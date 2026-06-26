--- File-panel decoration for active review sessions.
---
--- Installs two hooks on `views/diff/render`:
---   * `file_row_prefix`  -> prepends `[x] ` / `[ ] ` to each file row,
---                           hl=DiffviewReviewReviewed / Pending
---   * `post_panel_render` -> sets the file-panel window's `winbar` to
---                            the session.render_statusbar() text
---
--- The install is idempotent and uses `require()` directly (not lazy)
--- so the hooks are in place before the first panel render.
---
--- For `refresh_statusbar(view)` we read the panel from `view.panel`
--- and apply the winbar inline, without triggering a re-render.

local lazy = require("diffview.lazy")

local review = lazy.require("diffview.review") ---@module "diffview.review"

local api = vim.api
local M = {}

---@type boolean
local installed = false

-- ───── prefix decorator (per file row) ────────────────────────────────

---@param comp RenderComponent
---@param file FileEntry
---@param panel FilePanel
local function file_row_prefix(comp, file, panel)
  local view = panel and panel.view  -- not present; we look up via tabpage
  -- The panel doesn't store its view; we find the session via the
  -- current tabpage which equals view.tabpage for the panel that's
  -- currently rendering.
  if not view then
    local tabpage = api.nvim_get_current_tabpage()
    -- Locate the view by tabpage through the global views list.
    for _, v in ipairs(require("diffview.lib").views) do
      if v.tabpage == tabpage then view = v; break end
    end
  end
  local session = view and review.session_for(view)
  if not session then return end

  if session:is_reviewed(file.path) then
    comp:add_text("[x] ", "DiffviewReviewReviewed")
  else
    comp:add_text("[ ] ", "DiffviewReviewPending")
  end
end

-- ───── status bar (winbar) ────────────────────────────────────────────

---@param view DiffView
function M.refresh_statusbar(view)
  if not view or not view.panel then return end
  local panel = view.panel
  if not panel.winid or not api.nvim_win_is_valid(panel.winid) then return end
  local session = review.session_for(view)
  if not session then
    -- Clear any previously-set review winbar without clobbering other
    -- consumers — we only own a winbar when a session is attached.
    pcall(function() vim.wo[panel.winid].winbar = "" end)
    return
  end
  pcall(function()
    vim.wo[panel.winid].winbar = session:render_statusbar()
  end)
end

---@param panel FilePanel
local function post_panel_render(panel)
  -- Find the view for this panel and refresh its winbar.
  local tabpage = api.nvim_get_current_tabpage()
  for _, v in ipairs(require("diffview.lib").views) do
    if v.tabpage == tabpage and v.panel == panel then
      M.refresh_statusbar(v)
      return
    end
  end
end

-- ───── install ────────────────────────────────────────────────────────

---Install the render hooks. Idempotent.
function M.install()
  if installed then return end
  installed = true
  local render = require("diffview.scene.views.diff.render")
  render.file_row_prefix   = file_row_prefix
  render.post_panel_render = post_panel_render
end

return M
