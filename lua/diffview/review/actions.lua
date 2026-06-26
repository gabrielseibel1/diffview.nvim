--- Top-level user actions for review sessions.
---
--- Each entry resolves the current `DiffView`, grabs its `ReviewSession` (if
--- any), and dispatches. Bound from `config.keymaps.{view,file_panel}` and
--- from the `:DiffviewReview*` commands.
---
--- Most of these are stubs in task #2 - they're filled in by tasks #6+.
--- Calling an un-implemented action prints an informative message via
--- `utils.warn` rather than throwing.

local lazy = require("diffview.lazy")

local DiffView = lazy.access("diffview.scene.views.diff.diff_view", "DiffView") ---@type DiffView|LazyModule
local lib = lazy.require("diffview.lib") ---@module "diffview.lib"
local review = lazy.require("diffview.review") ---@module "diffview.review"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local M = {}

---@return DiffView?, ReviewSession?
local function current()
  local view = lib.get_current_view()
  if not view or not view:instanceof(DiffView.__get()) then return nil end
  ---@cast view DiffView
  return view, review.session_for(view)
end

local function nyi(name)
  utils.warn(("[review] action `%s` is not yet implemented"):format(name))
end

---Start (or attach) a review session on the current DiffView.
---@param explicit_pr? integer
---@diagnostic disable-next-line: unused-local
function M.start(explicit_pr)
  nyi("start")
end

---Add a line / line-range comment at the cursor (normal or visual mode).
function M.comment_line()
  local _, session = current()
  if not session then return utils.err("[review] no active review session") end
  nyi("comment_line")
end

---Add a file-level comment on the current file.
function M.comment_file()
  local _, session = current()
  if not session then return utils.err("[review] no active review session") end
  nyi("comment_file")
end

---Toggle the reviewed checkbox on the file under the file-panel cursor.
function M.toggle_reviewed()
  local _, session = current()
  if not session then return utils.err("[review] no active review session") end
  nyi("toggle_reviewed")
end

---Open the floating list of pending comments.
function M.list_comments()
  local _, session = current()
  if not session then return utils.err("[review] no active review session") end
  nyi("list_comments")
end

---Open the submit form (radio + body buffer).
function M.submit_review()
  local _, session = current()
  if not session then return utils.err("[review] no active review session") end
  nyi("submit_review")
end

---Render the session to markdown and yank to clipboard, then offer to finish.
function M.copy_review()
  local _, session = current()
  if not session then return utils.err("[review] no active review session") end
  nyi("copy_review")
end

---Save the active inline comment editor and persist the comment.
---Bound to `<C-s>` in the editor's `review` keymap section.
function M.editor_save()
  nyi("editor_save")
end

---Discard the active inline comment editor without saving.
---Bound to `q`/`<C-c>` in the editor's `review` keymap section.
function M.editor_cancel()
  nyi("editor_cancel")
end

return M
