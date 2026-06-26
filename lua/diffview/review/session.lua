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

local logger = lazy.access(_G, { "DiffviewGlobal", "logger" }) ---@type Logger
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local M = {}

---@class ReviewComment
---@field id          string                  -- uuid-ish; stable across saves
---@field path        string                  -- relative to repo root (oldpath on LEFT renames)
---@field side        "LEFT" | "RIGHT"        -- which side of the diff
---@field line        integer                 -- end line; 1-based
---@field start_line? integer                 -- inclusive start; nil = single-line
---@field subject     "line" | "file"
---@field body        string                  -- raw markdown

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
---@field _save_timer?   userdata              -- debounce handle
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
end

---Append a new comment. Returns its id.
---@param c ReviewComment
---@return string id
function Session:add_comment(c)
  if not c.id then c.id = utils.uuid and utils.uuid() or tostring(os.time()) .. "-" .. tostring(#self.comments + 1) end
  table.insert(self.comments, c)
  self:mutate()
  return c.id
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

---Mark the session as dirty and schedule a save.
function Session:mutate()
  self.dirty = true
  -- Debounced persist is wired in a later task; for now just record the
  -- intent so callers don't have to worry about it.
end

---Number of distinct files reviewed.
---@return integer
function Session:n_reviewed()
  local n = 0
  for _ in pairs(self.reviewed_files) do n = n + 1 end
  return n
end

---@return string
function Session:short_id()
  if self.pr then return ("#%d"):format(self.pr) end
  return "(copy-only)"
end

---Avoid an "unused" warning in case `logger` only fires conditionally.
function Session:_debug_log(msg)
  logger:lvl(10):debug(("[review.session %s] %s"):format(self:short_id(), msg))
end

return M
