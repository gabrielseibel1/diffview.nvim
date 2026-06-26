--- Submit form (floating window).
---
--- Two visual zones:
---   * a "radio" row near the top with three options (APPROVE / COMMENT /
---     REQUEST_CHANGES). Switching the selection cycles through them with
---     <Tab> or 1/2/3.
---   * a markdown-editable body buffer below for the overall review text.
---
--- We use a single buffer for both: the radio row is in the first two
--- lines (a header + the options) and we keep them non-modifiable by
--- marking the buffer modifiable only for the body region — actually,
--- since v1 keeps things simple, the WHOLE buffer is modifiable, but
--- save() reads the body starting from the body marker line. The user
--- can tweak the event indicator if they want; we'll re-parse it on save.
---
--- Bindings:
---   <C-s>     submit
---   <Tab>     cycle event APPROVE -> COMMENT -> REQUEST_CHANGES
---   1, 2, 3   pick event directly
---   q, <esc>  cancel

local lazy = require("diffview.lazy")

local config = lazy.require("diffview.config") ---@module "diffview.config"
local github = lazy.require("diffview.review.github") ---@module "diffview.review.github"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api
local M = {}

---@type { win: integer, buf: integer, session: ReviewSession, event: string }?
local active = nil

local EVENTS = { "APPROVE", "COMMENT", "REQUEST_CHANGES" }

local function close()
  if not active then return end
  local st = active
  active = nil
  if api.nvim_win_is_valid(st.win) then pcall(api.nvim_win_close, st.win, true) end
  if api.nvim_buf_is_valid(st.buf) then pcall(api.nvim_buf_delete, st.buf, { force = true }) end
end

---@return integer width, integer height, integer row, integer col
local function geometry()
  local w = math.min(100, math.max(60, math.floor(vim.o.columns * 0.6)))
  local h = math.min(18, math.max(10, math.floor(vim.o.lines * 0.4)))
  local row = math.floor((vim.o.lines - h) * 0.5)
  local col = math.floor((vim.o.columns - w) * 0.5)
  return w, h, row, col
end

---@param st table
local function render_header(st)
  vim.bo[st.buf].modifiable = true
  local n = #st.session.comments
  local header_lines = {
    (" Submit review on PR #%d  │  %d inline comment%s")
      :format(st.session.pr or 0, n, n == 1 and "" or "s"),
    (" Event: %s   (1/2/3 or <Tab> to switch; <C-s> submit; q cancel)")
      :format(st.event),
    "",
    " ── body ────────────────────────────────────────────────",
  }
  -- Preserve any body the user has already typed below the header.
  local existing = api.nvim_buf_get_lines(st.buf, 0, -1, false)
  local body
  if #existing == 0 then
    body = {}
  else
    -- Find the existing body marker line; everything below it is the body.
    local marker_at
    for i, l in ipairs(existing) do
      if l:match("^ ── body") then marker_at = i; break end
    end
    body = marker_at and { unpack(existing, marker_at + 1) } or {}
  end
  local all = {}
  for _, l in ipairs(header_lines) do table.insert(all, l) end
  for _, l in ipairs(body) do table.insert(all, l) end
  if #body == 0 then table.insert(all, "") end
  api.nvim_buf_set_lines(st.buf, 0, -1, false, all)
  -- Place cursor on the first body line on first render
  pcall(api.nvim_win_set_cursor, st.win, { #header_lines + 1, 0 })
end

local function set_event(st, ev)
  st.event = ev
  render_header(st)
end

local function read_body(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local marker_at
  for i, l in ipairs(lines) do
    if l:match("^ ── body") then marker_at = i; break end
  end
  if not marker_at then return "" end
  local body = { unpack(lines, marker_at + 1) }
  while #body > 0 and body[1] == "" do table.remove(body, 1) end
  while #body > 0 and body[#body] == "" do table.remove(body, #body) end
  return table.concat(body, "\n")
end

local function do_submit(st)
  local body = read_body(st.buf)
  if st.event == "REQUEST_CHANGES" and body == "" and #st.session.comments == 0 then
    utils.warn("[review] REQUEST_CHANGES requires either an overall body or inline comments")
    return
  end
  utils.info(("[review] submitting %s on PR #%d (%d comments)..."):format(
    st.event, st.session.pr, #st.session.comments))
  local ok, err, resp = github.submit_review(st.session, st.event, body)
  if not ok then
    utils.err(("[review] submit failed: %s"):format(err or "unknown"))
    return
  end
  close()
  -- Clean up persisted draft.
  st.session:delete_storage()
  -- Detach the session from the view.
  local review = require("diffview.review")
  review.unregister_session(st.session.view)
  if st.session.view and st.session.view.panel and st.session.view.panel.is_open
      and st.session.view.panel:is_open() then
    st.session.view.panel:render()
    st.session.view.panel:redraw()
    review.refresh_statusbar(st.session.view)
    review.markers.clear(0)  -- best-effort; full clear happens on file swap
  end
  DiffviewGlobal.emitter:emit("review_submitted", st.session)
  local url = (resp and resp.html_url) or ""
  utils.info(("[review] submitted ✓  %s"):format(url))
end

---@param session ReviewSession
function M.open(session)
  if active then close() end
  if session.copy_only or not session.pr then
    utils.err("[review] cannot submit a copy-only session")
    return
  end

  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  pcall(function() vim.bo[buf].filetype = "markdown" end)

  local w, h, row, col = geometry()
  local border = (config.get_config().review or {}).border or "rounded"
  local win = api.nvim_open_win(buf, true, {
    relative = "editor", row = row, col = col, width = w, height = h,
    style = "minimal", border = border, title = " submit review ", title_pos = "left",
  })

  local st = { win = win, buf = buf, session = session, event = "COMMENT" }
  active = st
  render_header(st)

  local map = function(modes, lhs, fn, desc)
    if type(modes) ~= "table" then modes = { modes } end
    for _, mode in ipairs(modes) do
      vim.keymap.set(mode, lhs, fn, { buffer = buf, silent = true, nowait = true, desc = desc })
    end
  end
  map("n", "q", close, "Cancel")
  map("n", "<esc>", close, "Cancel")
  map({ "n", "i" }, "<C-c>", close, "Cancel")
  map({ "n", "i" }, "<C-s>", function() do_submit(st) end, "Submit")
  map("n", "<Tab>", function()
    for i, ev in ipairs(EVENTS) do
      if ev == st.event then
        set_event(st, EVENTS[(i % #EVENTS) + 1]); return
      end
    end
  end, "Cycle event")
  map("n", "1", function() set_event(st, "APPROVE") end, "APPROVE")
  map("n", "2", function() set_event(st, "COMMENT") end, "COMMENT")
  map("n", "3", function() set_event(st, "REQUEST_CHANGES") end, "REQUEST_CHANGES")
end

return M
