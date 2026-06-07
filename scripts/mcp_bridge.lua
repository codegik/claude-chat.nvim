-- Standalone stdio MCP server, launched by the plugin via `nvim -l`.
--
-- Why this exists: Claude Code's IDE integration (the WebSocket channel in
-- lua/claude-chat/ide/) calls tools like openFile *itself*, for its own context
-- gathering and diff UI — it does NOT expose them to the model. The only IDE
-- tools the model can call are getDiagnostics and executeCode. So "open the
-- readme" never reaches our openFile; the model just Reads the file instead.
--
-- A regular MCP server's tools, by contrast, ARE offered to the model. This
-- script is such a server: it speaks newline-delimited JSON-RPC over stdio and,
-- on a tool call, reaches back into the parent Neovim over RPC to open the file
-- in the real editor window.
--
-- The parent's RPC address is passed in the CLAUDE_CHAT_NVIM env var.

local PROTOCOL_VERSION = "2025-03-26"

local parent_addr = os.getenv("CLAUDE_CHAT_NVIM")
local parent_ch

local function parent()
  if parent_ch then
    return parent_ch
  end
  if not parent_addr or parent_addr == "" then
    return nil
  end
  local ok, ch = pcall(vim.fn.sockconnect, "pipe", parent_addr, { rpc = true })
  if ok and type(ch) == "number" and ch > 0 then
    parent_ch = ch
    return ch
  end
  return nil
end

local function open_file(args)
  local ch = parent()
  if not ch then
    return "Error: cannot reach Neovim (no RPC channel to the editor)"
  end
  local ok, res = pcall(
    vim.rpcrequest,
    ch,
    "nvim_exec_lua",
    "return require('claude-chat.ide.tools').open_in_editor(...)",
    { args.filePath, args.startText }
  )
  if not ok then
    return "Error: " .. tostring(res)
  end
  return tostring(res)
end

local TOOLS = {
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

local function send(obj)
  io.write(vim.json.encode(obj) .. "\n")
  io.flush()
end

local function handle(msg)
  local method = msg.method
  local id = msg.id
  if method == "initialize" then
    send({
      jsonrpc = "2.0",
      id = id,
      result = {
        protocolVersion = PROTOCOL_VERSION,
        capabilities = { tools = vim.empty_dict() },
        serverInfo = { name = "claude-chat", version = "0.1.0" },
      },
    })
  elseif method == "notifications/initialized" or method == "initialized" then
    -- no response expected
  elseif method == "tools/list" then
    send({ jsonrpc = "2.0", id = id, result = { tools = TOOLS } })
  elseif method == "tools/call" then
    local params = msg.params or {}
    local text
    if params.name == "open_file" then
      text = open_file(params.arguments or {})
    else
      text = "Unknown tool: " .. tostring(params.name)
    end
    send({ jsonrpc = "2.0", id = id, result = { content = { { type = "text", text = text } } } })
  elseif method == "ping" then
    send({ jsonrpc = "2.0", id = id, result = vim.empty_dict() })
  elseif id ~= nil then
    send({ jsonrpc = "2.0", id = id, error = { code = -32601, message = "Method not found: " .. tostring(method) } })
  end
end

-- Drive the protocol: one JSON-RPC message per line until stdin closes.
for line in io.lines() do
  if line ~= "" then
    local ok, msg = pcall(vim.json.decode, line)
    if ok and type(msg) == "table" then
      pcall(handle, msg)
    end
  end
end
