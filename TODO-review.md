# Review-sessions — pre-merge TODO

Things to address before this branch is ready to upstream.

## Bugs to investigate

- **`Lua callback: [+7](1)` error** — observed when the comment-list float
  was open with an empty session. The `[+N](M)` shape resembles a
  bufname/winnr pair printed via `nvim_err_writeln`, but headless
  reproductions of every visible interaction (`<CR>` / `d` / `e` / `q`)
  on an empty list come back clean. Likely candidates to instrument:
    * `comment_list.lua:130` — the LEFT-side jump fallback's
      `and ... or ...` chain has a precedence subtlety worth simplifying
      to an explicit `if` statement.
    * Floats opened over each other (list ↔ submit ↔ editor) — confirm
      that closing one doesn't leave a dangling `active` state in another.
    * `BufLeave` autocmd in `comment_editor.lua:176` schedules a cancel,
      which races with `WinClosed` on `:179`; both can fire on a single
      close and call `close_active()` twice.
  Next step: turn on `:lua DiffviewGlobal.debug_level = 10`, repro the
  exact sequence that triggered the error, and capture the log.

- **Stale `<leader>cc` hint** in the empty comment-list — FIXED in
  51cbf26.

## UI polish

- **Float borders / titles** — current titles (` review comments `,
  ` submit review `, ` comment `) render fine on `border = "rounded"`
  but look cramped on `"single"` / `"double"`. Add a small leading +
  trailing space pad that scales with the border style.
- **Comment-list cursor placement** — first item lands at col 2, but
  the visible row has 2 leading spaces; consider `{ 3, 4 }` so the
  cursor sits on the first identifier (path char) rather than the
  whitespace prefix.
- **Comment-list highlights** — every row is plain `Normal`. Worth
  adding:
    * path segment → `Directory`
    * `Lline (SIDE)` span → `Number` / `Identifier`
    * body excerpt → `Comment`
    * `[FILE]` marker → `Special`
- **Submit form** — the "marker line" `── body ─` is a string literal
  that doesn't scale with the float width. Compute the dashes from
  `nvim_win_get_width`.
- **Editor header line** — currently `# foo.lua:L4 (RIGHT)`. Could be
  rendered as virt_text on a hidden first line so the user's actual
  body always starts at row 1 and the header isn't accidentally
  edited / saved.
- **Status bar template** — `  Review #42  │ 2 comments │ 1/16 reviewed`
  is fine on a wide panel but gets clipped on `file_panel.win_config.
  width = 35`. Consider a shorter token vocab when width is constrained,
  or wrap to a second winbar line.
- **Reviewed checkbox** — `[x]` / `[ ]` is functional but eats 4 columns
  of every file row. A single-glyph alternative (e.g. `✓` vs `·`) would
  reclaim 2 cols and look cleaner in `listing_style = "tree"`.
- **Inline comment marker preview** — virt_lines preview shows the first
  60 chars of the body's first line. Could show the comment author
  (placeholder when local: "(draft)") and a count badge when multiple
  comments stack on the same line.

## UX gaps

- **No "edit comment" entry point from the diff window** — currently
  only via the list float's `e`. Add a binding (e.g. `<leader>je`) that
  finds the comment under the cursor (matching path+side+line) and
  re-opens the editor on it.
- **No way to navigate between markers** — add `]c` / `[c` to jump to
  next/prev comment within the current file, mirroring the conflict
  navigator's `]x` / `[x`.
- **Visual-range comments** — works, but exits the visual range
  silently. Verify the `'<>'` marks are still set after save so the
  user can `gv` back into their selection.
- **Submit form body** — no draft persistence. If the user spends 5
  minutes on the overall body, hits `q`, the text is gone. Either
  persist it on the session (`session.draft_body`) or warn before
  discard when non-empty.
- **PR auto-detect failure feedback** — when no PR matches the head
  branch, we silently drop to copy-only mode and emit one
  `vim.notify`. Worth offering a small `vim.ui.input` to enter a PR
  number on the spot.
- **Confirm before submit** — currently `<C-s>` in the submit form
  fires the API call immediately. Add a confirmation step when
  `event = APPROVE` (most destructive — irreversible without a
  follow-up review).
- **Session reload on branch switch** — `:DiffviewReviewStart` reloads
  the saved draft for the current PR, but if the user switches branches
  / re-runs `:DiffviewOpen` against a different rev, the in-memory
  session may stale. Hook `DiffviewViewClosed` to drop the session
  cleanly (already done) and verify start-over works.

## Tests to add

- Persistence: corruption recovery (truncated JSON, malformed schema).
- Renamed-file LEFT-side path: end-to-end (FileEntry.oldpath → payload).
- GH `detect_pr` fallback path (the `commits/<sha>/pulls` branch) — needs
  a stubbed `Job` factory.
- The `[+7](1)` error reproduction once we know what triggers it.

## Documentation

- Add a screencast / GIF to README showing the workflow.
- Reference the v1 limitations more prominently (no upstream comment
  loading, no thread replies, no suggestion blocks).
- Document the `User DiffviewReview*` autocmds with usage examples
  (e.g. a snippet that posts to a Slack webhook on
  `DiffviewReviewSubmitted`).

## Out of scope (v2+)

- Load existing GitHub-side review comments and render them in a
  different highlight group alongside local pending ones.
- Reply to existing review threads (`POST /pulls/{n}/comments/{id}/replies`).
- Render ```suggestion blocks inline.
- Resolve / re-request review actions.
