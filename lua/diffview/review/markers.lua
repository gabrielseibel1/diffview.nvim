--- Inline extmark-based comment markers on the diff buffers.
---
--- For each comment on a (path, side) pair that's currently displayed in
--- a diff window, we place:
---   * a sign in the gutter (config.review.sign_text, default "C") on
---     the comment's line
---   * a `virt_lines` preview below the line: the FULL body, wrapped to
---     the parent window's width and prefixed with " ┌ / │ / └ " box
---     drawing on each row.
---   * for a multi-line range comment, `line_hl_group = "DiffviewReviewMark"`
---     on each line of the range so it's visually distinguishable.
---
--- Why `virt_lines` and not floating windows: floats anchored with
--- `bufpos` don't track scroll-out correctly (they stick near the top of
--- the parent window once the anchor line scrolls off-screen). `virt_lines`
--- are part of the buffer's rendered output, scroll naturally with the
--- code, never overlap, and don't need autocmd choreography.
---
--- Tradeoff: `virt_lines` rows aren't cursor-navigable. That's fine
--- because `<leader>je` / `<leader>jd` act on the *code line* the
--- comment is anchored to, not on the virtual preview rows. The cursor
--- never needs to land on the preview.
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

---@return string
local function sign_text()
  local cfg = config.get_config().review or {}
  return (cfg.sign_text or "C"):sub(1, 2)
end

---@return integer  Max virtual rows per comment preview.
local function max_preview_rows()
  local cfg = config.get_config().review or {}
  return cfg.max_marker_height or 12
end

--- Hard-wrap `body` to `width` display columns, splitting on whitespace
--- when possible. Newlines in `body` become row breaks.
---@param body string
---@param width integer
---@return string[]
local function wrap_body(body, width)
  local out = {}
  if width < 1 then width = 1 end
  for raw in (body .. "\n"):gmatch("([^\n]*)\n") do
    if raw == "" then
      table.insert(out, "")
    else
      local line = raw
      while vim.fn.strdisplaywidth(line) > width do
        local cut
        local acc = 0
        local last_ws = nil
        for i = 1, #line do
          local ch = line:sub(i, i)
          acc = acc + vim.fn.strdisplaywidth(ch)
          if ch == " " or ch == "\t" then last_ws = i end
          if acc > width then
            cut = (last_ws and last_ws > 0) and last_ws or (i - 1)
            break
          end
        end
        if not cut or cut < 1 then cut = #line end
        table.insert(out, line:sub(1, cut):gsub("%s+$", ""))
        line = line:sub(cut + 1):gsub("^%s+", "")
        if line == "" then break end
      end
      if line ~= "" then table.insert(out, line) end
    end
  end
  if #out == 0 then table.insert(out, "") end
  return out
end

---Pick a sensible wrap width given a buffer that's currently visible in
---some window. We use the narrowest window showing this buffer so the
---preview never overflows.
---@param bufnr integer
---@return integer
local function preview_width_for(bufnr)
  local w
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(win) == bufnr then
      local ww = api.nvim_win_get_width(win)
      if not w or ww < w then w = ww end
    end
  end
  if not w or w < 20 then w = 80 end
  -- Leave room for sign column + the " │ " prefix on each virt row.
  return math.max(20, w - 6)
end

--- Build the virt_lines payload for a comment body. Returns a list of
--- chunk-lists (each chunk-list is one rendered row).
---@param body string
---@param width integer
---@param is_file boolean   prefix "[FILE]" on the first row
---@return table  -- nvim_buf_set_extmark virt_lines spec
local function virt_lines_for(body, width, is_file)
  local rows = wrap_body(body or "", width)
  local cap = max_preview_rows()
  if #rows > cap then
    -- Drop overflow but signal it.
    local kept = {}
    for i = 1, cap - 1 do table.insert(kept, rows[i]) end
    table.insert(kept, ("… (+%d more)"):format(#rows - (cap - 1)))
    rows = kept
  end

  local out = {}
  for i, row in ipairs(rows) do
    local glyph
    if #rows == 1 then
      glyph = " └ "
    elseif i == 1 then
      glyph = " ┌ "
    elseif i == #rows then
      glyph = " └ "
    else
      glyph = " │ "
    end
    local prefix = is_file and i == 1 and (glyph .. "[FILE] ") or glyph
    table.insert(out, {
      { prefix, "DiffviewReviewMarkPreview" },
      { row,    "DiffviewReviewMarkPreview" },
    })
  end
  return out
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

  local view = session.view
  if not view or not view.cur_entry then return end
  local path = view.cur_entry.path
  if side == "LEFT" and view.cur_entry.oldpath and view.cur_entry.oldpath ~= "" then
    path = view.cur_entry.oldpath
  end

  local n_lines = api.nvim_buf_line_count(bufnr)
  local sign = sign_text()
  local width = preview_width_for(bufnr)

  local n = 0
  for _, c in ipairs(session:comments_for(path, side)) do
    n = n + 1
    if c.subject == "file" then
      local row = 0
      if row < n_lines then
        api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, {
          sign_text = sign,
          sign_hl_group = "DiffviewReviewMark",
          virt_lines = virt_lines_for(c.body, width, true),
          virt_lines_above = false,
        })
      end
    else
      local start_l = (c.start_line or c.line) - 1   -- 0-indexed
      local end_l = c.line - 1
      if start_l < 0 then start_l = 0 end
      if end_l >= n_lines then end_l = n_lines - 1 end
      if end_l < start_l then end_l = start_l end

      -- Sign + preview on the last line of the range (where the cursor
      -- naturally lands after the comment is added).
      api.nvim_buf_set_extmark(bufnr, M.ns, end_l, 0, {
        sign_text = sign,
        sign_hl_group = "DiffviewReviewMark",
        virt_lines = virt_lines_for(c.body, width, false),
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

-- ───── cursor → comment lookup (for <leader>je / <leader>jd) ──────────

---Comments anchored on or covering `line` (1-based) of `bufnr` on the
---given side. The check matches:
---  * line-subject comments whose [start_line, end_line] range contains
---    `line`
---  * file-subject comments only when `line == 1` (their marker sits there)
---@param session ReviewSession
---@param bufnr integer
---@param side "LEFT"|"RIGHT"
---@param line integer  1-based
---@return ReviewComment[]
function M.comments_at_line(session, bufnr, side, line)
  if not (session and bufnr and api.nvim_buf_is_valid(bufnr)) then return {} end
  local view = session.view
  if not view or not view.cur_entry then return {} end
  local path = view.cur_entry.path
  if side == "LEFT" and view.cur_entry.oldpath and view.cur_entry.oldpath ~= "" then
    path = view.cur_entry.oldpath
  end
  local out = {}
  for _, c in ipairs(session:comments_for(path, side)) do
    if c.subject == "file" then
      if line == 1 then table.insert(out, c) end
    else
      local start_l = c.start_line or c.line
      local end_l = c.line
      if start_l > end_l then start_l, end_l = end_l, start_l end
      if line >= start_l and line <= end_l then
        table.insert(out, c)
      end
    end
  end
  return out
end

---Resolve which (side, layout window) corresponds to a given diff window
---in the view. Returns nil if the window isn't one of the layout's diff
---windows.
---@param view DiffView
---@param winid integer
---@return "LEFT"|"RIGHT"?
function M.side_for_win(view, winid)
  local layout = view and view.cur_layout
  if not layout then return nil end
  if layout.a and layout.a.id == winid then return "LEFT" end
  if layout.b and layout.b.id == winid then return "RIGHT" end
  return nil
end

return M
