-- In-process MCP server over HTTP (Streamable HTTP transport, stateless mode).
--
-- Why this exists: Claude Code's IDE integration (the WebSocket channel in
-- lua/claude-chat/ide/) calls tools like openFile *itself*, for its own context
-- gathering and diff UI — it does NOT expose them to the model. The only IDE
-- tools the model can call are getDiagnostics and executeCode. So "open the
-- readme" never reaches our openFile; the model just Reads the file instead.
--
-- A regular MCP server's tools, by contrast, ARE offered to the model. This
-- module is such a server, hosted *inside* Neovim and registered with the CLI
-- by URL (`--mcp-config` with type "http"). Claude's MCP client connects to it
-- directly, so open_file / current_file run in-process against the real editor —
-- no child process, no `nvim_exec_lua` back-channel.
--
-- Transport: one POST /mcp endpoint, newline-free JSON-RPC 2.0 in the body,
-- single JSON response with Content-Type: application/json. No SSE, no session
-- id — the minimal compliant subset. GET (server-initiated stream) is answered
-- 405; selection awareness still flows over the WebSocket IDE channel.
local log = require("claude-chat.log")

local M = {}

local PROTOCOL_VERSION = "2025-06-18"

M.tcp = nil
M.port = nil
M.token = nil
M.clients = {}

-- 16 cryptographically-random bytes as 32 lowercase hex chars.
local function generate_token()
  local bytes
  local f = io.open("/dev/urandom", "rb")
  if f then
    bytes = f:read(16)
    f:close()
  end
  if not bytes or #bytes < 16 then
    local t = {}
    math.randomseed(os.time() + vim.uv.hrtime() % 2 ^ 31)
    for i = 1, 16 do
      t[i] = string.char(math.random(0, 255))
    end
    bytes = table.concat(t)
  end
  return (bytes:gsub(".", function(c)
    return string.format("%02x", c:byte())
  end))
end

-- Editor tools. Mirrors what the old stdio bridge advertised; the handlers now
-- call into the editor in-process rather than over RPC.
local BASE_TOOLS = {
  {
    name = "current_file",
    description = "Ask the user's Neovim editor which file they currently have open. Returns "
      .. "JSON with the absolute path, cursor position, and any selected text. Use this "
      .. "whenever the user refers to \"this file\", \"the current file\", \"the file I'm "
      .. "looking at\", or asks what they have open — instead of guessing or asking them.",
    inputSchema = { type = "object", properties = vim.empty_dict() },
  },
  {
    name = "open_file",
    description = "Open a file in the user's Neovim editor window (the real editor, not "
      .. "the chat sidebar). Use this whenever the user asks to open, show, view, reveal, "
      .. "or go to a file, instead of reading and summarizing it. Accepts an absolute path "
      .. "or one relative to the working directory.",
    inputSchema = {
      type = "object",
      properties = {
        filePath = { type = "string", description = "Path of the file to open" },
        startText = { type = "string", description = "Optional text to position the cursor on" },
      },
      required = { "filePath" },
    },
  },
}

-- Semantic code-intelligence tools backed by the editor's live language server
-- (lua/claude-chat/lsp_tools.lua). These give the model accurate navigation the
-- IDE channel and a filesystem grep cannot.
local function symbol_schema()
  return {
    type = "object",
    properties = {
      filePath = { type = "string", description = "File containing the symbol" },
      symbol = { type = "string", description = "Name of the symbol to look up" },
      line = { type = "integer", description = "Optional 1-based line to disambiguate the occurrence" },
    },
    required = { "filePath", "symbol" },
  }
end

local LSP_TOOLS = {
  {
    name = "lsp_definition",
    description = "Jump to where a symbol is defined, using the language server. Accurate "
      .. "across the project (and into dependencies) — prefer this over grep when the user "
      .. "asks where something is defined or declared.",
    inputSchema = symbol_schema(),
  },
  {
    name = "lsp_references",
    description = "Find every reference to a symbol via the language server. Semantic and "
      .. "exact — no false matches in comments or strings, and it resolves overloads/dynamic "
      .. "dispatch that text search misses. Prefer this over Grep for \"find usages/callers\".",
    inputSchema = symbol_schema(),
  },
  {
    name = "lsp_hover",
    description = "Get the language server's hover info for a symbol — its real resolved type, "
      .. "signature, and doc comment. Prefer this over inferring a type from surrounding code.",
    inputSchema = symbol_schema(),
  },
  {
    name = "lsp_document_symbols",
    description = "List the symbols (functions, classes, methods, variables) defined in a file, "
      .. "with their kinds and line numbers — a structural outline from the language server.",
    inputSchema = {
      type = "object",
      properties = { filePath = { type = "string", description = "File to outline" } },
      required = { "filePath" },
    },
  },
  {
    name = "lsp_workspace_symbols",
    description = "Search the whole project for a symbol by name via the language server. "
      .. "Faster and more precise than scanning files — prefer this to locate a definition "
      .. "by name when you don't know which file it's in.",
    inputSchema = {
      type = "object",
      properties = { query = { type = "string", description = "Symbol name or fragment to search for" } },
      required = { "query" },
    },
  },
}

-- Whether LSP tools are advertised (set by start()).
M.lsp_enabled = true

local function tool_list()
  if not M.lsp_enabled then
    return BASE_TOOLS
  end
  local all = {}
  vim.list_extend(all, BASE_TOOLS)
  vim.list_extend(all, LSP_TOOLS)
  return all
end

local function text_content(s)
  return { content = { { type = "text", text = s } } }
end

local function call_tool(name, args)
  args = args or {}
  if name == "open_file" then
    local tools = require("claude-chat.ide.tools")
    return text_content(tostring(tools.open_in_editor(args.filePath, args.startText)))
  elseif name == "current_file" then
    local tools = require("claude-chat.ide.tools")
    return text_content(tostring(tools.current_file()))
  end

  -- LSP tools all return a JSON string.
  local lsp = require("claude-chat.lsp_tools")
  local lsp_handlers = {
    lsp_definition = lsp.definition,
    lsp_references = lsp.references,
    lsp_hover = lsp.hover,
    lsp_document_symbols = lsp.document_symbols,
    lsp_workspace_symbols = lsp.workspace_symbols,
  }
  local handler = lsp_handlers[name]
  if handler then
    return text_content(handler(args))
  end
  return text_content("Unknown tool: " .. tostring(name))
end

-- Dispatch a JSON-RPC message. Returns a response table, or nil for
-- notifications (no id) that take no reply.
local function handle_message(msg)
  local method = msg.method
  local id = msg.id

  if method == "initialize" then
    return {
      jsonrpc = "2.0",
      id = id,
      result = {
        protocolVersion = PROTOCOL_VERSION,
        capabilities = { tools = vim.empty_dict() },
        serverInfo = { name = "claude-chat", version = "0.1.0" },
      },
    }
  elseif method == "notifications/initialized" or method == "initialized" then
    return nil
  elseif method == "tools/list" then
    return { jsonrpc = "2.0", id = id, result = { tools = tool_list() } }
  elseif method == "tools/call" then
    local params = msg.params or {}
    local ok, result = pcall(call_tool, params.name, params.arguments)
    return {
      jsonrpc = "2.0",
      id = id,
      result = ok and result or text_content("Error: " .. tostring(result)),
    }
  elseif method == "ping" then
    return { jsonrpc = "2.0", id = id, result = vim.empty_dict() }
  elseif id ~= nil then
    return {
      jsonrpc = "2.0",
      id = id,
      error = { code = -32601, message = "Method not found: " .. tostring(method) },
    }
  end
  return nil
end

local function parse_headers(head)
  local headers = {}
  for line in head:gmatch("[^\r\n]+") do
    local k, v = line:match("^(.-):%s*(.*)$")
    if k then
      headers[k:lower()] = v
    end
  end
  return headers
end

-- Build an HTTP response. body may be nil (no payload).
local function http_response(status, body, content_type)
  local lines = { "HTTP/1.1 " .. status }
  if body then
    lines[#lines + 1] = "Content-Type: " .. (content_type or "application/json")
    lines[#lines + 1] = "Content-Length: " .. #body
  else
    lines[#lines + 1] = "Content-Length: 0"
  end
  lines[#lines + 1] = "MCP-Protocol-Version: " .. PROTOCOL_VERSION
  lines[#lines + 1] = "Connection: keep-alive"
  lines[#lines + 1] = ""
  lines[#lines + 1] = body or ""
  return table.concat(lines, "\r\n")
end

local function jsonrpc_error(id, code, message)
  return vim.json.encode({ jsonrpc = "2.0", id = id, error = { code = code, message = message } })
end

-- Runs on the main loop (vim.schedule): auth, dispatch, write the reply.
local function handle_request(client, req)
  local sock = client.sock
  if sock:is_closing() then
    return
  end

  if M.token and req.headers["authorization"] ~= ("Bearer " .. M.token) then
    sock:write(http_response("401 Unauthorized"))
    return
  end

  if req.method ~= "POST" then
    -- We do not push server-initiated messages over this channel (awareness
    -- uses the WebSocket IDE channel), so a GET stream is not supported.
    sock:write(http_response("405 Method Not Allowed"))
    return
  end

  local ok, msg = pcall(vim.json.decode, req.body)
  if not ok or type(msg) ~= "table" then
    sock:write(http_response("200 OK", jsonrpc_error(nil, -32700, "Parse error")))
    return
  end

  local response = handle_message(msg)
  if response == nil then
    -- Notification: accepted, no body.
    sock:write(http_response("202 Accepted"))
    return
  end
  sock:write(http_response("200 OK", vim.json.encode(response)))
end

-- Parse complete HTTP requests out of the buffer (header block + Content-Length
-- body), handing each to the main loop. Keep-alive: loops for pipelined requests.
local function on_data(client)
  while true do
    local s, e = client.buf:find("\r\n\r\n", 1, true)
    if not s then
      return
    end
    local head = client.buf:sub(1, e)
    local headers = parse_headers(head)
    local clen = tonumber(headers["content-length"]) or 0
    if #client.buf - e < clen then
      return -- body not fully arrived yet
    end
    local body = client.buf:sub(e + 1, e + clen)
    client.buf = client.buf:sub(e + clen + 1)

    local request_line = head:match("^(.-)\r\n") or head
    local method = request_line:match("^(%S+)")
    local req = { method = method, headers = headers, body = body }
    vim.schedule(function()
      handle_request(client, req)
    end)
  end
end

local function remove_client(client)
  M.clients[client] = nil
  if client.sock and not client.sock:is_closing() then
    client.sock:close()
  end
end

local function on_connection(err)
  if err then
    return
  end
  local sock = vim.uv.new_tcp()
  M.tcp:accept(sock)
  local client = { sock = sock, buf = "" }
  M.clients[client] = true
  sock:read_start(function(rerr, chunk)
    if rerr or not chunk then
      remove_client(client)
      return
    end
    client.buf = client.buf .. chunk
    -- HTTP parsing is pure Lua and safe in this fast-event context; the
    -- dispatch that touches vim.api is deferred to the main loop.
    on_data(client)
  end)
end

-- Start the server on a random localhost port. opts.lsp (default true) controls
-- whether the LSP code-intelligence tools are advertised. Returns port, token on
-- success, or nil + error.
function M.start(opts)
  M.lsp_enabled = not (opts and opts.lsp == false)
  if M.tcp then
    return M.port, M.token
  end
  M.token = generate_token()

  math.randomseed(os.time() + (vim.uv.hrtime() % 2 ^ 31))
  local tcp, port
  for _ = 1, 200 do
    local p = math.random(10000, 65535)
    local s = vim.uv.new_tcp()
    local ok = pcall(function()
      assert(s:bind("127.0.0.1", p))
    end)
    if ok then
      tcp, port = s, p
      break
    end
    s:close()
  end
  if not tcp then
    M.token = nil
    return nil, "could not bind a localhost port"
  end

  local ok, err = pcall(function()
    assert(tcp:listen(128, on_connection))
  end)
  if not ok then
    tcp:close()
    M.token = nil
    return nil, "listen failed: " .. tostring(err)
  end

  M.tcp = tcp
  M.port = port
  log.info("mcp http server listening on 127.0.0.1:%d", port)
  return port, M.token
end

function M.stop()
  for client in pairs(M.clients) do
    remove_client(client)
  end
  M.clients = {}
  if M.tcp and not M.tcp:is_closing() then
    M.tcp:close()
  end
  M.tcp = nil
  M.port = nil
  M.token = nil
end

return M
