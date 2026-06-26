--- Floating submit form: radio selection for the review event
--- (APPROVE / COMMENT / REQUEST_CHANGES) plus a multi-line markdown body
--- buffer with real vim editing. `<C-s>` invokes
--- `review.github.submit_review(session, event, body)`.
---
--- Implemented in task #10.

local lazy = require("diffview.lazy")
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local M = {}

---@param session ReviewSession
---@diagnostic disable-next-line: unused-local
function M.open(session)
  utils.warn("[review] submit form is not yet implemented (task #10)")
end

return M
