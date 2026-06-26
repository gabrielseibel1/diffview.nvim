if vim.g.diffview_nvim_loaded or not require("diffview.bootstrap") then
  return
end

vim.g.diffview_nvim_loaded = 1

local lazy = require("diffview.lazy")

---@module "diffview"
local arg_parser = lazy.require("diffview.arg_parser") ---@module "diffview.arg_parser"
local diffview = lazy.require("diffview") ---@module "diffview"

local api = vim.api
local command = api.nvim_create_user_command

-- NOTE: Need this wrapper around the completion function becuase it doesn't
-- exist yet.
local function completion(...)
  return diffview.completion(...)
end

-- Create commands
command("DiffviewOpen", function(ctx)
  diffview.open(arg_parser.scan(ctx.args).args)
end, { nargs = "*", complete = completion })

command("DiffviewFileHistory", function(ctx)
  local range

  if ctx.range > 0 then
    range = { ctx.line1, ctx.line2 }
  end

  diffview.file_history(range, arg_parser.scan(ctx.args).args)
end, { nargs = "*", complete = completion, range = true })

command("DiffviewClose", function()
  diffview.close()
end, { nargs = 0, bang = true })

command("DiffviewFocusFiles", function()
  diffview.emit("focus_files")
end, { nargs = 0, bang = true })

command("DiffviewToggleFiles", function()
  diffview.emit("toggle_files")
end, { nargs = 0, bang = true })

command("DiffviewRefresh", function()
  diffview.emit("refresh_files")
end, { nargs = 0, bang = true })

command("DiffviewLog", function()
  vim.cmd(("sp %s | norm! G"):format(
    vim.fn.fnameescape(DiffviewGlobal.logger.outfile)
  ))
end, { nargs = 0, bang = true })

command("DiffviewReviewStart", function(ctx)
  -- ctx.args is a single token or empty. Pass `nil` for autodetect and
  -- the parsed integer otherwise.
  local pr = nil
  local arg = ctx.args and ctx.args:match("^%s*(.-)%s*$")
  if arg and arg ~= "" then
    pr = tonumber(arg)
    if not pr then
      vim.notify(
        ("[diffview.review] invalid PR number: %s"):format(arg),
        vim.log.levels.ERROR
      )
      return
    end
  end
  require("diffview.review.actions").start(pr)
end, { nargs = "?", bang = true, desc = "Start a review session on the current DiffView" })

command("DiffviewReviewSubmit", function()
  require("diffview.review.actions").submit_review()
end, { nargs = 0, bang = true, desc = "Open the review submit form" })

command("DiffviewReviewCopy", function()
  require("diffview.review.actions").copy_review()
end, { nargs = 0, bang = true, desc = "Yank the current review to the clipboard" })

command("DiffviewReviewList", function()
  require("diffview.review.actions").list_comments()
end, { nargs = 0, bang = true, desc = "Open the pending review comments list" })
