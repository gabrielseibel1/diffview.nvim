--- Inline extmark-based comment markers on the diff buffers.
---
--- For each comment on a (path, side) pair that's currently displayed in
--- a diff window, we place:
---   * a sign in the gutter (config.review.sign_text, default "C") on
---     the comment's line
---   * a virt_lines preview below the line: the first body line truncated
---     to ~60 columns, prefixed with " └ "
---
--- For a multi-line range comment we underline the range with
--- `line_hl_group = "DiffviewReviewMark"` so it's visually distinguishable
--- from single-line comments.
---
--- Rendering is driven from `diffview.review.setup()` listeners:
---   * `view.emitter:on("file_open_post", ...)`      - file swapped
---   * `DiffviewGlobal.emitter:on("diff_buf_win_enter", ...)` - shown
--- Both call M.redraw_for_view(view) which walks the layout, clears the
--- namespace on each diff buffer, and re-applies markers.

local lazy = require("diffview.lazy")

local config = lazy.require("diffview.config") ---@module "diffview.config"
local logger = lazy.access(_G, { "DiffviewGlobal", "logger" }) ---@type Logger

local api = vim.api
local M = {}

---@type integer
M.ns = api.nvim_create_namespace("diffview_review_markers")

-- ───── helpers ────────────────────────────────────────────────────────

local function trunc(s, n)
  s = (s or ""):gsub("\n.*", "")  -- first line only
  if #s <= n then return s end
  return s:sub(1, n - 1) .. "…"
end

---@return string
local function sign_text()
  local cfg = config.get_config().review or {}
  return (cfg.sign_text or "C"):sub(1, 2)
end

-- ───── core redraw ────────────────────────────────────────────────────

---Clear all markers placed by this module on `bufnr`.
---@param bufnr integer
function M.clear(bufnr)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then return end
  api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
end

---Place markers for one session on one buffer / one side.
---@param session ReviewSession
---@param bufnr integer
---@param side "LEFT"|"RIGHT"
function M.redraw(session, bufnr, side)
  if not (session and bufnr and api.nvim_buf_is_valid(bufnr)) then return end
  M.clear(bufnr)

  -- Resolve the path we should match against for this buffer. We can't
  -- ask the buffer its diffview path directly, so the caller passes the
  -- session, and we walk session.view.cur_layout to find which file's
  -- bufnr matches. The caller already does this lookup; here we just
  -- accept the bufnr + side + path implicitly through cur_entry.
  local view = session.view
  if not view or not view.cur_entry then return end
  local path = view.cur_entry.path
  -- For LEFT-side markers on renamed files, use oldpath.
  if side == "LEFT" and view.cur_entry.oldpath and view.cur_entry.oldpath ~= "" then
    path = view.cur_entry.oldpath
  end

  local n_lines = api.nvim_buf_line_count(bufnr)
  local sign = sign_text()

  local n = 0
  for _, c in ipairs(session:comments_for(path, side)) do
    n = n + 1
    if c.subject == "file" then
      -- File-level comment: pin at line 1.
      local row = 0
      if row < n_lines then
        api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, {
          sign_text = sign,
          sign_hl_group = "DiffviewReviewMark",
          virt_lines = {
            { { " └ ", "DiffviewReviewMarkPreview" },
              { ("[FILE] " .. trunc(c.body, 60)), "DiffviewReviewMarkPreview" } },
          },
          virt_lines_above = false,
        })
      end
    else
      local start_l = (c.start_line or c.line) - 1   -- 0-indexed
      local end_l = c.line - 1
      if start_l < 0 then start_l = 0 end
      if end_l >= n_lines then end_l = n_lines - 1 end
      if end_l < start_l then end_l = start_l end

      -- Sign on the last line of the range (where the cursor naturally lands).
      api.nvim_buf_set_extmark(bufnr, M.ns, end_l, 0, {
        sign_text = sign,
        sign_hl_group = "DiffviewReviewMark",
        virt_lines = {
          { { " └ ", "DiffviewReviewMarkPreview" },
            { trunc(c.body, 60), "DiffviewReviewMarkPreview" } },
        },
        virt_lines_above = false,
      })

      -- Underline range for multi-line comments.
      if end_l > start_l then
        for row = start_l, end_l do
          api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, {
            line_hl_group = "DiffviewReviewMark",
            priority = 50,
          })
        end
      end
    end
  end

  if n > 0 then
    logger:lvl(10):debug(("[review.markers] %d marker(s) on buf %d side %s"):format(n, bufnr, side))
  end
end

---Redraw markers for both sides of the currently-displayed file in a view.
---@param view DiffView
---@param session? ReviewSession  -- defaults to the view's session
function M.redraw_for_view(view, session)
  session = session or require("diffview.review").session_for(view)
  if not session or not view or not view.cur_layout then return end
  local layout = view.cur_layout
  local b_buf = layout.b and layout.b.file and layout.b.file.bufnr
  local a_buf = layout.a and layout.a.file and layout.a.file.bufnr
  if b_buf then M.redraw(session, b_buf, "RIGHT") end
  if a_buf then M.redraw(session, a_buf, "LEFT") end
end

return M
