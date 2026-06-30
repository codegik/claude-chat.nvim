local lsp = require("claude-chat.lsp_tools")

-- CI has no language server, so stub the two seams: a fake attached client and
-- canned buf_request_sync results.
local function with_lsp(responses, fn)
  local orig_clients, orig_request = lsp._get_clients, lsp._request
  lsp._get_clients = function()
    return { { id = 1, name = "fake-ls", offset_encoding = "utf-16" } }
  end
  lsp._request = function(_, method, _)
    return { [1] = { result = responses[method] } }
  end
  local ok, err = pcall(fn)
  lsp._get_clients, lsp._request = orig_clients, orig_request
  if not ok then
    error(err)
  end
end

describe("lsp_tools", function()
  local tmp, file

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    file = tmp .. "/sample.lua"
    vim.fn.writefile({ "local foo = 1", "print(foo)", "return foo" }, file)
  end)

  after_each(function()
    pcall(vim.cmd, "silent! %bwipeout!")
  end)

  it("_find_position finds a symbol on word boundaries", function()
    local bufnr = vim.fn.bufadd(file)
    vim.fn.bufload(bufnr)
    local row, col = lsp._find_position(bufnr, "foo")
    assert.equals(0, row) -- line 1 (0-based)
    assert.equals(6, col) -- "local " is 6 chars
  end)

  it("_find_position honors a line hint", function()
    local bufnr = vim.fn.bufadd(file)
    vim.fn.bufload(bufnr)
    local row = lsp._find_position(bufnr, "foo", 2)
    assert.equals(1, row) -- line 2
  end)

  it("_find_position reports a clear error when missing", function()
    local bufnr = vim.fn.bufadd(file)
    vim.fn.bufload(bufnr)
    local row, err = lsp._find_position(bufnr, "nope")
    assert.is_nil(row)
    assert.is_truthy(err:match("not found"))
  end)

  it("references returns formatted, 1-based locations", function()
    with_lsp({
      ["textDocument/references"] = {
        { uri = vim.uri_from_fname(file), range = { start = { line = 1, character = 6 } } },
        { uri = vim.uri_from_fname(file), range = { start = { line = 2, character = 7 } } },
      },
    }, function()
      local data = vim.json.decode(lsp.references({ filePath = file, symbol = "foo" }))
      assert.is_true(data.success)
      assert.equals(2, #data.references)
      assert.equals(2, data.references[1].line) -- 0-based 1 -> 1-based 2
      assert.equals(7, data.references[1].col)
      assert.equals(file, data.references[1].file)
    end)
  end)

  it("definition handles a single Location (not a list)", function()
    with_lsp({
      ["textDocument/definition"] = {
        uri = vim.uri_from_fname(file),
        range = { start = { line = 0, character = 6 } },
      },
    }, function()
      local data = vim.json.decode(lsp.definition({ filePath = file, symbol = "foo" }))
      assert.is_true(data.success)
      assert.equals(1, #data.locations)
      assert.equals(1, data.locations[1].line)
    end)
  end)

  it("hover extracts MarkupContent value", function()
    with_lsp({
      ["textDocument/hover"] = { contents = { kind = "markdown", value = "local foo: integer" } },
    }, function()
      local data = vim.json.decode(lsp.hover({ filePath = file, symbol = "foo" }))
      assert.is_true(data.success)
      assert.equals("local foo: integer", data.hover)
    end)
  end)

  it("document_symbols flattens and names kinds", function()
    with_lsp({
      ["textDocument/documentSymbol"] = {
        { name = "foo", kind = 13, range = { start = { line = 0, character = 6 } } },
      },
    }, function()
      local data = vim.json.decode(lsp.document_symbols({ filePath = file }))
      assert.is_true(data.success)
      assert.equals("foo", data.symbols[1].name)
      assert.equals("Variable", data.symbols[1].kind) -- SymbolKind 13
      assert.equals(1, data.symbols[1].line)
    end)
  end)

  it("workspace_symbols routes through an attached buffer", function()
    -- load a buffer so the (stubbed) client lookup finds one
    local bufnr = vim.fn.bufadd(file)
    vim.fn.bufload(bufnr)
    with_lsp({
      ["workspace/symbol"] = {
        {
          name = "foo",
          kind = 13,
          location = { uri = vim.uri_from_fname(file), range = { start = { line = 0, character = 6 } } },
        },
      },
    }, function()
      local data = vim.json.decode(lsp.workspace_symbols({ query = "foo" }))
      assert.is_true(data.success)
      assert.equals("foo", data.symbols[1].name)
      assert.equals(file, data.symbols[1].file)
    end)
  end)

  it("reports a clear error when no language server is attached", function()
    local orig = lsp._get_clients
    lsp._get_clients = function()
      return {}
    end
    local data = vim.json.decode(lsp.definition({ filePath = file, symbol = "foo" }))
    lsp._get_clients = orig
    assert.is_false(data.success)
    assert.is_truthy(data.message:match("no language server"))
  end)
end)
