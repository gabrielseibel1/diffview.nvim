--- Review session subsystem.
---
--- Tuicr-style PR review built on top of `DiffView`: local-only line and
--- file-level comments, a reviewed checkbox + status winbar on the file
--- panel, floating dialogs for comment list / submit / copy, and a single
--- `gh api -X POST .../pulls/<n>/reviews` to send everything to GitHub
--- when the user is happy.
---
--- This is the top-level entry point. It lazily wires every submodule so
--- requiring `"diffview.review"` from anywhere is cheap and side-effect
--- free until `setup()` actually attaches listeners.
---
--- See `~/.claude/plans/wobbly-mapping-hickey.md` for the full design.

local lazy = require("diffview.lazy")

local Session = lazy.access("diffview.review.session", "Session") ---@type ReviewSession|LazyModule
local actions = lazy.require("diffview.review.actions") ---@module "diffview.review.actions"
local logger = lazy.access(_G, { "DiffviewGlobal", "logger" }) ---@type Logger

local M = {}

---@type table<integer, ReviewSession>  -- keyed by DiffView.tabpage
local sessions_by_tab = {}

---@type boolean
local did_setup = false

---@param view DiffView
---@return ReviewSession?
function M.session_for(view)
  if not view or not view.tabpage then return nil end
  return sessions_by_tab[view.tabpage]
end

---@param view DiffView
---@param session ReviewSession
function M.register_session(view, session)
  sessions_by_tab[view.tabpage] = session
end

---@param view DiffView
function M.unregister_session(view)
  if view and view.tabpage then
    sessions_by_tab[view.tabpage] = nil
  end
end

---Idempotent setup hook. Called from `diffview.config.setup` so review
---listeners attach exactly once per nvim session.
function M.setup()
  if did_setup then return end
  did_setup = true

  -- Hooks for view lifecycle, comment-marker redraw, and on-close prompt
  -- get attached here in later tasks. For now this is a no-op so the
  -- module is safe to require everywhere.
  logger:lvl(5):debug("[review] setup called")
end

---Refresh the file-panel status bar (winbar) for the given view. Filled
---in by task #9; safe no-op before then.
---@param view DiffView
---@diagnostic disable-next-line: unused-local
function M.refresh_statusbar(view)
  -- task #9
end

M.actions = actions
M.Session = Session

return M
