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
local Job = require("diffview.job").Job

local logger = lazy.access(_G, { "DiffviewGlobal", "logger" }) ---@type Logger

local uv = vim.loop

local M = {}

---@class GHRemote
---@field host  string  -- "github.com" or "github.tools.sap" (etc.)
---@field owner string
---@field repo  string

-- ───── env helpers ────────────────────────────────────────────────────

---Build a fresh env table for `gh`, overriding GH_HOST if provided.
---@param host? string
---@return table<string, string>
local function gh_env(host)
  local env = {}
  for k, v in pairs(uv.os_environ()) do env[k] = v end
  if host and host ~= "" then env.GH_HOST = host end
  -- Quiet: no pager, no colors in JSON output.
  env.GH_PAGER = ""
  env.NO_COLOR = "1"
  return env
end

-- ───── url parsing ────────────────────────────────────────────────────

---Parse a git remote URL into host/owner/repo. Returns nil on unknown shapes.
---@param url string
---@return GHRemote?
function M.parse_remote_url(url)
  if not url or url == "" then return nil end
  url = url:gsub("%.git$", ""):gsub("/+$", "")
  local host, owner, repo
  -- HTTPS first (to avoid the SSH pattern catching the `:` in `://`):
  --   https://[user@]host[:port]/owner/repo
  host, owner, repo = url:match("^https?://[^/]+@([^/:]+)[:%d]*/([^/]+)/(.+)$")
  if not host then
    host, owner, repo = url:match("^https?://([^/:]+)[:%d]*/([^/]+)/(.+)$")
  end
  if not host then
    -- SSH: git@host:owner/repo  or  ssh://git@host[:port]/owner/repo
    host, owner, repo = url:match("^ssh://[a-zA-Z_-]+@([^:/]+)[:%d]*/([^/]+)/(.+)$")
  end
  if not host then
    host, owner, repo = url:match("^[a-zA-Z_-]+@([^:/]+):([^/]+)/(.+)$")
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

-- ───── gh helpers ─────────────────────────────────────────────────────

---@class GHRunOpts
---@field args string[]      -- args passed to gh (excluding "gh" itself)
---@field host? string       -- GH_HOST override; defaults to gh's own default
---@field cwd? string
---@field stdin? string      -- optional stdin payload (e.g. JSON for `--input -`)
---@field timeout? integer   -- ms; default 15000

---Run `gh ...` synchronously, returning (stdout_lines, code, stderr_lines).
---@param opt GHRunOpts
---@return string[] stdout, integer code, string[] stderr
local function gh_sync(opt)
  ---@diagnostic disable-next-line: missing-fields
  local job = Job({
    command = "gh",
    args = opt.args,
    cwd = opt.cwd,
    env = gh_env(opt.host),
    writer = opt.stdin,
    fail_cond = function() return true end,  -- never raise, we handle the code
  })
  job:sync(opt.timeout or 15000)
  return job.stdout or {}, job.code or -1, job.stderr or {}
end

---@param stdout string[]
---@return any?
local function decode_json(stdout)
  local text = table.concat(stdout, "\n")
  if text == "" then return nil end
  local ok, val = pcall(vim.json.decode, text, { luanil = { object = true } })
  if not ok then
    logger:warn(("[review.github] failed to decode JSON: %s"):format(tostring(val)))
    return nil
  end
  return val
end

-- ───── PR detection ───────────────────────────────────────────────────

---Try `gh pr list -R o/r --head <ref> --json number --jq '.[0].number'`.
---Returns the PR number or nil.
---@param remote GHRemote
---@param head string  -- branch name or commit SHA
---@return integer?
local function detect_pr_via_pr_list(remote, head)
  local stdout, code = gh_sync({
    host = remote.host,
    args = {
      "pr", "list",
      "-R", ("%s/%s"):format(remote.owner, remote.repo),
      "--head", head,
      "--state", "open",
      "--json", "number,headRefOid",
      "--limit", "5",
    },
  })
  if code ~= 0 then return nil end
  local list = decode_json(stdout)
  if type(list) ~= "table" then return nil end
  for _, pr in ipairs(list) do
    if pr and pr.number then return tonumber(pr.number) end
  end
  return nil
end

---Fallback: `gh api /repos/o/r/commits/<sha>/pulls -H 'Accept: application/vnd.github.groot-preview+json'`.
---Returns the first open PR number or nil.
---@param remote GHRemote
---@param sha string
---@return integer?
local function detect_pr_via_commit(remote, sha)
  local stdout, code = gh_sync({
    host = remote.host,
    args = {
      "api",
      ("/repos/%s/%s/commits/%s/pulls"):format(remote.owner, remote.repo, sha),
      "-H", "Accept: application/vnd.github.groot-preview+json",
    },
  })
  if code ~= 0 then return nil end
  local list = decode_json(stdout)
  if type(list) ~= "table" then return nil end
  for _, pr in ipairs(list) do
    if pr and pr.state == "open" and pr.number then return tonumber(pr.number) end
  end
  -- Allow closed PRs too as a last resort (user may be reviewing post-hoc).
  for _, pr in ipairs(list) do
    if pr and pr.number then return tonumber(pr.number) end
  end
  return nil
end

---Detect the PR number for a head ref. Tries branch name first, falls back to SHA.
---@param remote GHRemote
---@param head_branch_or_sha string
---@param head_sha? string  -- if `head_branch_or_sha` is a branch, pass the SHA here for fallback
---@return integer?
function M.detect_pr(remote, head_branch_or_sha, head_sha)
  local pr = detect_pr_via_pr_list(remote, head_branch_or_sha)
  if pr then return pr end
  local sha = head_sha or head_branch_or_sha
  if sha:match("^[%x]+$") and #sha >= 7 then
    return detect_pr_via_commit(remote, sha)
  end
  return nil
end

-- ───── submit ─────────────────────────────────────────────────────────

---Build the JSON payload accepted by GitHub's
--- `POST /repos/{o}/{r}/pulls/{n}/reviews`.
---@param session ReviewSession
---@param event "APPROVE"|"COMMENT"|"REQUEST_CHANGES"
---@param body string
---@return table
function M.build_payload(session, event, body)
  local comments = {}
  for _, c in ipairs(session.comments) do
    local entry = { path = c.path, body = c.body }
    if c.subject == "file" then
      entry.subject_type = "file"
    else
      entry.side = c.side or "RIGHT"
      entry.line = c.line
      if c.start_line and c.start_line ~= c.line then
        entry.start_line = c.start_line
        entry.start_side = entry.side
      end
    end
    table.insert(comments, entry)
  end
  return {
    commit_id = session.commit_id,
    event = event,
    body = body or "",
    comments = comments,
  }
end

---Submit the session's review to GitHub. Returns (ok, error_message).
---@param session ReviewSession
---@param event "APPROVE"|"COMMENT"|"REQUEST_CHANGES"
---@param body string
---@return boolean ok, string? err, table? response
function M.submit_review(session, event, body)
  if session.copy_only or not session.pr then
    return false, "copy-only session: no PR to submit to"
  end
  if not (event == "APPROVE" or event == "COMMENT" or event == "REQUEST_CHANGES") then
    return false, ("invalid event: %s"):format(tostring(event))
  end
  local payload = M.build_payload(session, event, body)
  local ok_enc, json = pcall(vim.json.encode, payload)
  if not ok_enc then return false, ("failed to encode payload: %s"):format(tostring(json)) end

  local endpoint = ("/repos/%s/%s/pulls/%d/reviews"):format(
    session.owner, session.repo, session.pr
  )
  logger:lvl(5):debug(("[review.github] POST %s (%d comments)"):format(endpoint, #payload.comments))

  local stdout, code, stderr = gh_sync({
    host = session.host,
    timeout = 30000,
    stdin = json,
    args = { "api", "-X", "POST", endpoint, "--input", "-" },
  })
  if code ~= 0 then
    local msg = table.concat(stderr, "\n")
    if msg == "" then msg = table.concat(stdout, "\n") end
    return false, ("gh exited %d: %s"):format(code, msg)
  end
  local resp = decode_json(stdout)
  return true, nil, resp
end

-- ───── exposed for tests ──────────────────────────────────────────────
M._gh_env = gh_env
M._gh_sync = gh_sync
M._decode_json = decode_json

return M
