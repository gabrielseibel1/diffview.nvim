local helpers = require("diffview.tests.helpers")
local eq = helpers.eq

describe("diffview.review", function()
  local Sess = require("diffview.review.session")
  local format = require("diffview.review.format")
  local github = require("diffview.review.github")
  local actions = require("diffview.review.actions")

  -- Make sure the test environment has a config (some helpers read it
  -- via config.get_config). setup() is idempotent.
  before_each(function()
    require("diffview.config").setup({
      review = { persistence_dir = "/tmp/diffview_review_test_spec" },
    })
    os.execute("rm -rf /tmp/diffview_review_test_spec")
  end)

  describe("github.parse_remote_url", function()
    it("parses SSH (user@host:owner/repo) URLs", function()
      eq(
        { host = "github.com", owner = "gabrielseibel1", repo = "diffview.nvim" },
        github.parse_remote_url("git@github.com:gabrielseibel1/diffview.nvim.git")
      )
      eq(
        { host = "github.tools.sap", owner = "CI-DS", repo = "cids" },
        github.parse_remote_url("git@github.tools.sap:CI-DS/cids.git")
      )
    end)

    it("parses HTTPS URLs (with and without .git, trailing slashes)", function()
      eq(
        { host = "github.com", owner = "gabrielseibel1", repo = "diffview.nvim" },
        github.parse_remote_url("https://github.com/gabrielseibel1/diffview.nvim.git")
      )
      eq(
        { host = "github.com", owner = "sindrets", repo = "diffview.nvim" },
        github.parse_remote_url("https://github.com/sindrets/diffview.nvim")
      )
      eq(
        { host = "github.tools.sap", owner = "bdc-fos", repo = "cids-kyma" },
        github.parse_remote_url("https://github.tools.sap/bdc-fos/cids-kyma/")
      )
    end)

    it("parses ssh:// scheme URLs", function()
      eq(
        { host = "github.tools.sap", owner = "bdc-fos", repo = "cids-kyma" },
        github.parse_remote_url("ssh://git@github.tools.sap:22/bdc-fos/cids-kyma.git")
      )
    end)

    it("returns nil on garbage", function()
      eq(nil, github.parse_remote_url(""))
      eq(nil, github.parse_remote_url("not a url"))
      eq(nil, github.parse_remote_url("http://host"))
    end)
  end)

  describe("github.build_payload", function()
    it("emits the expected shape for each comment kind", function()
      local session = {
        owner = "o", repo = "r", host = "h", pr = 42,
        commit_id = "deadbeef", copy_only = false,
        comments = {
          { path = "a.lua", side = "RIGHT", line = 10, subject = "line", body = "single" },
          { path = "a.lua", side = "RIGHT", start_line = 5, line = 7, subject = "line", body = "range" },
          { path = "b.lua", side = "LEFT", line = 3, subject = "line", body = "left" },
          { path = "c.lua", subject = "file", body = "file-level", line = 0 },
        },
      }
      local p = github.build_payload(session, "COMMENT", "overall")
      eq("COMMENT", p.event)
      eq("deadbeef", p.commit_id)
      eq("overall", p.body)
      eq(4, #p.comments)
      eq({ path = "a.lua", side = "RIGHT", line = 10, body = "single" }, p.comments[1])
      eq(
        { path = "a.lua", side = "RIGHT", line = 7, start_line = 5, start_side = "RIGHT", body = "range" },
        p.comments[2]
      )
      eq({ path = "b.lua", side = "LEFT", line = 3, body = "left" }, p.comments[3])
      eq({ path = "c.lua", subject_type = "file", body = "file-level" }, p.comments[4])
    end)
  end)

  describe("Session", function()
    local function fake_view() return { tabpage = 1 } end

    local function fresh(opts)
      opts = vim.tbl_extend("force", {
        view = fake_view(), owner = "o", repo = "r", host = "h",
        pr = 1, commit_id = "abc", total_files = 5,
      }, opts or {})
      return Sess.new(opts)
    end

    it("appends, finds, updates, and deletes comments", function()
      local s = fresh()
      local id = s:add_comment{ path = "x", side = "RIGHT", line = 1, subject = "line", body = "first" }
      eq(1, #s.comments)
      eq("first", s:get_comment(id).body)
      eq(true, s:update_comment(id, { body = "edited" }))
      eq("edited", s:get_comment(id).body)
      eq(true, s:delete_comment(id))
      eq(0, #s.comments)
      eq(false, s:delete_comment("missing"))
    end)

    it("toggles reviewed flags and counts", function()
      local s = fresh()
      eq(true, s:toggle_reviewed("a"))
      eq(true, s:toggle_reviewed("b"))
      eq(2, s:n_reviewed())
      eq(false, s:toggle_reviewed("a"))
      eq(1, s:n_reviewed())
      eq(true, s:is_reviewed("b"))
      eq(false, s:is_reviewed("a"))
    end)

    it("renders the status bar", function()
      local s = fresh()
      s:add_comment{ path = "x", side = "RIGHT", line = 1, subject = "line", body = "c" }
      s:toggle_reviewed("x")
      local bar = s:render_statusbar()
      assert.truthy(bar:find("Review #1"))
      assert.truthy(bar:find("1 comments"))
      assert.truthy(bar:find("1/5 reviewed"))
    end)

    it("round-trips through disk (save + load)", function()
      local s = fresh()
      s:add_comment{ path = "x", side = "RIGHT", line = 7, subject = "line", body = "hello" }
      s:toggle_reviewed("x")
      s:save()
      local loaded = Sess.load({
        view = fake_view(), owner = "o", repo = "r", host = "h",
        pr = 1, commit_id = "abc", total_files = 5,
      })
      assert.truthy(loaded, "expected load() to return a session")
      eq(1, #loaded.comments)
      eq("hello", loaded.comments[1].body)
      eq(true, loaded:is_reviewed("x"))
    end)

    it("does not persist copy_only sessions", function()
      local s = fresh({ copy_only = true })
      s:add_comment{ path = "x", side = "RIGHT", line = 1, subject = "line", body = "c" }
      s:save()
      eq(nil, Sess._storage_path(s))
    end)
  end)

  describe("format.render", function()
    it("renders header, summary, and per-file sections", function()
      local s = Sess.new({
        view = { tabpage = 1 }, owner = "gabrielseibel1", repo = "diffview.nvim",
        host = "github.com", pr = 7, commit_id = "abc", total_files = 2, copy_only = true,
      })
      s:add_comment{ path = "foo", side = "RIGHT", line = 1, subject = "line", body = "hi" }
      s:add_comment{ path = "foo", side = "RIGHT", start_line = 5, line = 8, subject = "line", body = "range" }
      s:add_comment{ path = "foo", subject = "file", body = "wow", line = 0 }
      s:toggle_reviewed("foo")
      local out = format.render(s, { event = "COMMENT", body = "overall" })
      assert.truthy(out:find("# Review of gabrielseibel1/diffview%.nvim #7"))
      assert.truthy(out:find("%*%*Event:%*%* COMMENT"))
      assert.truthy(out:find("%*%*Body:%*%* overall"))
      assert.truthy(out:find("%*%*Comments:%*%* 3"))
      assert.truthy(out:find("%*%*Files reviewed:%*%* 1/2"))
      assert.truthy(out:find("## foo"))
      assert.truthy(out:find("L1 %(RIGHT%) — hi"))
      assert.truthy(out:find("L5%-L8 %(RIGHT%) — range"))
      assert.truthy(out:find("%[FILE%] — wow"))
    end)

    it("renders an empty-session placeholder", function()
      local s = Sess.new({
        view = { tabpage = 1 }, owner = "o", repo = "r", host = "h",
        pr = 1, commit_id = "abc", total_files = 0, copy_only = true,
      })
      local out = format.render(s, {})
      assert.truthy(out:find("_no inline comments_"))
    end)
  end)

  describe("actions.cursor_location", function()
    it("returns a file subject when the panel is focused", function()
      local fake_view = {
        panel = { is_focused = function() return true end },
        infer_cur_file = function() return { path = "foo.lua" } end,
        cur_layout = nil,
      }
      local loc = actions.cursor_location(fake_view)
      eq("file", loc.subject)
      eq("foo.lua", loc.path)
      eq(nil, loc.side)
    end)

    it("returns a line subject from a diff window", function()
      local cur = vim.api.nvim_get_current_win()
      local fake_view = {
        panel = { is_focused = function() return false end },
        cur_entry = { path = "foo.lua", oldpath = nil },
        cur_layout = { a = { id = 0 }, b = { id = cur } },
      }
      local loc = actions.cursor_location(fake_view)
      eq("line", loc.subject)
      eq("foo.lua", loc.path)
      eq("RIGHT", loc.side)
      assert.truthy(loc.line and loc.line >= 1)
    end)

    it("uses oldpath on LEFT-side renamed files", function()
      local cur = vim.api.nvim_get_current_win()
      local fake_view = {
        panel = { is_focused = function() return false end },
        cur_entry = { path = "new.lua", oldpath = "old.lua" },
        cur_layout = { a = { id = cur }, b = { id = 0 } },
      }
      local loc = actions.cursor_location(fake_view)
      eq("LEFT", loc.side)
      eq("old.lua", loc.path)
    end)
  end)
end)
