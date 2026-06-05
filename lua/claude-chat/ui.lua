local config = require("claude-chat.config")

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

local function start_terminal(opts)
  -- The current buffer becomes the terminal, so create one and show it first.
  M.buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_win_set_buf(M.win, M.buf)

  local cmd = { opts.cli }
  vim.list_extend(cmd, opts.extra_args)

  M.job = vim.fn.jobstart(cmd, {
    term = true,
    cwd = opts.cwd or vim.fn.getcwd(),
    on_exit = function()
      M.job = nil
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

function M.open()
  local opts = config.ensure()

  if M.is_open() then
    vim.api.nvim_set_current_win(M.win)
    if opts.start_insert then
      vim.cmd("startinsert")
    end
    return
  end

  open_window(opts)

  -- Reuse the live session if one exists; otherwise launch a fresh TUI.
  if session_alive() then
    vim.api.nvim_win_set_buf(M.win, M.buf)
  else
    start_terminal(opts)
  end

  if opts.start_insert then
    vim.cmd("startinsert")
  end
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
