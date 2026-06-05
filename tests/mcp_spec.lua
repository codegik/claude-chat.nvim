local mcp = require("claude-chat.ide.mcp")
local selection = require("claude-chat.ide.selection")

-- Drive an MCP request through a fake client and return the single reply.
local function call(method, params)
  local out = {}
  local client = { send = function(o)
    out[#out + 1] = o
  end }
  mcp.handle(client, { jsonrpc = "2.0", id = 1, method = method, params = params })
  vim.wait(500, function()
    return #out > 0
  end)
  return out[1]
end

local function tool(name, args)
  local reply = call("tools/call", { name = name, arguments = args or {} })
  return vim.json.decode(reply.result.content[1].text), reply
end

describe("ide.mcp + tools", function()
  local tmp, file

  before_each(function()
    require("claude-chat.config").setup({ ide_diff = true })
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    file = tmp .. "/README.md"
    vim.fn.writefile({ "line one", "line two", "line three" }, file)
    vim.cmd("edit " .. vim.fn.fnameescape(file))
    vim.cmd("cd " .. vim.fn.fnameescape(tmp))
    selection.start(function() end)
    vim.wait(200)
  end)

  after_each(function()
    selection.stop()
    pcall(vim.cmd, "silent! %bwipeout!")
  end)

  it("initialize returns protocol version and server info", function()
    local r = call("initialize", {}).result
    assert.equals("2025-03-26", r.protocolVersion)
    assert.equals("claude-chat.nvim", r.serverInfo.name)
    assert.is_truthy(r.capabilities.tools)
  end)

  local function tool_names()
    local names = {}
    for _, t in ipairs(call("tools/list", {}).result.tools) do
      names[t.name] = true
    end
    return names
  end

  it("tools/list advertises the editor tools", function()
    local names = tool_names()
    assert.is_true(names["getOpenEditors"])
    assert.is_true(names["getCurrentSelection"])
    assert.is_true(names["getWorkspaceFolders"])
    assert.is_true(names["getDiagnostics"])
    assert.is_true(names["openFile"])
  end)

  it("advertises diff tools only when ide_diff is enabled", function()
    require("claude-chat.config").setup({ ide_diff = true })
    assert.is_true(tool_names()["openDiff"])

    require("claude-chat.config").setup({ ide_diff = false })
    local names = tool_names()
    assert.is_nil(names["openDiff"])
    assert.is_nil(names["close_tab"])
    -- read tools remain available
    assert.is_true(names["getOpenEditors"])

    require("claude-chat.config").setup({ ide_diff = true })
  end)

  it("getOpenEditors reports the active file", function()
    local data = tool("getOpenEditors")
    assert.equals(1, #data.tabs)
    assert.equals("README.md", data.tabs[1].label)
    assert.is_true(data.tabs[1].isActive)
    assert.equals("markdown", data.tabs[1].languageId)
  end)

  it("getCurrentSelection reports the open file path", function()
    local data = tool("getCurrentSelection")
    assert.is_true(data.success)
    assert.equals(file, data.filePath)
    assert.is_truthy(data.selection.start)
  end)

  it("getWorkspaceFolders returns the cwd", function()
    local data = tool("getWorkspaceFolders")
    assert.is_true(data.success)
    assert.equals(vim.fn.getcwd(), data.rootPath)
    assert.equals(vim.fn.getcwd(), data.folders[1].path)
  end)

  it("checkDocumentDirty reflects buffer state", function()
    local clean = tool("checkDocumentDirty", { filePath = file })
    assert.is_true(clean.success)
    assert.is_false(clean.isDirty)

    vim.api.nvim_buf_set_lines(0, 0, 0, false, { "dirty edit" })
    local dirty = tool("checkDocumentDirty", { filePath = file })
    assert.is_true(dirty.isDirty)
  end)

  it("checkDocumentDirty fails for a file that is not open", function()
    local data = tool("checkDocumentDirty", { filePath = "/no/such/file.txt" })
    assert.is_false(data.success)
    assert.is_truthy(data.message:match("Document not open"))
  end)

  it("returns a JSON-RPC error for unknown methods", function()
    local reply = call("frobnicate", {})
    assert.is_truthy(reply.error)
    assert.equals(-32601, reply.error.code)
  end)
end)
