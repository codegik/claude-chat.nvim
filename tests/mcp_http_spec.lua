local mcp_http = require("claude-chat.mcp_http")

-- POST a JSON-RPC message to the live HTTP server and return the parsed reply
-- (or the raw response for non-JSON cases). headers defaults to a valid bearer.
local function post(port, token, msg, opts)
  opts = opts or {}
  local body = type(msg) == "string" and msg or vim.json.encode(msg)
  local auth = opts.token == false and "" or ("Authorization: Bearer " .. (opts.token or token) .. "\r\n")
  local request = table.concat({
    (opts.method or "POST") .. " /mcp HTTP/1.1\r\n",
    "Host: 127.0.0.1\r\n",
    auth,
    "Content-Type: application/json\r\n",
    "Content-Length: " .. #body .. "\r\n",
    "\r\n",
    body,
  })

  local sock = vim.uv.new_tcp()
  local buf, done = "", false
  sock:connect("127.0.0.1", port, function()
    sock:write(request)
    sock:read_start(function(err, chunk)
      if chunk then
        buf = buf .. chunk
        if buf:find("\r\n\r\n", 1, true) then
          done = true
        end
      elseif err then
        done = true
      end
    end)
  end)
  vim.wait(2000, function()
    return done
  end)
  if not sock:is_closing() then
    sock:close()
  end
  return buf
end

-- Split an HTTP response into its status line and decoded JSON body.
local function parse(raw)
  local status = raw:match("^HTTP/1%.1 ([^\r\n]+)")
  local s = raw:find("\r\n\r\n", 1, true)
  local body = s and raw:sub(s + 4) or ""
  local ok, decoded = pcall(vim.json.decode, body)
  return status, (ok and decoded or nil), body
end

describe("mcp_http (live socket)", function()
  local port, token

  before_each(function()
    require("claude-chat.config").setup()
    port, token = mcp_http.start()
    assert.is_truthy(port, "server should bind a port")
  end)

  after_each(function()
    mcp_http.stop()
  end)

  it("rejects a request with no/wrong bearer token", function()
    local raw = post(port, token, { jsonrpc = "2.0", id = 1, method = "ping" }, { token = false })
    assert.is_truthy(raw:match("^HTTP/1%.1 401"))
  end)

  it("answers initialize with the protocol version", function()
    local status, reply = parse(post(port, token, {
      jsonrpc = "2.0",
      id = 1,
      method = "initialize",
      params = {},
    }))
    assert.is_truthy(status:match("^200"))
    assert.equals("2025-06-18", reply.result.protocolVersion)
    assert.equals("claude-chat", reply.result.serverInfo.name)
  end)

  it("advertises the editor and LSP tools", function()
    local _, reply = parse(post(port, token, { jsonrpc = "2.0", id = 2, method = "tools/list" }))
    local names = {}
    for _, t in ipairs(reply.result.tools) do
      names[t.name] = true
    end
    assert.is_true(names["open_file"])
    assert.is_true(names["current_file"])
    assert.is_true(names["lsp_definition"])
    assert.is_true(names["lsp_references"])
    assert.is_true(names["lsp_hover"])
    assert.is_true(names["lsp_document_symbols"])
    assert.is_true(names["lsp_workspace_symbols"])
  end)

  it("answers a notification with 202 and no body", function()
    local raw = post(port, token, { jsonrpc = "2.0", method = "notifications/initialized" })
    assert.is_truthy(raw:match("^HTTP/1%.1 202"))
  end)

  it("rejects GET (no server-initiated stream) with 405", function()
    local raw = post(port, token, "", { method = "GET" })
    assert.is_truthy(raw:match("^HTTP/1%.1 405"))
  end)

  it("open_file opens the file in a real editor window", function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    local target = tmp .. "/open_me.txt"
    vim.fn.writefile({ "alpha", "beta" }, target)
    vim.cmd("enew") -- a normal editor window to receive the file

    local _, reply = parse(post(port, token, {
      jsonrpc = "2.0",
      id = 3,
      method = "tools/call",
      params = { name = "open_file", arguments = { filePath = target } },
    }))
    assert.is_truthy(reply.result.content[1].text:match("Opened"))
    assert.equals(vim.fs.normalize(target), vim.fs.normalize(vim.api.nvim_buf_get_name(0)))

    pcall(vim.cmd, "silent! %bwipeout!")
  end)

  it("returns a JSON-RPC error for unknown methods", function()
    local _, reply = parse(post(port, token, { jsonrpc = "2.0", id = 4, method = "frobnicate" }))
    assert.is_truthy(reply.error)
    assert.equals(-32601, reply.error.code)
  end)
end)
