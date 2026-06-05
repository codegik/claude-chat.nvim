local server = require("claude-chat.ide.server")
local mcp = require("claude-chat.ide.mcp")
local frame = require("claude-chat.ide.frame")
local sha1 = require("claude-chat.ide.sha1")
local bit = require("bit")

local WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

local function request(token, key)
  return table.concat({
    "GET / HTTP/1.1",
    "Host: 127.0.0.1",
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: " .. key,
    "Sec-WebSocket-Version: 13",
    "x-claude-code-ide-authorization: " .. token,
    "",
    "",
  }, "\r\n")
end

-- Masked text frame (clients must mask).
local function mask_encode(payload)
  local mask = { 0x12, 0x34, 0x56, 0x78 }
  local n = #payload
  local header = string.char(bit.bor(0x80, frame.OP_TEXT), bit.bor(0x80, n))
  local mk = string.char(mask[1], mask[2], mask[3], mask[4])
  local out = {}
  for i = 1, n do
    out[i] = string.char(bit.bxor(payload:byte(i), mask[((i - 1) % 4) + 1]))
  end
  return header .. mk .. table.concat(out)
end

describe("ide.server (live socket)", function()
  local port, token

  before_each(function()
    port, token = server.start({
      on_message = function(client, msg)
        mcp.handle(client, msg)
      end,
    })
    assert.is_truthy(port, "server should bind a port")
  end)

  after_each(function()
    server.stop()
  end)

  it("rejects a connection with the wrong auth token", function()
    local sock = vim.uv.new_tcp()
    local received, closed = "", false
    sock:connect("127.0.0.1", port, function()
      sock:write(request("0000000000000000", "AAAAAAAAAAAAAAAAAAAAAA=="))
      sock:read_start(function(err, chunk)
        if chunk then
          received = received .. chunk
        end
        if err or not chunk then
          closed = true
        end
      end)
    end)
    vim.wait(1500, function()
      return closed
    end)
    if not sock:is_closing() then
      sock:close()
    end
    assert.is_true(closed, "server should close the unauthorized connection")
    assert.is_nil(received:match("101"))
  end)

  it("completes the handshake and answers initialize over the socket", function()
    local key = "dGhlIHNhbXBsZSBub25jZQ=="
    local expected_accept = vim.base64.encode(sha1.binary(key .. WS_GUID))

    local sock = vim.uv.new_tcp()
    local buf, handshook = "", false
    local result = { status_ok = false, accept_ok = false, messages = {} }

    sock:connect("127.0.0.1", port, function()
      sock:write(request(token, key))
      sock:read_start(function(err, chunk)
        if err or not chunk then
          return
        end
        buf = buf .. chunk
        if not handshook then
          local s, e = buf:find("\r\n\r\n", 1, true)
          if not s then
            return
          end
          local header = buf:sub(1, e)
          result.status_ok = header:match("HTTP/1%.1 101") ~= nil
          result.accept_ok = header:find(expected_accept, 1, true) ~= nil
          buf = buf:sub(e + 1)
          handshook = true
          sock:write(mask_encode(vim.json.encode({
            jsonrpc = "2.0",
            id = 1,
            method = "initialize",
            params = {},
          })))
        end
        local frames
        frames, buf = frame.decode(buf)
        for _, f in ipairs(frames) do
          if f.opcode == frame.OP_TEXT then
            result.messages[#result.messages + 1] = vim.json.decode(f.payload)
          end
        end
      end)
    end)

    vim.wait(3000, function()
      return #result.messages > 0
    end)
    if not sock:is_closing() then
      sock:close()
    end

    assert.is_true(result.status_ok, "expected HTTP 101 status line")
    assert.is_true(result.accept_ok, "expected correct Sec-WebSocket-Accept")
    assert.equals(1, #result.messages)
    assert.equals(1, result.messages[1].id)
    assert.equals("2025-03-26", result.messages[1].result.protocolVersion)
  end)

  it("answers a tools/call over the socket", function()
    local key = "x3JJHMbDL1EzLkh9GBhXDw=="
    local sock = vim.uv.new_tcp()
    local buf, handshook = "", false
    local messages = {}

    sock:connect("127.0.0.1", port, function()
      sock:write(request(token, key))
      sock:read_start(function(err, chunk)
        if err or not chunk then
          return
        end
        buf = buf .. chunk
        if not handshook then
          local s, e = buf:find("\r\n\r\n", 1, true)
          if not s then
            return
          end
          buf = buf:sub(e + 1)
          handshook = true
          sock:write(mask_encode(vim.json.encode({
            jsonrpc = "2.0",
            id = 7,
            method = "tools/call",
            params = { name = "getWorkspaceFolders", arguments = {} },
          })))
        end
        local frames
        frames, buf = frame.decode(buf)
        for _, f in ipairs(frames) do
          if f.opcode == frame.OP_TEXT then
            messages[#messages + 1] = vim.json.decode(f.payload)
          end
        end
      end)
    end)

    vim.wait(3000, function()
      return #messages > 0
    end)
    if not sock:is_closing() then
      sock:close()
    end

    assert.equals(1, #messages)
    assert.equals(7, messages[1].id)
    local payload = vim.json.decode(messages[1].result.content[1].text)
    assert.is_true(payload.success)
    assert.equals(vim.fn.getcwd(), payload.rootPath)
  end)
end)
