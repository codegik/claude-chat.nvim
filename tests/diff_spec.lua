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
    -- Cancel any watchers left running so timers don't leak between tests.
    for name, entry in pairs(diff.active) do
      if entry.cancel then
        entry.cancel()
      end
      diff.active[name] = nil
    end
    pcall(vim.cmd, "silent! %bwipeout!")
  end)

  it("acknowledges immediately with FILE_SAVED without writing the file", function()
    local result
    diff.open({
      old_file_path = target,
      new_file_path = target,
      new_file_contents = "new content line\n",
      tab_name = "ack-test",
    }, function(r)
      result = r
    end)

    -- Resolved synchronously: the user confirms in the Claude console, not here,
    -- so openDiff must not block waiting on a `:w`.
    assert.is_truthy(result)
    assert.equals("FILE_SAVED", result.content[1].text)
    -- The plugin must NOT write the file (Claude performs the real write);
    -- otherwise Claude's follow-up edit fails with "file content has changed".
    assert.are.same({ "old line" }, vim.fn.readfile(target))
  end)

  it("auto-closes the preview once the file is written on disk", function()
    diff.open({
      old_file_path = target,
      new_file_path = target,
      new_file_contents = "new content line\n",
      tab_name = "autoclose-test",
    }, function() end)
    assert.is_truthy(diff.active["autoclose-test"])

    -- Simulate Claude saving the approved change (clearly different size).
    vim.fn.writefile({ "a much longer replacement line" }, target)
    vim.wait(2000, function()
      return diff.active["autoclose-test"] == nil
    end)
    assert.is_nil(diff.active["autoclose-test"])
  end)

  it("does not leak diff scratch buffers into the buffer list", function()
    diff.open({
      old_file_path = target,
      new_file_path = target,
      new_file_contents = "x",
      tab_name = "cleanup-test",
    }, function() end)
    vim.wait(50)

    -- The current/proposed panes are unlisted scratch buffers, so none of the
    -- diff buffers should show up in the listed-buffer set.
    for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
      assert.is_nil(info.name:match("cleanup%-test"))
    end
  end)

  it("q dismisses the preview without touching the file", function()
    diff.open({
      old_file_path = target,
      new_file_path = target,
      new_file_contents = "rejected change",
      tab_name = "dismiss-test",
    }, function() end)
    vim.wait(50)
    assert.is_truthy(diff.active["dismiss-test"])

    vim.api.nvim_feedkeys("q", "x", false)
    vim.wait(300, function()
      return diff.active["dismiss-test"] == nil
    end)

    assert.is_nil(diff.active["dismiss-test"])
    -- Dismissing the preview never writes the file.
    assert.are.same({ "old line" }, vim.fn.readfile(target))
  end)
end)
