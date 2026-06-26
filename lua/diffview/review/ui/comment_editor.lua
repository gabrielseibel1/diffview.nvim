--- Inline comment editor — opens a small floating scratch buffer
--- (filetype `markdown`, modifiable, full vim editing) anchored just below
--- the commented line.
---
--- Real implementation lives in task #7. This module exposes:
---
---   open(session, location, opts) -> integer? winid
---
--- where `location` is the table returned by `review.cursor_location` and
--- `opts` may carry `{ existing_comment = ReviewComment }` for edit mode.

local lazy = require("diffview.lazy")

local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local M = {}

---@class ReviewEditorOpts
---@field existing_comment? ReviewComment

---@param session ReviewSession
---@param location table  -- output of review.cursor_location
---@param opts? ReviewEditorOpts
---@return integer? winid
---@diagnostic disable-next-line: unused-local
function M.open(session, location, opts)
  utils.warn("[review] comment editor is not yet implemented (task #7)")
  return nil
end

---Save the active editor's content as a comment on the bound session.
function M.save()
  utils.warn("[review] comment editor save is not yet implemented (task #7)")
end

---Discard the active editor without saving.
function M.cancel()
  utils.warn("[review] comment editor cancel is not yet implemented (task #7)")
end

return M
