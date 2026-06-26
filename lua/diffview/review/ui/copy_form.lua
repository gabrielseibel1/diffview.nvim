--- Post-copy dialog.
---
--- Asks the user whether to finish the session after a successful clipboard
--- yank. Implemented via `vim.ui.select` for portability — no custom Panel
--- needed; whatever ui-select provider the user has (default, dressing,
--- snacks, telescope-ui-select, etc.) will pick it up.

local M = {}

---@param session ReviewSession
---@param on_finish fun()  -- called when the user picks "Finish session"
function M.open(session, on_finish)
  -- `session` is unused for now; reserved for future "summary" rendering.
  vim.ui.select(
    { "Keep working", "Finish session" },
    {
      prompt = ("Review copied (%d comments). Finish this session?"):format(#session.comments),
      kind = "diffview.review.copy",
    },
    function(choice)
      if choice == "Finish session" and on_finish then
        on_finish()
      end
    end
  )
end

return M
