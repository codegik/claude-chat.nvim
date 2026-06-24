local sessions = require("claude-chat.sessions")

describe("sessions", function()
  local tmp_home, old_home

  before_each(function()
    old_home = vim.uv.os_getenv("HOME")
    tmp_home = vim.fn.tempname()
    vim.fn.mkdir(tmp_home, "p")
    vim.fn.setenv("HOME", tmp_home)
  end)

  after_each(function()
    vim.fn.setenv("HOME", old_home)
  end)

  local function write_session(cwd, id, lines)
    local dir = sessions.dir(cwd)
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(lines, dir .. "/" .. id .. ".jsonl")
  end

  it("encodes a cwd into a project directory name", function()
    assert.equals(
      "-Users-iklassman-sources-codegik-claude-chat-nvim",
      sessions.encode_cwd("/Users/iklassman/sources/codegik/claude-chat.nvim")
    )
  end)

  it("returns an empty list when the project has no sessions", function()
    assert.are.same({}, sessions.list("/some/empty/project"))
  end)

  it("prefers aiTitle, falling back to lastPrompt then untitled", function()
    local cwd = "/p"
    write_session(cwd, "a", {
      vim.json.encode({ type = "ai-title", aiTitle = "Add the picker" }),
      vim.json.encode({ type = "last-prompt", lastPrompt = "ignored when title present" }),
    })
    write_session(cwd, "b", {
      vim.json.encode({ type = "last-prompt", lastPrompt = "only a prompt here" }),
    })
    write_session(cwd, "c", {
      vim.json.encode({ type = "mode", sessionId = "c" }),
    })

    local by_id = {}
    for _, e in ipairs(sessions.list(cwd)) do
      by_id[e.id] = e.title
    end

    assert.equals("Add the picker", by_id.a)
    assert.equals("only a prompt here", by_id.b)
    assert.equals("(untitled)", by_id.c)
  end)

  it("sorts sessions by most-recently modified first", function()
    local cwd = "/q"
    write_session(cwd, "older", { vim.json.encode({ type = "ai-title", aiTitle = "old" }) })
    write_session(cwd, "newer", { vim.json.encode({ type = "ai-title", aiTitle = "new" }) })

    local dir = sessions.dir(cwd)
    vim.uv.fs_utime(dir .. "/older.jsonl", 1000, 1000)
    vim.uv.fs_utime(dir .. "/newer.jsonl", 2000, 2000)

    local list = sessions.list(cwd)
    assert.equals("newer", list[1].id)
    assert.equals("older", list[2].id)
  end)

  it("buckets relative times", function()
    local now = 1000000
    assert.equals("just now", sessions.reltime(now - 10, now))
    assert.equals("5m ago", sessions.reltime(now - 5 * 60, now))
    assert.equals("3h ago", sessions.reltime(now - 3 * 3600, now))
    assert.equals("yesterday", sessions.reltime(now - 30 * 3600, now))
    assert.equals("4d ago", sessions.reltime(now - 4 * 86400, now))
  end)
end)
