local lazy = require("diffview.lazy")
local oop = require("diffview.oop")

local File = lazy.access("diffview.vcs.file", "File") ---@type vcs.File|LazyModule
local RevType = lazy.access("diffview.vcs.rev", "RevType") ---@type RevType|LazyModule
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api

local M = {}

local fstat_cache = {}

---@class GitStats
---@field additions integer
---@field deletions integer
---@field conflicts integer

---@class RevMap
---@field a Rev
---@field b Rev
---@field c Rev
---@field d Rev

---@class FileEntry : diffview.Object
---@field adapter GitAdapter
---@field path string
---@field oldpath string
---@field absolute_path string
---@field parent_path string
---@field basename string
---@field extension string
---@field revs RevMap
---@field layout Layout
---@field status string
---@field stats GitStats
---@field kind vcs.FileKind
---@field commit Commit|nil
---@field active boolean
local FileEntry = oop.create_class("FileEntry")

---@class FileEntry.init.Opt
---@field adapter GitAdapter
---@field path string
---@field oldpath string
---@field revs RevMap
---@field layout Layout
---@field status string
---@field stats GitStats
---@field kind vcs.FileKind
---@field commit? Commit

---FileEntry constructor
---@param opt FileEntry.init.Opt
function FileEntry:init(opt)
  self.adapter = opt.adapter
  self.path = opt.path
  self.oldpath = opt.oldpath
  self.absolute_path = utils.path:absolute(opt.path, opt.adapter.ctx.toplevel)
  self.parent_path = utils.path:parent(opt.path) or ""
  self.basename = utils.path:basename(opt.path)
  self.extension = utils.path:extension(opt.path)
  self.revs = opt.revs
  self.layout = opt.layout
  self.status = opt.status
  self.stats = opt.stats
  self.kind = opt.kind
  self.commit = opt.commit
  self.active = false
end

function FileEntry:destroy()
  for _, f in ipairs(self.layout:files()) do
    f:destroy()
  end

  self.layout:destroy()
end

---@param new_head Rev
function FileEntry:update_heads(new_head)
  for _, file in ipairs(self.layout:files()) do
    if file.rev.track_head then
      file:dispose_buffer()
      file.rev = new_head
    end
  end
end

---@param flag boolean
function FileEntry:set_active(flag)
  self.active = flag

  for _, f in ipairs(self.layout:files()) do
    f.active = flag
  end
end

---@param target_layout Layout
function FileEntry:convert_layout(target_layout)
  local get_data

  for _, file in ipairs(self.layout:files()) do
    if file.get_data then
      get_data = file.get_data
      break
    end
  end

  local function create_file(rev, symbol)
    return File({
      adapter = self.adapter,
      path = self.path,
      kind = self.kind,
      commit = self.commit,
      get_data = get_data,
      rev = rev,
      nulled = select(2, pcall(target_layout.should_null, rev, self.status, symbol)),
    }) --[[@as vcs.File ]]
  end

  self.layout = target_layout({
    parent = self,
    a = utils.tbl_access(self.layout, "a.file") or create_file(self.revs.a, "a"),
    b = utils.tbl_access(self.layout, "b.file") or create_file(self.revs.b, "b"),
    c = utils.tbl_access(self.layout, "c.file") or create_file(self.revs.c, "c"),
    d = utils.tbl_access(self.layout, "d.file") or create_file(self.revs.d, "d"),
  })
end

---@param adapter VCSAdapter
---@param stat? table
function FileEntry:validate_stage_buffers(adapter, stat)
  stat = stat or utils.path:stat(utils.path:join(adapter.ctx.dir, "index"))
  local cached_stat = utils.tbl_access(fstat_cache, { adapter.ctx.toplevel, "index" })

  if stat then
    if not cached_stat or cached_stat.mtime < stat.mtime.sec then
      for _, f in ipairs(self.layout:files()) do
        if f.rev.type == RevType.STAGE and f:is_valid() then
          if f.rev.stage == 0 then
            local is_modified = vim.bo[f.bufnr].modified

            if f.blob_hash then
              local new_hash = f.adapter:file_blob_hash(f.path)
              if new_hash and new_hash ~= f.blob_hash and is_modified then
                utils.warn((
                  "A file was changed in the index since you started editing it!"
                  .. " Be careful not to lose any staged changes when writing to this buffer: %s"
                ):format(api.nvim_buf_get_name(f.bufnr)))
              end
            elseif not is_modified then
              -- Should be very rare that we don't have an index-buffer's blob
              -- hash. But in that case, we can't warn the user when a file
              -- changes in the index while they're editing its index buffer.
              f:dispose_buffer()
            end

          else
            f:dispose_buffer()
          end
        end
      end
    end
  end
end

---@static
---@param adapter VCSAdapter
function FileEntry.update_index_stat(adapter, stat)
  stat = stat or utils.path:stat(utils.path:join(adapter.ctx.toplevel, "index"))

  if stat then
    if not fstat_cache[adapter.ctx.toplevel] then
      fstat_cache[adapter.ctx.toplevel] = {}
    end

    fstat_cache[adapter.ctx.toplevel].index = {
      mtime = stat.mtime.sec,
    }
  end
end

---@class FileEntry.with_layout.Opt : FileEntry.init.Opt
---@field nulled boolean
---@field get_data git.FileDataProducer?

---@param layout_class Layout (class)
---@param opt FileEntry.with_layout.Opt
---@return FileEntry
function FileEntry.with_layout(layout_class, opt)
  local function create_file(rev, symbol)
    return File({
      adapter = opt.adapter,
      path = opt.path,
      kind = opt.kind,
      commit = opt.commit,
      get_data = opt.get_data,
      rev = rev,
      nulled = utils.sate(
        opt.nulled,
        select(2, pcall(layout_class.should_null, rev, opt.status, symbol))
      ),
    }) --[[@as vcs.File ]]
  end

  local entry = FileEntry({
    adapter = opt.adapter,
    path = opt.path,
    oldpath = opt.oldpath,
    status = opt.status,
    stats = opt.stats,
    kind = opt.kind,
    commit = opt.commit,
    revs = opt.revs,
  })

  entry.layout = layout_class({
    parent = entry,
    a = create_file(opt.revs.a, "a"),
    b = create_file(opt.revs.b, "b"),
    c = create_file(opt.revs.c, "c"),
    d = create_file(opt.revs.d, "d"),
  })

  return entry
end

M.FileEntry = FileEntry
return M
