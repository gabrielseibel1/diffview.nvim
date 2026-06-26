--- Floating panel listing all pending comments in the current session.
---
--- Subclasses `Panel` with `default_type = "float"`, modelled on
--- `CommitLogPanel`. One row per comment: `path:Lline(SIDE)  body[:40]`.
--- Bindings: `<CR>` jump to the file+line, `d` delete, `e` edit.
---
--- Implemented in task #10. This module currently exports a function-style
--- open() stub so callers can require it without errors.

local lazy = require("diffview.lazy")
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local M = {}

---@param session ReviewSession
---@diagnostic disable-next-line: unused-local
function M.open(session)
  utils.warn("[review] comment list panel is not yet implemented (task #10)")
end

return M
