local M = {}

-- Default options. Override any of these via require("claude-chat").setup({...}).
M.defaults = {
  -- Path/name of the Claude Code CLI executable.
  cli = "claude",
  -- Extra args appended to every CLI invocation (e.g. { "--model", "sonnet" }).
  extra_args = {},
  -- Sidebar width in columns.
  width = 64,
  -- Which side the sidebar opens on: "right" or "left".
  position = "right",
  -- Height of the input window in rows.
  input_height = 6,
  -- Per-request timeout in milliseconds.
  timeout = 180000,
  keymaps = {
    submit = "<CR>", -- normal mode, in the input window
    submit_insert = "<C-s>", -- insert mode, in the input window
    close = "q", -- normal mode, in either window
    reset = "<C-l>", -- normal mode, in either window
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
