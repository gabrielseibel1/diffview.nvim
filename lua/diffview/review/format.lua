--- Format a ReviewSession's comments as markdown for clipboard yank.
---
--- Output shape (matches plan §"Clipboard format"):
---
---     # Review of <repo>#<pr> - <commit_id>
---     **Event:** COMMENT
---     **Body:** <overall body>
---
---     ## path/to/file.lua
---     - L42 (RIGHT) - body
---     - L40-L42 (RIGHT) - body
---
---     ## path/to/other.lua (FILE)
---     - body

local M = {}

---@param c ReviewComment
---@return string
local function comment_line(c)
  if c.subject == "file" then
    return ("- %s"):format(c.body)
  end
  local span
  if c.start_line and c.start_line ~= c.line then
    span = ("L%d-L%d"):format(c.start_line, c.line)
  else
    span = ("L%d"):format(c.line)
  end
  return ("- %s (%s) - %s"):format(span, c.side, c.body)
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
  local header = ("# Review of %s/%s %s - %s"):format(
    session.owner, session.repo, short, session.commit_id or "?"
  )
  table.insert(parts, header)
  table.insert(parts, ("**Event:** %s"):format(opts.event or "COMMENT"))
  if opts.body and opts.body ~= "" then
    table.insert(parts, ("**Body:** %s"):format(opts.body))
  end
  table.insert(parts, "")

  local grouped, order = group_by_path(session.comments)
  for _, path in ipairs(order) do
    local has_file_only = false
    for _, c in ipairs(grouped[path]) do
      if c.subject == "file" then has_file_only = true; break end
    end
    local suffix = (has_file_only and #grouped[path] == 1) and " (FILE)" or ""
    table.insert(parts, ("## %s%s"):format(path, suffix))
    for _, c in ipairs(grouped[path]) do
      table.insert(parts, comment_line(c))
    end
    table.insert(parts, "")
  end

  return table.concat(parts, "\n")
end

return M
