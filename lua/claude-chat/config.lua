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
