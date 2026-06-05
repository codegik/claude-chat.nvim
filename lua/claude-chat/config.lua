local M = {}

-- Default options. Override any of these via require("claude-chat").setup({...}).
M.defaults = {
  -- Path/name of the Claude Code CLI executable.
  cli = "claude",
  -- Extra args passed to the interactive CLI (e.g. { "--model", "sonnet" }).
  extra_args = {},
  -- Sidebar width in columns.
  width = 80,
  -- Which side the sidebar opens on: "right" or "left".
  position = "right",
  -- Working directory for the Claude session. nil = Neovim's current directory.
  cwd = nil,
  -- Enter terminal (insert) mode automatically when the sidebar opens.
  start_insert = true,
  -- Run the IDE integration (WebSocket MCP server) so Claude is aware of your
  -- open file, selection, diagnostics, and can open files/diffs in the editor.
  ide_integration = true,
  -- Pre-approve the IDE MCP tools (passes `--allowedTools mcp__ide`) so Claude
  -- reads your editor context without a permission prompt on every call.
  auto_allow_ide_tools = true,
  -- Also pre-approve Claude's edit tools (Edit/Write/MultiEdit). With this on,
  -- Claude applies edits without a "Do you want to make this edit?" prompt.
  -- Off by default so nothing is written without an explicit confirmation.
  auto_allow_edits = false,
  -- Show proposed edits as a diff in a Neovim tab (the `openDiff` MCP tool).
  -- Off by default because Claude's own TUI already renders the diff and asks
  -- for approval; enabling this adds a second, separate diff in the editor.
  ide_diff = false,
  -- Log verbosity: "off" | "error" | "warn" | "info" | "debug".
  -- Logs are written to stdpath("log").."/claude-chat.log" (:ClaudeChatLog).
  log_level = "info",
  -- Terminal-mode keymaps, scoped to the Claude buffer. They are intercepted by
  -- Neovim instead of being sent to Claude, so you can navigate/resize/hide while
  -- the TUI is focused. Set any entry to false/"" to disable it (and free the key
  -- for Claude). Defaults mirror LazyVim's window keys.
  keymaps = {
    -- Hide the sidebar without stopping Claude.
    hide = "<C-q>",
    -- Move focus to another window (e.g. back to the editor).
    nav = {
      left = "<C-h>",
      down = "<C-j>",
      up = "<C-k>",
      right = "<C-l>",
    },
    -- Resize the sidebar window.
    resize = {
      left = "<C-Left>",
      right = "<C-Right>",
      up = "<C-Up>",
      down = "<C-Down>",
    },
  },
}

-- Active, merged options. Populated by setup().
M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
  require("claude-chat.log").set_level(M.options.log_level)
  return M.options
end

-- Ensure options exist even if the user never called setup() (native package load).
function M.ensure()
  if vim.tbl_isempty(M.options) then
    M.setup()
  end
  return M.options
end

return M
