# Review sessions

`diffview.nvim` ships a tuicr-style PR review system on top of the diff
view. Open any diff (typically `:DiffviewOpen origin/main...`), start a
review, and accumulate inline comments locally before submitting them as
a single GitHub review — or yank the whole thing as markdown.

## Quick start

```vim
:DiffviewOpen origin/main...HEAD --imply-local
:DiffviewReviewStart
```

`DiffviewReviewStart` auto-detects the PR via `gh pr list --head <branch>`
and falls back to the head SHA. If no PR is found you still get a
**copy-only** session — you can build the review locally and yank it
with `<leader>jy`.

## Default bindings

All review bindings use the `<leader>j` prefix to stay out of common
`<leader>c…` / `<leader>r…` namespaces that LSP and code-action plugins
often claim.

In a diff buffer or the file panel:

| Key           | Action                                          |
|---------------|-------------------------------------------------|
| `<leader>jc`  | Comment on current line (works in visual range) |
| `<leader>jC`  | Comment on the current file (subject = file)    |
| `<leader>jl`  | Open the pending-comments list                  |
| `<leader>js`  | Open the submit form                            |
| `<leader>jy`  | Yank the review to clipboard                    |

File panel only:

| Key           | Action                                          |
|---------------|-------------------------------------------------|
| `c`           | Comment on the file under the cursor            |
| `C`           | File-subject comment on the file under cursor   |
| `<leader>jR`  | Toggle the `[x] / [ ]` reviewed checkbox        |

Inside the inline comment editor:

| Key / cmd       | Action                                                |
|-----------------|-------------------------------------------------------|
| —               | Opens in insert mode at the body line                 |
| `<C-s>`         | Save the comment and close (works in normal & insert) |
| `:w`, `:write`  | Same as `<C-s>` — save and close                      |
| `q`, `<C-c>`    | Discard the comment and close                         |
| `:q`, `:quit`   | Same as `q` — discard and close (no `E37` block)      |
| `:wq`           | Save and close                                        |

## Commands

| Command                       | Notes                                           |
|-------------------------------|-------------------------------------------------|
| `:DiffviewReviewStart [pr]`   | `pr` overrides auto-detection                   |
| `:DiffviewReviewSubmit`       | Opens the submit form (event + body)            |
| `:DiffviewReviewCopy`         | Yanks the markdown review to the clipboard      |
| `:DiffviewReviewList`         | Opens the pending-comments list                 |

## Submit form

`<C-s>` submits with the chosen event:

* `1` — APPROVE
* `2` — COMMENT (default)
* `3` — REQUEST_CHANGES
* `<Tab>` — cycle

On success the on-disk draft is removed, the session detaches, and the
PR review URL is reported.

## How it talks to GitHub

All GitHub calls go through `gh`. `GH_HOST` is set per call from the
remote's host (`github.com`, `github.tools.sap`, etc.) so the same nvim
session can review across hosts without any token plumbing in
diffview itself.

The submit POSTs a single
`/repos/{owner}/{repo}/pulls/{n}/reviews` with the unified
`{commit_id, event, body, comments[]}` payload.

## Persistence

Drafts are saved (debounced, atomic write+rename) to:

```
<stdpath('data')>/diffview/reviews/<host>__<owner>__<repo>__<pr>.json
```

Closing the DiffView (or quitting nvim) preserves the draft; the next
`:DiffviewReviewStart` on the same PR reloads it. On successful submit
the file is deleted. Copy-only sessions are never persisted.

## Configuration

```lua
require("diffview").setup({
  review = {
    enabled = true,            -- master toggle
    auto_attach = false,       -- start a session on every DiffviewOpen
    editor_style = "float",    -- "float" | "split" (split is reserved)
    max_editor_height = 12,    -- comment-editor auto-grow limit
    persistence_dir = nil,     -- override draft dir; nil -> stdpath('data')/diffview/reviews
    border = "rounded",        -- all review float borders
    status_template = "  Review %s  │ %d comments │ %d/%d reviewed",
    sign_text = "C",           -- gutter sign on commented lines
  },
})
```

## Highlights

| Group                          | Default link              |
|--------------------------------|---------------------------|
| `DiffviewReviewReviewed`       | `DiffviewStatusAdded`     |
| `DiffviewReviewPending`        | `Comment`                 |
| `DiffviewReviewMark`           | `DiagnosticInfo`          |
| `DiffviewReviewMarkPreview`    | `Comment`                 |

## User autocmd patterns

* `User DiffviewReviewStarted`
* `User DiffviewReviewSubmitted`
* `User DiffviewReviewCopied`
* `User DiffviewReviewClosed`

## Limitations (v1)

* Loading existing GitHub-side comments is not implemented yet.
* No reply threading / suggestion-block preview.
* One review session per DiffView tabpage.
