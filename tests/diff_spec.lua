local diff = require("claude-chat.ide.diff")

describe("ide.diff", function()
  local tmp, target

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    target = tmp .. "/orig.txt"
    vim.fn.writefile({ "old line" }, target)
  end)

  after_each(function()
    pcall(vim.cmd, "silent! %bwipeout!")
  end)

  it("accepts on :w and returns FILE_SAVED without writing the file itself", function()
    local result
    diff.open({
      old_file_path = target,
      new_file_path = target,
      new_file_contents = "new line\n",
      tab_name = "accept-test",
    }, function(r)
      result = r
    end)
    vim.wait(150)

    -- The proposed buffer is the focused one; saving it accepts the diff.
    vim.cmd("silent write")
    vim.wait(300, function()
      return result ~= nil
    end)

    assert.is_truthy(result)
    assert.equals("FILE_SAVED", result.content[1].text)
    -- The plugin must NOT write the file (Claude does the real write); otherwise
    -- Claude's follow-up edit fails with "file content has changed".
    assert.are.same({ "old line" }, vim.fn.readfile(target))
  end)

  it("does not list or leave stray buffers behind", function()
    local before = #vim.fn.getbufinfo({ buflisted = 1 })
    local result
    diff.open({
      old_file_path = target,
      new_file_path = target,
      new_file_contents = "x",
      tab_name = "cleanup-test",
    }, function(r)
      result = r
    end)
    vim.wait(150)
    vim.cmd("silent write")
    vim.wait(300, function()
      return result ~= nil
    end)
    -- The diff used unlisted scratch buffers, so the listed-buffer count is
    -- unchanged after it closes.
    assert.equals(before, #vim.fn.getbufinfo({ buflisted = 1 }))
  end)

  it("rejects on q and returns DIFF_REJECTED", function()
    local result
    diff.open({
      old_file_path = target,
      new_file_path = target,
      new_file_contents = "rejected change",
      tab_name = "reject-test",
    }, function(r)
      result = r
    end)
    vim.wait(150)

    vim.api.nvim_feedkeys("q", "x", false)
    vim.wait(300, function()
      return result ~= nil
    end)

    assert.is_truthy(result)
    assert.equals("DIFF_REJECTED", result.content[1].text)
    -- File untouched.
    assert.are.same({ "old line" }, vim.fn.readfile(target))
  end)
end)
