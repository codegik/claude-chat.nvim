-- JSON-RPC 2.0 / MCP dispatch. Claude is the client; we are the server.
local tools = require("claude-chat.ide.tools")
local log = require("claude-chat.log")

local M = {}

local PROTOCOL_VERSION = "2025-03-26"

function M.handle(client, msg)
  local method = msg.method
  if not method then
    -- A response to a request we sent (we don't send any); ignore.
    return
  end
  local id = msg.id
  log.debug("recv method=%s id=%s", tostring(method), tostring(id))

  if method == "initialize" then
    client.send({
      jsonrpc = "2.0",
      id = id,
      result = {
        protocolVersion = PROTOCOL_VERSION,
        capabilities = { tools = vim.empty_dict() },
        serverInfo = { name = "claude-chat.nvim", version = "0.1.0" },
      },
    })
  elseif method == "notifications/initialized" or method == "initialized" then
    -- no response expected
  elseif method == "tools/list" then
    client.send({ jsonrpc = "2.0", id = id, result = { tools = tools.list() } })
  elseif method == "tools/call" then
    local params = msg.params or {}
    log.info("tools/call %s", tostring(params.name))
    tools.call(params.name, params.arguments, function(result)
      client.send({ jsonrpc = "2.0", id = id, result = result })
    end)
  elseif method == "ping" then
    client.send({ jsonrpc = "2.0", id = id, result = vim.empty_dict() })
  elseif id ~= nil then
    client.send({
      jsonrpc = "2.0",
      id = id,
      error = { code = -32601, message = "Method not found: " .. tostring(method) },
    })
  end
end

return M
