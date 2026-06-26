--- GitHub integration via the `gh` CLI.
---
--- Three responsibilities:
---   * detect_remote -- parse `git remote get-url origin` into {host, owner, repo}
---   * detect_pr     -- map a head branch / commit SHA to a PR number
---   * submit_review -- POST the unified review payload (event + body +
---                       inline comments) and decode the response
---
--- We always shell out to `gh` (never custom HTTPS) so the user's existing
--- credential chain (`gh auth`, SSO, the `ghe` alias for SAP) keeps working.
--- We override `GH_HOST` per call from `session.host`, so a single nvim
--- session can target both github.com and github.tools.sap.

local lazy = require("diffview.lazy")

local logger = lazy.access(_G, { "DiffviewGlobal", "logger" }) ---@type Logger
local utils = lazy.require("diffview.utils") ---@module "diffview.utils"

local M = {}

---@class GHRemote
---@field host  string  -- "github.com" or "github.tools.sap" (etc.)
---@field owner string
---@field repo  string

---Parse a git remote URL into host/owner/repo. Returns nil on unknown shapes.
---@param url string
---@return GHRemote?
function M.parse_remote_url(url)
  if not url or url == "" then return nil end
  url = url:gsub("%.git$", ""):gsub("/+$", "")
  -- SSH: git@host:owner/repo or ssh://git@host[:port]/owner/repo
  local host, owner, repo = url:match("^[a-zA-Z_-]+@([^:/]+)[:/]([^/]+)/(.+)$")
  if not host then
    -- HTTPS: https://host/owner/repo
    host, owner, repo = url:match("^https?://[^/]*[@]?([^/:]+)[:%d]*/([^/]+)/(.+)$")
  end
  if not host or not owner or not repo then return nil end
  return { host = host, owner = owner, repo = repo }
end

---Detect the remote for the current adapter's repo. Inspects `origin` by default.
---@param adapter VCSAdapter
---@param remote_name? string  -- default "origin"
---@return GHRemote?, string?  -- nil + error message if anything fails
function M.detect_remote(adapter, remote_name)
  remote_name = remote_name or "origin"
  -- We can't trust users have a `git remote get-url origin` shim; both
  -- forms (`get-url` and `--get`) work on git >= 2.0. Stay with `get-url`.
  local out, code = adapter:exec_sync(
    { "remote", "get-url", remote_name },
    { silent = true }
  )
  if code ~= 0 or not out or not out[1] then
    return nil, ("remote '%s' not found"):format(remote_name)
  end
  local parsed = M.parse_remote_url(out[1])
  if not parsed then
    return nil, ("could not parse remote URL: %s"):format(out[1])
  end
  return parsed
end

---Stub. Fills in later: shells out to `gh pr list --head <branch> ...`
---then `gh api /repos/o/r/commits/<sha>/pulls` as fallback. Returns a PR
---number or nil.
---@param remote GHRemote
---@param head_branch_or_sha string
---@return integer?
---@diagnostic disable-next-line: unused-local
function M.detect_pr(remote, head_branch_or_sha)
  -- Implemented in task #5. Returning nil here means the session falls
  -- back to copy_only mode, which is the explicit user-approved behavior
  -- when no PR is found.
  logger:lvl(5):debug("[review.github] detect_pr: not yet implemented")
  return nil
end

---Stub. Fills in later: builds the JSON payload and pipes it to
--- `gh api -X POST /repos/o/r/pulls/<n>/reviews --input -`.
---@param session ReviewSession
---@param event "APPROVE" | "COMMENT" | "REQUEST_CHANGES"
---@param body string
---@return boolean ok, string? err
---@diagnostic disable-next-line: unused-local
function M.submit_review(session, event, body)
  utils.err("[review] submit_review is not yet implemented (task #5)")
  return false, "not implemented"
end

return M
