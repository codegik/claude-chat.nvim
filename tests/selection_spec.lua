local selection = require("claude-chat.ide.selection")

describe("ide.selection", function()
  local tmp, file

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    file = tmp .. "/main.lua"
    vim.fn.writefile({ "local x = 1", "return x" }, file)
  end)

  after_each(function()
    selection.stop()
    pcall(vim.cmd, "silent! %bwipeout!")
  end)

  it("prime seeds the open-file context from a buffer", function()
    -- Load the file into a buffer but do NOT make it the focused window,
    -- mimicking the sidebar stealing focus.
    local buf = vim.fn.bufadd(file)
    vim.fn.bufload(buf)

    local emitted = {}
    selection.start(function(p)
      emitted[#emitted + 1] = p
    end)
    selection.prime(buf)

    local cur = selection.get()
    assert.is_truthy(cur)
    assert.equals(file, cur.filePath)
    assert.equals("file://" .. file, cur.fileUrl)
    assert.is_true(cur.selection.isEmpty)
    -- prime should have emitted a selection_changed payload
    assert.is_true(#emitted >= 1)
    assert.equals(file, emitted[#emitted].filePath)
  end)

  it("prime ignores non-file buffers", function()
    local scratch = vim.api.nvim_create_buf(false, true)
    selection.start(function() end)
    selection.prime(scratch)
    assert.is_nil(selection.get())
  end)
end)
