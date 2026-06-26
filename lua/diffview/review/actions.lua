--- Top-level user actions for review sessions.
---
--- Each entry resolves the current `DiffView`, grabs its `ReviewSession`
--- (if any), and dispatches. Bound from `config.keymaps.{view,file_panel,
--- review}` and from the `:DiffviewReview*` commands.

local lazy = require("diffview.lazy")

local DiffView = lazy.access("diffview.scene.views.diff.diff_view", "DiffView") ---@type DiffView|LazyModule
local SessionMod = lazy.require("diffview.review.session") ---@module "diffview.review.session"
local comment_editor = lazy.require("diffview.review.ui.comment_editor") ---@module "diffview.review.ui.comment_editor"
local comment_list = lazy.require("diffview.review.ui.comment_list") ---@module "diffview.review.ui.comment_list"
local copy_form = lazy.require("diffview.review.ui.copy_form") ---@module "diffview.review.ui.copy_form"
local format = lazy.require("diffview.review.format") ---@module "diffview.review.format"
local github = lazy.require("diffview.review.github") ---@module "diffview.review.github"
local lib = lazy.require("diffview.lib") ---@module "diffview.lib"
local logger = lazy.access(_G, { "DiffviewGlobal", "logger" }) ---@type Logger
local review = lazy.require("diffview.review") ---@module "diffview.review"
local submit_form = lazy.require("diffview.review.ui.submit_form") ---@module "diffview.review.ui.submit_form"
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local api = vim.api

local M = {}

-- ───── view + session resolution ──────────────────────────────────────

---@return DiffView?, ReviewSession?
local function current()
  local view = lib.get_current_view()
  if not view or not view:instanceof(DiffView.__get()) then return nil end
  ---@cast view DiffView
  return view, review.session_for(view)
end

---Same as `current` but errors with a uniform message when no DiffView.
---@return DiffView?, ReviewSession?
local function require_view()
  local view, session = current()
  if not view then
    utils.err("[review] no active DiffView")
    return nil
  end
  return view, session
end

---@param view DiffView
---@return ReviewSession?
local function require_session(view)
  local s = review.session_for(view)
  if not s then
    utils.err("[review] no active review session — run :DiffviewReviewStart")
    return nil
  end
  return s
end

-- ───── cursor → (path, side, line[, start_line], subject) ─────────────

---@class ReviewCursorLocation
---@field path       string                  -- repo-relative
---@field side?      "LEFT"|"RIGHT"          -- nil for file-panel subjects
---@field line?      integer                 -- 1-based; nil for file subject
---@field start_line? integer                -- inclusive start; nil = single
---@field subject    "line"|"file"

---Resolve the current cursor position into a comment location.
---
---When the cursor is in the file panel we always return a file-subject
---location (subject="file", no side/line). When in a diff window we return
---a line-subject location with the side detected from the layout.
---
---@param view DiffView
---@param force_subject? "line"|"file"  -- if set, override auto-detect
---@return ReviewCursorLocation?
function M.cursor_location(view, force_subject)
  local winid = api.nvim_get_current_win()
  local layout = view.cur_layout

  -- File panel: pick the entry under the cursor.
  if view.panel:is_focused() then
    local entry = view:infer_cur_file()
    if not entry or type(entry.collapsed) == "boolean" then return nil end
    return {
      path = entry.path,
      side = nil,
      subject = "file",
    }
  end

  -- Diff window: detect side and line.
  if not (layout and layout.a and layout.b) then return nil end
  local side
  if winid == layout.a.id then
    side = "LEFT"
  elseif winid == layout.b.id then
    side = "RIGHT"
  else
    -- Cursor is in a third/fourth window of a diff3/diff4 layout. Treat
    -- it as the right side for now — that's where conflict-resolution
    -- lives and is the most useful default.
    side = "RIGHT"
  end

  local cur = view.cur_entry
  if not cur then return nil end
  local path = cur.path
  if side == "LEFT" and cur.oldpath and cur.oldpath ~= "" then
    path = cur.oldpath
  end

  -- Visual range -> {start_line, line}; otherwise single line.
  -- Inside visual mode the `'<>'` marks aren't set yet, so we use the
  -- live `v`/`.` marks via nvim_buf_get_mark.
  local mode = api.nvim_get_mode().mode
  local in_visual = mode == "v" or mode == "V" or mode == "\22"
  local start_line, line
  if in_visual then
    local sm = api.nvim_buf_get_mark(0, "v")
    local em = api.nvim_buf_get_mark(0, ".")
    if sm[1] > 0 and em[1] > 0 then
      start_line = math.min(sm[1], em[1])
      line = math.max(sm[1], em[1])
    end
  end
  if not line then
    line = api.nvim_win_get_cursor(winid)[1]
  end
  if start_line == line then start_line = nil end

  if force_subject == "file" then
    return { path = path, subject = "file" }
  end

  return {
    path = path,
    side = side,
    line = line,
    start_line = start_line,
    subject = "line",
  }
end

-- ───── start ──────────────────────────────────────────────────────────

---@param view DiffView
---@param explicit_pr? integer
---@return ReviewSession?, string?
local function build_session(view, explicit_pr)
  local adapter = view.adapter
  if not adapter then return nil, "view has no VCS adapter" end

  -- PR head SHA = view.right.commit (preferred), falling back to HEAD.
  local commit_id = view.right and view.right.commit
  if not commit_id or commit_id == "" then
    local out, code = adapter:exec_sync({ "rev-parse", "HEAD" }, { silent = true })
    if code ~= 0 or not out or not out[1] then return nil, "could not resolve HEAD" end
    commit_id = out[1]
  end

  local remote, rerr = github.detect_remote(adapter)
  if not remote then
    -- Allow copy_only with a synthetic local marker so the session still works.
    return SessionMod.new({
      view = view, owner = "local", repo = "local", host = "local",
      pr = nil, commit_id = commit_id, total_files = view.files:len(),
      copy_only = true,
    }), rerr
  end

  local pr = explicit_pr
  if not pr then
    -- Get current branch for the head-ref lookup.
    local branch
    local out, code = adapter:exec_sync(
      { "symbolic-ref", "--quiet", "--short", "HEAD" }, { silent = true }
    )
    if code == 0 and out and out[1] then branch = out[1] end
    pr = github.detect_pr(remote, branch or commit_id, commit_id)
  end

  local opt = {
    view = view, owner = remote.owner, repo = remote.repo, host = remote.host,
    pr = pr, commit_id = commit_id, total_files = view.files:len(),
    copy_only = pr == nil,
  }
  -- Try to hydrate from disk first (only matters when we have a PR).
  local hydrated = pr and SessionMod.load(opt)
  return hydrated or SessionMod.new(opt)
end

---Start (or attach) a review session on the current DiffView.
---@param explicit_pr? integer
function M.start(explicit_pr)
  local view = require_view()
  if not view then return end
  local existing = review.session_for(view)
  if existing then
    utils.info(("[review] session already attached (%s, %d comments)"):format(
      existing:short_id(), #existing.comments))
    return
  end
  local s, err = build_session(view, explicit_pr)
  if not s then
    utils.err(("[review] could not start session: %s"):format(err or "unknown"))
    return
  end
  review.register_session(view, s)
  -- Re-render the file panel so the checkbox + status bar light up.
  if view.panel and view.panel:is_open() then
    view.panel:render()
    view.panel:redraw()
    review.refresh_statusbar(view)
  end
  if s.copy_only then
    utils.info(("[review] started in copy-only mode (%s)"):format(err or "no PR detected"))
  else
    utils.info(("[review] attached to PR #%d (%d comments restored)"):format(s.pr, #s.comments))
  end
  DiffviewGlobal.emitter:emit("review_started", s)
end

-- ───── comment_line / comment_file ────────────────────────────────────

---Internal: open the editor at the resolved location.
---@param view DiffView
---@param session ReviewSession
---@param force_subject? "line"|"file"
local function open_editor_at_cursor(view, session, force_subject)
  local loc = M.cursor_location(view, force_subject)
  if not loc then
    utils.err("[review] could not resolve cursor location")
    return
  end
  comment_editor.open(session, loc, {})
end

---Add a line / line-range comment at the cursor (normal or visual mode).
function M.comment_line()
  local view = require_view(); if not view then return end
  local session = require_session(view); if not session then return end
  -- If invoked while the file panel is focused, treat it as a file-subject
  -- comment (tuicr: `c` on a panel row comments on that file).
  local force = view.panel:is_focused() and "file" or nil
  open_editor_at_cursor(view, session, force)
end

---Add a file-level comment on the current file.
function M.comment_file()
  local view = require_view(); if not view then return end
  local session = require_session(view); if not session then return end
  open_editor_at_cursor(view, session, "file")
end

-- ───── toggle_reviewed ────────────────────────────────────────────────

---Toggle the reviewed checkbox on the file under the cursor.
function M.toggle_reviewed()
  local view = require_view(); if not view then return end
  local session = require_session(view); if not session then return end

  local path
  if view.panel:is_focused() then
    local entry = view:infer_cur_file()
    if not entry or type(entry.collapsed) == "boolean" then
      utils.err("[review] no file under cursor")
      return
    end
    path = entry.path
  else
    path = view.cur_entry and view.cur_entry.path
  end
  if not path then return end

  local now_reviewed = session:toggle_reviewed(path)
  logger:lvl(5):debug(("[review] %s -> reviewed=%s"):format(path, tostring(now_reviewed)))
  if view.panel:is_open() then
    view.panel:render()
    view.panel:redraw()
    review.refresh_statusbar(view)
  end
end

-- ───── list / submit / copy ───────────────────────────────────────────

---Open the floating list of pending comments.
function M.list_comments()
  local view = require_view(); if not view then return end
  local session = require_session(view); if not session then return end
  comment_list.open(session)
end

---Open the submit form.
function M.submit_review()
  local view = require_view(); if not view then return end
  local session = require_session(view); if not session then return end
  if session.copy_only then
    utils.err("[review] copy-only session — no PR to submit to")
    return
  end
  submit_form.open(session)
end

---Render the session to markdown and yank to clipboard, then offer to finish.
function M.copy_review()
  local view = require_view(); if not view then return end
  local session = require_session(view); if not session then return end
  local text = format.render(session, { event = "COMMENT" })
  local reg = format.yank(text)
  DiffviewGlobal.emitter:emit("review_copied", session)
  utils.info(("[review] copied %d-byte review to %s register"):format(#text, reg))
  copy_form.open(session, function() M.close_session() end)
end

-- ───── editor save / cancel (forward to comment_editor) ───────────────

function M.editor_save()
  comment_editor.save()
end
function M.editor_cancel()
  comment_editor.cancel()
end

-- ───── close_session ──────────────────────────────────────────────────

---Drop the review session attached to the current view (in-memory).
function M.close_session()
  local view = require_view(); if not view then return end
  local session = review.session_for(view)
  if not session then return end
  if not session.copy_only then session:save() end
  review.unregister_session(view)
  if view.panel and view.panel:is_open() then
    view.panel:render()
    view.panel:redraw()
    review.refresh_statusbar(view)
  end
  DiffviewGlobal.emitter:emit("review_closed", session)
  utils.info(("[review] session %s closed (%d comments)"):format(
    session:short_id(), #session.comments))
end

return M
