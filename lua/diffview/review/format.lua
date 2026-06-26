--- Format a ReviewSession's comments as markdown for clipboard yank.
---
--- Output shape (matches plan §"Clipboard format"):
---
---     # Review of <owner>/<repo> #<pr> — <commit_id>
---     **Event:** COMMENT
---     **Body:** <overall body>
---
---     ## path/to/file.lua
---     - L42 (RIGHT) — body
---     - L40-L42 (RIGHT) — body
---     - [FILE] — body
---
---     ## path/to/other.lua
---     - [FILE] — only file-level comment on this file

local M = {}

---@param c ReviewComment
---@return string
local function comment_line(c)
  if c.subject == "file" then
    return ("- [FILE] — %s"):format(c.body or "")
  end
  local span
  if c.start_line and c.start_line ~= c.line then
    span = ("L%d-L%d"):format(c.start_line, c.line)
  else
    span = ("L%d"):format(c.line)
  end
  return ("- %s (%s) — %s"):format(span, c.side or "RIGHT", c.body or "")
end

---Group comments by path while preserving insertion order.
---@param comments ReviewComment[]
---@return table<string, ReviewComment[]> grouped, string[] order
local function group_by_path(comments)
  local grouped = {}
  local order = {}
  for _, c in ipairs(comments) do
    if not grouped[c.path] then
      grouped[c.path] = {}
      table.insert(order, c.path)
    end
    table.insert(grouped[c.path], c)
  end
  return grouped, order
end

---@class ReviewFormatOpts
---@field event? "APPROVE"|"COMMENT"|"REQUEST_CHANGES"
---@field body?  string

---@param session ReviewSession
---@param opts? ReviewFormatOpts
---@return string
function M.render(session, opts)
  opts = opts or {}
  local parts = {}

  local short = session.pr and ("#%d"):format(session.pr) or "(local diff)"
  local header = ("# Review of %s/%s %s — %s"):format(
    session.owner, session.repo, short, session.commit_id or "?"
  )
  table.insert(parts, header)
  table.insert(parts, ("**Event:** %s"):format(opts.event or "COMMENT"))
  if opts.body and opts.body ~= "" then
    table.insert(parts, ("**Body:** %s"):format(opts.body))
  end

  -- Summary: comment counts, reviewed-files progress
  local n_left, n_right, n_file = 0, 0, 0
  for _, c in ipairs(session.comments) do
    if c.subject == "file" then n_file = n_file + 1
    elseif c.side == "LEFT" then n_left = n_left + 1
    else n_right = n_right + 1 end
  end
  table.insert(parts, ("**Comments:** %d (%d right, %d left, %d file-level)"):format(
    #session.comments, n_right, n_left, n_file))
  table.insert(parts, ("**Files reviewed:** %d/%d"):format(
    session:n_reviewed(), session.total_files or 0))
  table.insert(parts, "")

  if #session.comments == 0 then
    table.insert(parts, "_no inline comments_")
    table.insert(parts, "")
  else
    local grouped, order = group_by_path(session.comments)
    for _, path in ipairs(order) do
      table.insert(parts, ("## %s"):format(path))
      for _, c in ipairs(grouped[path]) do
        table.insert(parts, comment_line(c))
      end
      table.insert(parts, "")
    end
  end

  return table.concat(parts, "\n")
end

---Pick a usable clipboard register: prefer `+` (system clipboard) when
---a provider is loaded, fall back to `*` (selection), then `"` (unnamed).
---@return string register
function M.pick_register()
  -- The clipboard provider is set up lazily; force-load by querying.
  local has_clip = vim.fn.has("clipboard") == 1
  if has_clip then
    -- On macOS the system clipboard maps to both + and *; pick +.
    return "+"
  end
  return '"'
end

---Yank `text` to the appropriate clipboard register. Returns the register used.
---@param text string
---@return string register
function M.yank(text)
  local reg = M.pick_register()
  vim.fn.setreg(reg, text)
  -- Some users have +clipboard but no provider configured; warn but still
  -- write to the chosen register (vim.fn.setreg never errors).
  return reg
end

return M
