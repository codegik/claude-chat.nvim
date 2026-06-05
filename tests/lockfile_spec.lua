local lockfile = require("claude-chat.ide.lockfile")

describe("ide.lockfile", function()
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

  it("writes a discovery lock file with the expected fields", function()
    assert.is_true(lockfile.write(54321, "deadbeefcafebabe", "/some/project"))

    local path = lockfile.path(54321)
    assert.equals(tmp_home .. "/.claude/ide/54321.lock", path)
    assert.equals(1, vim.fn.filereadable(path))

    local data = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    assert.equals("deadbeefcafebabe", data.authToken)
    assert.equals("ws", data.transport)
    assert.equals("Neovim", data.ideName)
    assert.are.same({ "/some/project" }, data.workspaceFolders)
    assert.is_truthy(data.pid)
  end)

  it("removes the lock file", function()
    lockfile.write(54321, "tok", "/p")
    local path = lockfile.path(54321)
    assert.equals(1, vim.fn.filereadable(path))
    lockfile.remove(54321)
    assert.equals(0, vim.fn.filereadable(path))
  end)
end)
