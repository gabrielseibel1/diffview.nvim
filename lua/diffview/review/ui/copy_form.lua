--- Post-copy dialog: after `actions.copy_review` yanks the markdown to the
--- system clipboard, ask the user whether to finish the session or keep
--- going. Backed by `vim.ui.select` (no custom Panel needed).
---
--- Implemented in task #10.

local lazy = require("diffview.lazy")
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local M = {}

---@param session ReviewSession
---@param on_finish fun()
---@diagnostic disable-next-line: unused-local
function M.open(session, on_finish)
  utils.warn("[review] copy form is not yet implemented (task #10)")
end

return M
