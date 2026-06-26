--- Inline comment editor.
---
--- Opens a small floating window with a normal modifiable scratch buffer
--- so every vim motion / textobject / register / undo behaves natively.
--- The float is anchored to the diff window using `bufpos`, so it
--- visually sits just below the line being commented on. It auto-grows
--- vertically on `TextChanged*` up to `config.review.max_editor_height`.
---
--- Lifecycle:
---   open(session, location, opts) -> opens the float and stores state
---     in a module-level `active` table.
---   save() / cancel() -> close the float; save() also commits the body
---     to the session.
---
--- Only one editor can be open at a time; calling open() while one is
--- live first cancels the existing one.

local lazy = require("diffview.lazy")

local config = lazy.require("diffview.config") ---@module "diffview.config"
local logger = lazy.access(_G, { "DiffviewGlobal", "logger" }) ---@type Logger
local markers = lazy.require("diffview.review.markers") ---@module "diffview.review.markers"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local M = {}

---@class ReviewEditorOpts
---@field existing_comment? ReviewComment   -- if set, save() updates instead of adding

---@class ReviewEditorState
---@field session         ReviewSession
---@field location        ReviewCursorLocation
---@field opts            ReviewEditorOpts
---@field parent_win      integer
---@field win             integer
---@field buf             integer
---@field aug             integer

---@type ReviewEditorState?
local active = nil

-- ───── geometry ───────────────────────────────────────────────────────

---@param parent_win integer
---@param body_lines integer
---@return table  -- nvim_open_win config
local function float_config_for(parent_win, body_lines)
  local cfg = config.get_config().review or {}
  local max_h = cfg.max_editor_height or 12
  local border = cfg.border or "rounded"
  local height = math.max(1, math.min(body_lines, max_h))
  local win_w = api.nvim_win_get_width(parent_win)
  local width = math.max(20, win_w - 4)

  local cursor_line = api.nvim_win_get_cursor(parent_win)[1]
  -- bufpos is 0-indexed from the start of the buffer; place the float
  -- on the line *below* the cursor.
  return {
    relative = "win",
    win = parent_win,
    bufpos = { cursor_line - 1, 0 },
    anchor = "NW",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = border,
    title = " comment ",
    title_pos = "left",
    noautocmd = false,
  }
end

---@param win integer
---@param buf integer
local function resize_to_content(win, buf)
  if not (api.nvim_win_is_valid(win) and api.nvim_buf_is_valid(buf)) then return end
  local n = api.nvim_buf_line_count(buf)
  local cfg = config.get_config().review or {}
  local h = math.max(1, math.min(n, cfg.max_editor_height or 12))
  local current = api.nvim_win_get_height(win)
  if current ~= h then api.nvim_win_set_height(win, h) end
end

-- ───── keymaps ────────────────────────────────────────────────────────

---@param buf integer
local function install_keymaps(buf)
  -- Apply `config.keymaps.review` to the editor buffer.
  for _, km in ipairs(config.get_config().keymaps.review or {}) do
    local modes, lhs, rhs, opts = km[1], km[2], km[3], km[4]
    opts = vim.tbl_extend("force", { buffer = buf, silent = true, nowait = true }, opts or {})
    if type(modes) ~= "table" then modes = { modes } end
    for _, mode in ipairs(modes) do
      pcall(vim.keymap.set, mode, lhs, rhs, opts)
    end
  end
end

-- ───── header ─────────────────────────────────────────────────────────

---@param loc ReviewCursorLocation
---@return string
local function header_for(loc)
  if loc.subject == "file" then
    return ("# %s (FILE)"):format(loc.path)
  end
  local span = loc.start_line and ("L%d-L%d"):format(loc.start_line, loc.line)
                              or  ("L%d"):format(loc.line)
  return ("# %s:%s (%s)"):format(loc.path, span, loc.side or "RIGHT")
end

-- ───── open / close ───────────────────────────────────────────────────

local function close_active()
  if not active then return end
  local st = active
  active = nil
  pcall(api.nvim_del_augroup_by_id, st.aug)
  if api.nvim_win_is_valid(st.win) then
    pcall(api.nvim_win_close, st.win, true)
  end
  if api.nvim_buf_is_valid(st.buf) then
    pcall(api.nvim_buf_delete, st.buf, { force = true })
  end
end

---Open the editor.
---@param session ReviewSession
---@param location ReviewCursorLocation
---@param opts? ReviewEditorOpts
---@return integer? winid
function M.open(session, location, opts)
  opts = opts or {}
  if active then
    -- A second open() means "give up the previous one".
    close_active()
  end

  local parent_win = api.nvim_get_current_win()
  local buf = api.nvim_create_buf(false, true)  -- nofile, no listing
  api.nvim_buf_set_name(buf, ("diffview://review/comment/%d"):format(buf))
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false
  vim.bo[buf].modifiable = true
  -- Markdown filetype is nice-to-have (gives the user markdown text objects,
  -- comment/header motions, etc.) but its FileType autocmds may try to
  -- start treesitter or LSPs that aren't available — never fatal here.
  pcall(function() vim.bo[buf].filetype = "markdown" end)

  local initial = { header_for(location), "" }
  if opts.existing_comment and opts.existing_comment.body then
    for line in (opts.existing_comment.body .. "\n"):gmatch("([^\n]*)\n") do
      table.insert(initial, line)
    end
  end
  api.nvim_buf_set_lines(buf, 0, -1, false, initial)

  local win_cfg = float_config_for(parent_win, #initial)
  local win = api.nvim_open_win(buf, true, win_cfg)
  -- Put the cursor on the first body line (skipping the header).
  pcall(api.nvim_win_set_cursor, win, { math.min(2, #initial), 0 })

  install_keymaps(buf)

  local aug = api.nvim_create_augroup(("DiffviewReviewEditor_%d"):format(buf), { clear = true })

  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = aug, buffer = buf,
    callback = function() resize_to_content(win, buf) end,
  })
  -- If the user navigates away (e.g. clicks into another window), cancel.
  api.nvim_create_autocmd("BufLeave", {
    group = aug, buffer = buf,
    callback = function()
      vim.schedule(function() if active and active.buf == buf then M.cancel() end end)
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = aug, pattern = tostring(win),
    callback = function() vim.schedule(close_active) end,
  })

  active = {
    session = session, location = location, opts = opts,
    parent_win = parent_win, win = win, buf = buf, aug = aug,
  }
  logger:lvl(5):debug(("[review.editor] opened on %s"):format(header_for(location)))
  return win
end

-- ───── save / cancel ──────────────────────────────────────────────────

---@param buf integer
---@return string
local function read_body(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  -- Strip the auto-generated header line (and any blank line right after).
  if lines[1] and lines[1]:match("^#%s") then table.remove(lines, 1) end
  while lines[1] == "" do table.remove(lines, 1) end
  while #lines > 0 and lines[#lines] == "" do table.remove(lines, #lines) end
  return table.concat(lines, "\n")
end

---Commit the active editor's body to the session and close.
function M.save()
  if not active then return end
  local st = active
  local body = read_body(st.buf)
  if body == "" then
    utils.warn("[review] empty comment — not saved (use q to cancel without saving)")
    return
  end
  local existing = st.opts.existing_comment
  if existing then
    st.session:update_comment(existing.id, { body = body })
    logger:lvl(5):debug(("[review.editor] updated comment %s"):format(existing.id))
  else
    local id = st.session:add_comment({
      path = st.location.path,
      side = st.location.side,
      line = st.location.line,
      start_line = st.location.start_line,
      subject = st.location.subject,
      body = body,
    })
    logger:lvl(5):debug(("[review.editor] added comment %s"):format(id))
  end
  close_active()

  -- Trigger marker + statusbar refresh on the host view.
  local review = require("diffview.review")
  local view = st.session.view
  if view then
    if view.cur_layout then
      local b_buf = view.cur_layout.b and view.cur_layout.b.file and view.cur_layout.b.file.bufnr
      local a_buf = view.cur_layout.a and view.cur_layout.a.file and view.cur_layout.a.file.bufnr
      if b_buf then markers.redraw(st.session, b_buf, "RIGHT") end
      if a_buf then markers.redraw(st.session, a_buf, "LEFT") end
    end
    if view.panel and view.panel.is_open and view.panel:is_open() then
      view.panel:render()
      view.panel:redraw()
      review.refresh_statusbar(view)
    end
  end
  utils.info("[review] comment saved")
end

---Discard the active editor.
function M.cancel()
  if not active then return end
  close_active()
end

---Test helper.
function M._active() return active end

return M
