-- WebSocket server (localhost only) that Claude connects to for IDE integration.
-- Performs the HTTP upgrade + auth, then exchanges JSON-RPC messages as frames.
local sha1 = require("claude-chat.ide.sha1")
local frame = require("claude-chat.ide.frame")
local log = require("claude-chat.log")

local M = {}

local WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

M.tcp = nil
M.port = nil
M.auth_token = nil
M.clients = {}
M.handlers = {}

-- 16 cryptographically-random bytes as 32 lowercase hex chars.
local function generate_token()
  local bytes
  local f = io.open("/dev/urandom", "rb")
  if f then
    bytes = f:read(16)
    f:close()
  end
  if not bytes or #bytes < 16 then
    -- Last-resort fallback; /dev/urandom should always exist on Linux.
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

local function parse_headers(request)
  local headers = {}
  for line in request:gmatch("[^\r\n]+") do
    local k, v = line:match("^(.-):%s*(.*)$")
    if k then
      headers[k:lower()] = v
    end
  end
  return headers
end

-- Build the HTTP 101 response, or nil + reason on failure.
local function handshake_response(request, auth_token)
  local headers = parse_headers(request)
  if auth_token and headers["x-claude-code-ide-authorization"] ~= auth_token then
    return nil, "auth token mismatch"
  end
  local key = headers["sec-websocket-key"]
  if not key then
    return nil, "missing Sec-WebSocket-Key"
  end
  local accept = vim.base64.encode(sha1.binary(key .. WS_GUID))
  return table.concat({
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Accept: " .. accept,
    "",
    "",
  }, "\r\n")
end

local function remove_client(client)
  M.clients[client] = nil
  if client.sock and not client.sock:is_closing() then
    client.sock:close()
  end
end

-- Deliver a complete JSON-RPC message to the handler (on the main loop).
local function deliver(client, data)
  vim.schedule(function()
    local ok, msg = pcall(vim.json.decode, data)
    if ok and type(msg) == "table" and M.handlers.on_message then
      M.handlers.on_message(client, msg)
    end
  end)
end

local function handle_frame(client, fr)
  local op = fr.opcode
  if op == frame.OP_CLOSE then
    remove_client(client)
    return
  elseif op == frame.OP_PING then
    client.sock:write(frame.encode(frame.OP_PONG, fr.payload))
    return
  elseif op == frame.OP_PONG then
    return
  end

  -- Text/binary/continuation: reassemble fragments until FIN.
  if op == frame.OP_TEXT or op == frame.OP_BIN then
    client.frag = fr.payload
  elseif op == frame.OP_CONT then
    client.frag = (client.frag or "") .. fr.payload
  end
  if fr.fin then
    local data = client.frag or fr.payload
    client.frag = nil
    if data and data ~= "" then
      deliver(client, data)
    end
  end
end

local function on_data(client, chunk)
  client.buf = client.buf .. chunk

  if not client.handshaked then
    local s, e = client.buf:find("\r\n\r\n", 1, true)
    if not s then
      return
    end
    local request = client.buf:sub(1, e)
    client.buf = client.buf:sub(e + 1)
    local resp, reason = handshake_response(request, M.auth_token)
    if not resp then
      log.warn("websocket handshake rejected: %s", reason or "unknown")
      remove_client(client)
      return
    end
    client.sock:write(resp)
    client.handshaked = true
    log.info("websocket handshake completed")
    if M.handlers.on_connect then
      vim.schedule(function()
        M.handlers.on_connect(client)
      end)
    end
  end

  local frames
  frames, client.buf = frame.decode(client.buf)
  for _, fr in ipairs(frames) do
    handle_frame(client, fr)
  end
end

local function on_connection(err)
  if err then
    return
  end
  local sock = vim.uv.new_tcp()
  M.tcp:accept(sock)

  local client = { sock = sock, buf = "", handshaked = false, frag = nil }
  -- Send a JSON-RPC table to this client as a text frame.
  client.send = function(obj)
    if sock:is_closing() then
      return
    end
    sock:write(frame.encode(frame.OP_TEXT, vim.json.encode(obj)))
  end
  M.clients[client] = true

  sock:read_start(function(rerr, chunk)
    if rerr or not chunk then
      remove_client(client)
      return
    end
    -- Frame decode is pure Lua and safe in this fast-event context.
    on_data(client, chunk)
  end)
end

-- Start the server. handlers = { on_message=fn(client,msg), on_connect=fn(client) }.
-- Returns port, auth_token on success, or nil + error.
function M.start(handlers)
  if M.tcp then
    return M.port, M.auth_token
  end
  M.handlers = handlers or {}
  M.auth_token = generate_token()

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
    M.auth_token = nil
    return nil, "could not bind a localhost port"
  end

  local ok, err = pcall(function()
    assert(tcp:listen(128, on_connection))
  end)
  if not ok then
    tcp:close()
    M.auth_token = nil
    return nil, "listen failed: " .. tostring(err)
  end

  M.tcp = tcp
  M.port = port
  return port, M.auth_token
end

-- Send a JSON-RPC object to every connected client.
function M.broadcast(obj)
  for client in pairs(M.clients) do
    if client.handshaked then
      pcall(client.send, obj)
    end
  end
end

function M.has_clients()
  for client in pairs(M.clients) do
    if client.handshaked then
      return true
    end
  end
  return false
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
  M.auth_token = nil
end

return M
