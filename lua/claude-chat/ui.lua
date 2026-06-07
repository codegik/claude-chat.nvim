local config = require("claude-chat.config")
local ide = require("claude-chat.ide")

-- Absolute path to a file shipped with this plugin (relative to its root).
local function plugin_file(rel)
  local src = debug.getinfo(1, "S").source:sub(2) -- .../lua/claude-chat/ui.lua
  return vim.fn.fnamemodify(src, ":h:h:h") .. "/" .. rel
end

-- This Neovim's RPC address, so a child process can connect back to it.
local function nvim_rpc_address()
  local addr = vim.v.servername
  if addr == nil or addr == "" then
    addr = vim.fn.serverstart()
  end
  return addr
end

-- The chat sidebar hosts the *interactive* Claude Code TUI inside a terminal
-- buffer. Because it is the real TUI, everything works exactly like running
-- `claude` in a terminal: streaming replies, multi-turn, and — crucially —
-- interactive permission prompts that you answer yourself.
local M = {}

M.buf = nil -- terminal buffer running claude
M.win = nil -- sidebar window currently showing it
M.job = nil -- job id of the claude process

function M.is_open()
  return M.win ~= nil and vim.api.nvim_win_is_valid(M.win)
end

-- True when a Claude process is still running in a live buffer.
local function session_alive()
  return M.job ~= nil and M.buf ~= nil and vim.api.nvim_buf_is_valid(M.buf)
end

local function open_window(opts)
  local split = (opts.position == "left") and "topleft vsplit" or "botright vsplit"
  vim.cmd(split)
  M.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(M.win, opts.width)
  vim.wo[M.win].number = false
  vim.wo[M.win].relativenumber = false
  vim.wo[M.win].signcolumn = "no"
  vim.wo[M.win].winfixwidth = true
  vim.wo[M.win].winbar = " Claude"
end

local function start_terminal(opts, prime_buf)
  -- The current buffer becomes the terminal, so create one and show it first.
  M.buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_win_set_buf(M.win, M.buf)

  local cmd = { opts.cli }

  -- Start the IDE integration so Claude becomes aware of the editor, and pass
  -- the discovery env vars to the CLI so it connects back to us.
  local env
  local cwd = opts.cwd or vim.fn.getcwd()
  if opts.ide_integration ~= false and ide.start(cwd, prime_buf) then
    env = ide.env()
    -- Pre-approve tools so Claude uses them without a permission prompt.
    -- "mcp__ide" allows the whole IDE server; Edit/Write/MultiEdit let Claude
    -- apply edits without its own "make this edit?" prompt.
    local allowed = {}
    if opts.auto_allow_ide_tools ~= false then
      table.insert(allowed, "mcp__ide")
    end
    if opts.auto_allow_edits then
      vim.list_extend(allowed, { "Edit", "Write", "MultiEdit" })
    end

    -- The IDE channel does not expose openFile to the model, so run a small
    -- stdio MCP server (`scripts/mcp_bridge.lua`, via this nvim binary) whose
    -- open_file tool Claude *can* call. It reaches back into us over RPC.
    if opts.open_file_tool ~= false then
      local mcp_cfg = vim.json.encode({
        mcpServers = {
          ["claude-chat"] = {
            type = "stdio",
            command = vim.v.progpath,
            args = { "-l", plugin_file("scripts/mcp_bridge.lua") },
            env = { CLAUDE_CHAT_NVIM = nvim_rpc_address() },
          },
        },
      })
      table.insert(cmd, "--mcp-config")
      table.insert(cmd, mcp_cfg)
      table.insert(allowed, "mcp__claude-chat")
    end

    if #allowed > 0 then
      table.insert(cmd, "--allowedTools")
      vim.list_extend(cmd, allowed)
    end

    -- Reinforce the open_file tool: "open the readme" should open it in the
    -- editor, not make Claude read and summarize the file.
    if opts.open_in_editor_hint then
      local hint = type(opts.open_in_editor_hint) == "string" and opts.open_in_editor_hint
        or "When the user asks to open, show, reveal, or go to a file (or a line in a file), "
          .. "open it in their editor with the open_file tool from the claude-chat MCP server, "
          .. "rather than reading and summarizing it with the Read tool. Only summarize when "
          .. "the user explicitly asks for a summary or the file's contents."
      table.insert(cmd, "--append-system-prompt")
      table.insert(cmd, hint)
    end
  end

  vim.list_extend(cmd, opts.extra_args)

  M.job = vim.fn.jobstart(cmd, {
    term = true,
    cwd = cwd,
    env = env,
    on_exit = function()
      M.job = nil
      if opts.ide_integration ~= false then
        ide.stop()
      end
    end,
  })

  -- Terminal-mode keymaps scoped to this buffer. Neovim intercepts them before
  -- they reach Claude, so window navigation/resize/hide work while the TUI is
  -- focused. <Cmd> mappings run without leaving terminal mode.
  local km = opts.keymaps
  local function tmap(lhs, rhs)
    if lhs and lhs ~= "" then
      vim.keymap.set("t", lhs, rhs, { buffer = M.buf, nowait = true, silent = true })
    end
  end

  tmap(km.hide, function()
    M.close()
  end)

  -- Move focus to another window (leaves the terminal; lands in the target window).
  tmap(km.nav.left, "<Cmd>wincmd h<CR>")
  tmap(km.nav.down, "<Cmd>wincmd j<CR>")
  tmap(km.nav.up, "<Cmd>wincmd k<CR>")
  tmap(km.nav.right, "<Cmd>wincmd l<CR>")

  -- Resize the sidebar (stays focused on Claude).
  tmap(km.resize.left, "<Cmd>vertical resize -2<CR>")
  tmap(km.resize.right, "<Cmd>vertical resize +2<CR>")
  tmap(km.resize.up, "<Cmd>resize +2<CR>")
  tmap(km.resize.down, "<Cmd>resize -2<CR>")

  -- Re-enter insert mode when returning to the Claude window, so you can type
  -- immediately after navigating away and back.
  if opts.start_insert then
    vim.api.nvim_create_autocmd("WinEnter", {
      buffer = M.buf,
      callback = function()
        if vim.api.nvim_get_current_buf() == M.buf then
          vim.cmd("startinsert")
        end
      end,
    })
  end
end

-- Opens/focuses the sidebar. Returns true if a fresh Claude session was launched.
function M.open()
  local opts = config.ensure()
  local started = false

  -- Capture the editor buffer *before* the sidebar takes focus, so we can seed
  -- Claude's open-file context with it.
  local prime_buf = vim.api.nvim_get_current_buf()

  if M.is_open() then
    vim.api.nvim_set_current_win(M.win)
  else
    open_window(opts)
    -- Reuse the live session if one exists; otherwise launch a fresh TUI.
    if session_alive() then
      vim.api.nvim_win_set_buf(M.win, M.buf)
    else
      start_terminal(opts, prime_buf)
      started = true
    end
  end

  if opts.start_insert then
    vim.cmd("startinsert")
  end
  return started
end

-- Focus the sidebar and enter terminal mode, so the next keystroke reaches the
-- Claude TUI (used after a diff tab closes, which returns focus in normal mode).
function M.focus()
  if not M.is_open() then
    return
  end
  vim.api.nvim_set_current_win(M.win)
  if config.options.start_insert ~= false then
    vim.cmd("startinsert")
  end
end

-- The file shown in the current buffer, or the alternate file as a fallback.
local function resolve_file()
  if vim.bo.buftype == "" then
    local name = vim.api.nvim_buf_get_name(0)
    if name ~= "" then
      return name
    end
  end
  local alt = vim.fn.bufnr("#")
  if alt > 0 and vim.bo[alt].buftype == "" then
    local name = vim.api.nvim_buf_get_name(alt)
    if name ~= "" then
      return name
    end
  end
  return nil
end

-- Insert an @-mention of the current file into Claude's prompt so it reads that
-- file into context. You then type your question and press Enter.
function M.add_current_file()
  local opts = config.ensure()

  local file = resolve_file()
  if not file then
    vim.notify("ClaudeChat: no file in the current buffer", vim.log.levels.WARN)
    return
  end

  -- Path relative to Claude's working directory (how @-mentions resolve).
  local cwd = opts.cwd or vim.fn.getcwd()
  local rel = (vim.fs.relpath and vim.fs.relpath(cwd, file)) or vim.fn.fnamemodify(file, ":.")
  local mention = "@" .. rel .. " "

  -- Capture the file before focusing the terminal, then send it.
  local started = M.open()
  -- A fresh TUI needs a moment to be ready for input; an existing one is instant.
  vim.defer_fn(function()
    if session_alive() then
      vim.fn.chansend(M.job, mention)
    end
  end, started and 1500 or 0)
end

-- Hide the sidebar window. The Claude process keeps running in the background;
-- reopening with M.open() returns to the same live session.
function M.close()
  if M.is_open() then
    vim.api.nvim_win_close(M.win, true)
  end
  M.win = nil
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

-- Stop the current Claude process and start a brand-new session.
function M.reset()
  local was_open = M.is_open()

  if M.job then
    vim.fn.jobstop(M.job)
    M.job = nil
  end
  M.close()
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    vim.api.nvim_buf_delete(M.buf, { force = true })
  end
  M.buf = nil

  if was_open then
    M.open()
  end
end

return M
