-- Orchestrates the IDE integration: starts the WebSocket server, writes the
-- discovery lock file, tracks selection, and exposes the env Claude needs.
local server = require("claude-chat.ide.server")
local mcp = require("claude-chat.ide.mcp")
local selection = require("claude-chat.ide.selection")
local lockfile = require("claude-chat.ide.lockfile")
local log = require("claude-chat.log")

local M = {}

M.port = nil
M.auth_token = nil
M.workspace = nil
M._autocmd = nil

-- Start the integration. Returns true on success. `workspace` is the project
-- root advertised in the lock file (defaults to Neovim's cwd). `prime_buf` is
-- the editor buffer to seed Claude's open-file context with.
function M.start(workspace, prime_buf)
  if M.port then
    return true
  end

  local port, token = server.start({
    on_message = function(client, msg)
      mcp.handle(client, msg)
    end,
    on_connect = function(client)
      log.info("claude connected to IDE server")
      selection.send_to(client)
    end,
  })
  if not port then
    log.error("IDE server failed to start: %s", tostring(token))
    vim.notify("claude-chat: IDE server failed to start (" .. tostring(token) .. ")", vim.log.levels.WARN)
    return false
  end

  M.port = port
  M.auth_token = token
  M.workspace = workspace or vim.fn.getcwd()

  if not lockfile.write(port, token, M.workspace) then
    log.warn("could not write IDE lock file at %s", lockfile.path(port))
    vim.notify("claude-chat: could not write IDE lock file", vim.log.levels.WARN)
  end

  selection.start(function(payload)
    server.broadcast({ jsonrpc = "2.0", method = "selection_changed", params = payload })
  end)

  -- Seed the open-file context from the editor buffer (before the terminal
  -- took focus), so the very first question already has the active file.
  if prime_buf then
    selection.prime(prime_buf)
  end

  log.info("IDE server started on 127.0.0.1:%d, workspace %s", port, M.workspace)

  -- Always clean up the lock file when Neovim exits.
  if not M._autocmd then
    M._autocmd = vim.api.nvim_create_autocmd("VimLeavePre", {
      callback = function()
        M.stop()
      end,
    })
  end

  return true
end

function M.stop()
  if M.port then
    log.info("IDE server stopping (port %d)", M.port)
  end
  selection.stop()
  lockfile.remove(M.port)
  server.stop()
  M.port = nil
  M.auth_token = nil
  M.workspace = nil
end

function M.is_running()
  return M.port ~= nil
end

-- Environment variables Claude needs to discover and connect to the server.
function M.env()
  if not M.port then
    return {}
  end
  return {
    CLAUDE_CODE_SSE_PORT = tostring(M.port),
    ENABLE_IDE_INTEGRATION = "true",
  }
end

return M
