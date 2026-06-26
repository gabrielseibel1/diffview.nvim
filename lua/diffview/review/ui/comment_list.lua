--- Pending-comments list (floating window).
---
--- Renders one row per pending comment in the active session. Each row is:
---   <path>:L<line>(<side>)  <body excerpt>
---
--- Keybindings (buffer-local):
---   <CR>      jump to the file+line in the host DiffView
---   d         delete the comment under the cursor
---   e         re-open the editor on the comment under the cursor
---   q, <esc>  close the list

local lazy = require("diffview.lazy")

local config = lazy.require("diffview.config") ---@module "diffview.config"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local M = {}

---@class CommentListState
---@field win integer
---@field buf integer
---@field session ReviewSession
---@field ids string[]  -- comment ids indexed by 1-based row

---@type CommentListState?
local active = nil

---@param c ReviewComment
---@return string
local function format_row(c)
  local body = (c.body or ""):gsub("\n.*$", "")
  if #body > 60 then body = body:sub(1, 59) .. "…" end
  if c.subject == "file" then
    return ("%s  [FILE]  %s"):format(c.path, body)
  end
  local span = c.start_line and ("L%d-L%d"):format(c.start_line, c.line)
                            or ("L%d"):format(c.line)
  return ("%s:%s (%s)  %s"):format(c.path, span, c.side or "RIGHT", body)
end

---@return integer width, integer height, integer row, integer col
local function float_geometry()
  local w = math.min(110, math.max(60, math.floor(vim.o.columns * 0.7)))
  local h = math.min(24, math.max(6, math.floor(vim.o.lines * 0.5)))
  local row = math.floor((vim.o.lines - h) * 0.5)
  local col = math.floor((vim.o.columns - w) * 0.5)
  return w, h, row, col
end

local function close()
  if not active then return end
  local st = active
  active = nil
  if api.nvim_win_is_valid(st.win) then pcall(api.nvim_win_close, st.win, true) end
  if api.nvim_buf_is_valid(st.buf) then pcall(api.nvim_buf_delete, st.buf, { force = true }) end
end

local function render(st)
  vim.bo[st.buf].modifiable = true
  st.ids = {}
  local lines = {}
  if #st.session.comments == 0 then
    table.insert(lines, "  (no pending comments — add some with <leader>cc)")
  else
    table.insert(lines, (" %s  │ %d pending comments"):format(
      st.session:short_id(), #st.session.comments))
    table.insert(lines, "")
    for _, c in ipairs(st.session.comments) do
      table.insert(lines, "  " .. format_row(c))
      table.insert(st.ids, c.id)
    end
    table.insert(lines, "")
    table.insert(lines, "  <CR> jump   e edit   d delete   q close")
  end
  api.nvim_buf_set_lines(st.buf, 0, -1, false, lines)
  vim.bo[st.buf].modifiable = false
end

---@return string?  comment id at the cursor line
local function id_at_cursor(st)
  local row = api.nvim_win_get_cursor(st.win)[1]
  -- The id list starts at the third visible line (header + blank line above).
  -- For empty sessions there's no id list.
  if not st.ids or #st.ids == 0 then return nil end
  local idx = row - 2  -- 1-indexed into st.ids
  return st.ids[idx]
end

---@param session ReviewSession
function M.open(session)
  if active then close() end

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "DiffviewReviewList"

  local w, h, row, col = float_geometry()
  local border = (config.get_config().review or {}).border or "rounded"
  local win = api.nvim_open_win(buf, true, {
    relative = "editor", row = row, col = col, width = w, height = h,
    style = "minimal", border = border, title = " review comments ", title_pos = "left",
  })

  local st = { win = win, buf = buf, session = session, ids = {} }
  active = st
  render(st)

  -- Cursor onto the first item if any.
  if #st.ids > 0 then pcall(api.nvim_win_set_cursor, win, { 3, 2 }) end

  local map = function(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
  end
  map("q", close, "Close the comment list")
  map("<esc>", close, "Close the comment list")
  map("<CR>", function()
    local id = id_at_cursor(st); if not id then return end
    local c = session:get_comment(id)
    if not c then return end
    close()
    -- Jump to the file in the host view and place cursor on the comment line.
    local view = session.view
    if view and view.set_file_by_path then
      view:set_file_by_path(c.path, true, false)
      vim.schedule(function()
        if c.subject == "line" and view.cur_layout then
          local target = view.cur_layout.b and (c.side == "RIGHT") and view.cur_layout.b.id or view.cur_layout.a and view.cur_layout.a.id
          if target and api.nvim_win_is_valid(target) then
            pcall(api.nvim_set_current_win, target)
            pcall(api.nvim_win_set_cursor, target, { c.line, 0 })
          end
        end
      end)
    end
  end, "Jump to the comment")
  map("d", function()
    local id = id_at_cursor(st); if not id then return end
    session:delete_comment(id)
    render(st)
    local review = require("diffview.review")
    if session.view then
      review.refresh_statusbar(session.view)
      review.markers.redraw_for_view(session.view, session)
    end
    utils.info("[review] comment deleted")
  end, "Delete the comment")
  map("e", function()
    local id = id_at_cursor(st); if not id then return end
    local c = session:get_comment(id)
    if not c then return end
    close()
    local loc = {
      path = c.path, side = c.side, line = c.line,
      start_line = c.start_line, subject = c.subject,
    }
    require("diffview.review.ui.comment_editor").open(session, loc, { existing_comment = c })
  end, "Edit the comment")
end

return M
