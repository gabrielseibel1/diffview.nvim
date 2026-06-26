--- ReviewSession: in-memory + on-disk model of a single review.
---
--- A session is created when the user runs `:DiffviewReviewStart` (or when
--- auto-attach is on). It holds the list of pending comments, the set of
--- reviewed file paths, and the metadata needed to submit to GitHub
--- (owner, repo, host, pr, commit_id).
---
--- Persistence is debounced JSON at `stdpath('data')/diffview/reviews/`.
--- `copy_only` sessions (no PR detected) are not persisted because there's
--- no stable key.

local oop = require("diffview.oop")
local lazy = require("diffview.lazy")
local debounce = require("diffview.debounce")

local config = lazy.require("diffview.config") ---@module "diffview.config"
local logger = lazy.access(_G, { "DiffviewGlobal", "logger" }) ---@type Logger

local uv = vim.loop

local M = {}

---@class ReviewComment
---@field id          string                  -- uuid-ish; stable across saves
---@field path        string                  -- relative to repo root (oldpath on LEFT renames)
---@field side        "LEFT" | "RIGHT"        -- which side of the diff
---@field line        integer                 -- end line; 1-based
---@field start_line? integer                 -- inclusive start; nil = single-line
---@field subject     "line" | "file"
---@field body        string                  -- raw markdown
---@field created_at? integer                 -- os.time() at creation

---@class ReviewSession : diffview.Object
---@field view           DiffView
---@field owner          string
---@field repo           string
---@field host           string                -- e.g. "github.tools.sap" or "github.com"
---@field pr             integer?              -- nil in copy_only mode
---@field commit_id      string                -- view.right.commit (PR head SHA)
---@field comments       ReviewComment[]
---@field reviewed_files table<string, true>   -- path -> true
---@field total_files    integer
---@field dirty          boolean               -- has unsaved/unsubmitted changes
---@field copy_only      boolean               -- no PR -> only yank works
---@field _persist       fun()                 -- debounced save trigger
local Session = oop.create_class("ReviewSession")
M.Session = Session

---@class ReviewSession.InitOpts
---@field view        DiffView
---@field owner       string
---@field repo        string
---@field host        string
---@field pr          integer?
---@field commit_id   string
---@field total_files integer
---@field copy_only?  boolean

-- ───── persistence helpers ────────────────────────────────────────────

---@return string
local function persistence_root()
  local cfg = config.get_config()
  local dir = cfg.review and cfg.review.persistence_dir
  if dir and dir ~= "" then return dir end
  return vim.fn.stdpath("data") .. "/diffview/reviews"
end

---@param session ReviewSession
---@return string?
local function storage_path(session)
  if session.copy_only or not session.pr then return nil end
  local root = persistence_root()
  -- Replace path separators in host so the filename stays flat.
  local host = session.host:gsub("[/\\]", "_")
  return ("%s/%s__%s__%s__%d.json"):format(root, host, session.owner, session.repo, session.pr)
end

---@param path string
---@return boolean ok
local function ensure_dir(path)
  if vim.fn.isdirectory(path) == 1 then return true end
  return vim.fn.mkdir(path, "p") == 1
end

---@param path string
---@param data string
---@return boolean ok, string? err
local function write_atomic(path, data)
  local tmp = path .. ".tmp"
  local fd, err = uv.fs_open(tmp, "w", 420)  -- 0644
  if not fd then return false, err end
  local ok_w, err_w = uv.fs_write(fd, data, 0)
  uv.fs_close(fd)
  if not ok_w then return false, err_w end
  local ok_r, err_r = uv.fs_rename(tmp, path)
  if not ok_r then return false, err_r end
  return true
end

---@param path string
---@return string?
local function read_file(path)
  local fd = uv.fs_open(path, "r", 420)
  if not fd then return nil end
  local stat = uv.fs_fstat(fd)
  if not stat then uv.fs_close(fd); return nil end
  local data = uv.fs_read(fd, stat.size, 0)
  uv.fs_close(fd)
  return data
end

---@param session ReviewSession
---@return table  -- JSON-serializable snapshot
local function snapshot(session)
  return {
    version = 1,
    host = session.host,
    owner = session.owner,
    repo = session.repo,
    pr = session.pr,
    commit_id = session.commit_id,
    comments = session.comments,
    reviewed_files = session.reviewed_files,
  }
end

---@param session ReviewSession
local function save_now(session)
  local path = storage_path(session)
  if not path then return end
  if not ensure_dir(persistence_root()) then
    logger:warn(("[review] could not create persistence dir: %s"):format(persistence_root()))
    return
  end
  local ok_enc, blob = pcall(vim.json.encode, snapshot(session))
  if not ok_enc then
    logger:warn(("[review] failed to encode session: %s"):format(tostring(blob)))
    return
  end
  local ok, err = write_atomic(path, blob)
  if not ok then
    logger:warn(("[review] failed to write %s: %s"):format(path, tostring(err)))
    return
  end
  session.dirty = false
  logger:lvl(5):debug(("[review] persisted %s (%d comments)"):format(path, #session.comments))
end

-- ───── public Session API ─────────────────────────────────────────────

---@param opt ReviewSession.InitOpts
function Session:init(opt)
  self.view           = assert(opt.view, "ReviewSession requires a view")
  self.owner          = assert(opt.owner, "ReviewSession requires owner")
  self.repo           = assert(opt.repo, "ReviewSession requires repo")
  self.host           = assert(opt.host, "ReviewSession requires host")
  self.pr             = opt.pr
  self.commit_id      = assert(opt.commit_id, "ReviewSession requires commit_id")
  self.total_files    = opt.total_files or 0
  self.copy_only      = opt.copy_only or (opt.pr == nil)
  self.comments       = {}
  self.reviewed_files = {}
  self.dirty          = false

  -- Debounced trailing-edge writer; rush_first=false so we don't write on
  -- the very first mutation (gives the caller a chance to batch).
  local self_ref = self
  self._persist = debounce.debounce_trailing(250, false, function()
    if self_ref.dirty then save_now(self_ref) end
  end)
end

---Build a fresh id for a new comment.
---@return string
local function new_id()
  -- Cheap, monotonically increasing within a session. Combines hrtime
  -- (ns since boot) with a process-local counter to avoid collisions.
  Session._counter = (Session._counter or 0) + 1
  return ("%d-%d"):format(uv.hrtime(), Session._counter)
end

---Append a new comment. Returns its id.
---@param c ReviewComment
---@return string id
function Session:add_comment(c)
  if not c.id then c.id = new_id() end
  if not c.created_at then c.created_at = os.time() end
  table.insert(self.comments, c)
  self:mutate()
  return c.id
end

---Replace an existing comment in place. Returns true iff one was updated.
---@param id string
---@param patch table<string, any>
---@return boolean
function Session:update_comment(id, patch)
  for _, c in ipairs(self.comments) do
    if c.id == id then
      for k, v in pairs(patch) do c[k] = v end
      self:mutate()
      return true
    end
  end
  return false
end

---Delete a comment by id. Returns true iff one was removed.
---@param id string
---@return boolean
function Session:delete_comment(id)
  for i, c in ipairs(self.comments) do
    if c.id == id then
      table.remove(self.comments, i)
      self:mutate()
      return true
    end
  end
  return false
end

---Find a comment by id.
---@param id string
---@return ReviewComment?
function Session:get_comment(id)
  for _, c in ipairs(self.comments) do
    if c.id == id then return c end
  end
  return nil
end

---Comments grouped by (path, side). Useful for marker rendering.
---@return table<string, ReviewComment[]>  -- key = path .. "\0" .. side
function Session:comments_index()
  local idx = {}
  for _, c in ipairs(self.comments) do
    local k = c.path .. "\0" .. (c.side or "")
    idx[k] = idx[k] or {}
    table.insert(idx[k], c)
  end
  return idx
end

---@param path string
---@param side "LEFT"|"RIGHT"
---@return ReviewComment[]
function Session:comments_for(path, side)
  local out = {}
  for _, c in ipairs(self.comments) do
    if c.path == path and (c.side == side or (c.subject == "file" and side == "RIGHT")) then
      table.insert(out, c)
    end
  end
  return out
end

---Toggle the reviewed flag on `path`. Returns the new state.
---@param path string
---@return boolean
function Session:toggle_reviewed(path)
  if self.reviewed_files[path] then
    self.reviewed_files[path] = nil
  else
    self.reviewed_files[path] = true
  end
  self:mutate()
  return self.reviewed_files[path] == true
end

---@param path string
---@return boolean
function Session:is_reviewed(path)
  return self.reviewed_files[path] == true
end

---Mark the session as dirty and schedule a save.
function Session:mutate()
  self.dirty = true
  if not self.copy_only then self._persist() end
end

---Number of distinct files marked as reviewed.
---@return integer
function Session:n_reviewed()
  local n = 0
  for _ in pairs(self.reviewed_files) do n = n + 1 end
  return n
end

---Short label used in the status bar and log lines.
---@return string
function Session:short_id()
  if self.pr then return ("#%d"):format(self.pr) end
  return "(copy-only)"
end

---Render the status-bar line (used by the file-panel patch).
---@return string
function Session:render_statusbar()
  local cfg = config.get_config().review or {}
  local tpl = cfg.status_template
      or "  Review %s  │ %d comments │ %d/%d reviewed"
  local label = self:short_id()
  if self.copy_only then label = label end
  return tpl:format(label, #self.comments, self:n_reviewed(), self.total_files)
end

---Force an immediate save (skipping the debounce).
function Session:save()
  if self.copy_only then return end
  save_now(self)
end

---Delete the on-disk session file (used after successful submit).
function Session:delete_storage()
  local path = storage_path(self)
  if path and vim.fn.filereadable(path) == 1 then
    os.remove(path)
  end
end

---Try to hydrate a session from disk.
---@param opt ReviewSession.InitOpts
---@return ReviewSession?
function M.load(opt)
  local probe = Session(opt)  -- one-shot to compute storage_path
  local path = storage_path(probe)
  if not path then return nil end
  local blob = read_file(path)
  if not blob then return nil end
  local ok, data = pcall(vim.json.decode, blob, { luanil = { object = true } })
  if not ok or type(data) ~= "table" then
    logger:warn(("[review] could not parse session file: %s"):format(path))
    return nil
  end
  probe.comments = data.comments or {}
  probe.reviewed_files = data.reviewed_files or {}
  probe.dirty = false
  logger:lvl(5):debug(("[review] loaded %s (%d comments)"):format(path, #probe.comments))
  return probe
end

---Direct constructor (no disk read).
---@param opt ReviewSession.InitOpts
---@return ReviewSession
function M.new(opt)
  return Session(opt)
end

---Exposed for testability.
M._save_now = save_now
M._snapshot = snapshot
M._storage_path = storage_path

return M
