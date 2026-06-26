--- File-panel decoration patches for the active review session:
---   * prepend `[x] ` / `[ ] ` to each file row (reviewed checkbox)
---   * set `winbar` to `  <pr-or-branch>  | N comments | k/M reviewed`
---
--- This module is monkey-patched onto `views/diff/render.lua:render_file`
--- from `diffview.review.setup()` so the change is purely additive — no
--- edit to the core render file is required.
---
--- Implemented in task #9.

local M = {}

---Idempotent install. No-op stub until task #9.
function M.install()
end

return M
