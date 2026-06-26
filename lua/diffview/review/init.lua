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
local markers = lazy.require("diffview.review.markers") ---@module "diffview.review.markers"

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

---Refresh the file-panel status bar (winbar) for the given view.
---Filled in proper in `ui/file_panel_patch.lua`; this is the seam.
---@param view DiffView
function M.refresh_statusbar(view)
  local patch = require("diffview.review.ui.file_panel_patch")
  patch.refresh_statusbar(view)
end

-- ───── lifecycle listeners ────────────────────────────────────────────

---@param view DiffView?
local function on_view_opened(view)
  if not view then return end
  -- Auto-attach if config requests it.
  local cfg = require("diffview.config").get_config().review or {}
  if cfg.auto_attach then
    -- Defer so the view finishes layout before we touch its panel.
    vim.schedule(function()
      if M.session_for(view) then return end
      -- Reuse the same code path as the user command.
      vim.api.nvim_set_current_tabpage(view.tabpage)
      actions.start()
    end)
  end
end

---@param view DiffView?
local function on_view_closed(view)
  if not view then return end
  local session = M.session_for(view)
  if not session then return end
  if session.copy_only then
    M.unregister_session(view)
    return
  end
  if session.dirty then
    -- A debounced save may still be in flight; flush it now.
    session:save()
  end
  M.unregister_session(view)
end

---Hook for when a file is displayed (cursor swaps to a new diff buffer).
---@param view DiffView?
local function on_file_displayed(view)
  if not view then return end
  local session = M.session_for(view)
  if not session then return end
  markers.redraw_for_view(view, session)
end

-- ───── setup ──────────────────────────────────────────────────────────

---Idempotent setup hook. Called from `diffview.config.setup` so review
---listeners attach exactly once per nvim session.
function M.setup()
  if did_setup then return end
  did_setup = true

  local g = DiffviewGlobal.emitter

  g:on("view_opened", function(_, view) on_view_opened(view) end)
  g:on("view_closed", function(_, view) on_view_closed(view) end)
  -- `diff_buf_win_enter` fires every time a file is shown in a layout
  -- window. We don't get the view directly from the global emit, so we
  -- look it up via `lib.get_current_view`.
  g:on("diff_buf_win_enter", function()
    on_file_displayed(require("diffview.lib").get_current_view() --[[@as DiffView]])
  end)

  -- file_open_post is a per-view event, but at setup time the views
  -- don't exist yet. We hook it lazily inside on_view_opened.
  g:on("view_opened", function(_, view)
    if not view or not view.emitter then return end
    view.emitter:on("file_open_post", function()
      on_file_displayed(view)
    end)
    view.emitter:on("files_updated", function()
      local s = M.session_for(view)
      if s then s.total_files = view.files:len(); M.refresh_statusbar(view) end
    end)
  end)

  logger:lvl(5):debug("[review] setup complete; listeners attached")
end

M.actions = actions
M.Session = Session
M.markers = markers

return M
