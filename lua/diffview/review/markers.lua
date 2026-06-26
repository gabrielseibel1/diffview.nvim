--- Inline extmark-based comment markers on the diff buffers.
---
--- Owns a single dedicated namespace (per nvim session, not per ReviewSession;
--- one is plenty since we only ever render markers for the current session).
---
--- Rendering is driven by two hooks (wired in `diffview.review`'s setup):
---   * `DiffviewGlobal.emitter:on("diff_buf_win_enter", ...)` - file shown
---   * `view.emitter:on("file_open_post", ...)`               - file swapped
--- Both call `M.redraw(session, bufnr, side)` which clears the namespace on
--- that buffer and re-places signs + truncated virt_lines preview per comment.
---
--- Implementation lives in task #8 - this module is the seam.

local M = {}

---@type integer
M.ns = vim.api.nvim_create_namespace("diffview_review_markers")

---Clear all markers from `bufnr`.
---@param bufnr integer
function M.clear(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
end

---Redraw markers for one buffer / one side. No-op stub until task #8.
---@param session ReviewSession?
---@param bufnr integer
---@param side "LEFT"|"RIGHT"
---@diagnostic disable-next-line: unused-local
function M.redraw(session, bufnr, side)
  if not session or not bufnr then return end
  -- Filled in by task #8.
end

return M
