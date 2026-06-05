local config = require("claude-chat.config")
local session = require("claude-chat.session")

-- The chat sidebar: a read-only transcript window on top of a small input window.
local M = {}

M.transcript_buf = nil
M.transcript_win = nil
M.input_buf = nil
M.input_win = nil

-- Full transcript content, kept as a list of lines and re-rendered on change.
M.lines = {}
M.busy = false

local function header(label)
  local width = config.options.width
  local prefix = "── " .. label .. " "
  local fill = math.max(1, width - vim.fn.strdisplaywidth(prefix))
  return prefix .. string.rep("─", fill)
end

local function render()
  if not (M.transcript_buf and vim.api.nvim_buf_is_valid(M.transcript_buf)) then
    return
  end

  local out = vim.deepcopy(M.lines)
  if M.busy then
    if #out > 0 then
      table.insert(out, "")
    end
    table.insert(out, "⏳ Claude is thinking…")
  end

  vim.bo[M.transcript_buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.transcript_buf, 0, -1, false, out)
  vim.bo[M.transcript_buf].modifiable = false

  -- Keep the latest content in view.
  if M.transcript_win and vim.api.nvim_win_is_valid(M.transcript_win) then
    local count = vim.api.nvim_buf_line_count(M.transcript_buf)
    pcall(vim.api.nvim_win_set_cursor, M.transcript_win, { count, 0 })
  end
end

local function add_message(label, text)
  if #M.lines > 0 then
    table.insert(M.lines, "")
  end
  table.insert(M.lines, header(label))
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    table.insert(M.lines, line)
  end
  render()
end

function M.is_open()
  return M.transcript_win ~= nil and vim.api.nvim_win_is_valid(M.transcript_win)
end

function M.submit()
  if session.running then
    vim.notify("Claude is still responding…", vim.log.levels.WARN)
    return
  end

  local input = vim.api.nvim_buf_get_lines(M.input_buf, 0, -1, false)
  local prompt = vim.trim(table.concat(input, "\n"))
  if prompt == "" then
    return
  end

  vim.api.nvim_buf_set_lines(M.input_buf, 0, -1, false, {})
  add_message("You", prompt)
  M.busy = true
  render()

  session.send(prompt, {
    on_done = function(text, err)
      M.busy = false
      if err then
        add_message("Error", err)
      else
        add_message("Claude", (text and text ~= "") and text or "(empty response)")
      end
    end,
  })
end

local function setup_keymaps()
  local km = config.options.keymaps
  local function map(buf, mode, lhs, fn)
    if not lhs or lhs == "" then
      return
    end
    vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, silent = true })
  end

  map(M.input_buf, "n", km.submit, M.submit)
  map(M.input_buf, "i", km.submit_insert, M.submit)

  for _, buf in ipairs({ M.input_buf, M.transcript_buf }) do
    map(buf, "n", km.close, M.close)
    map(buf, "n", km.reset, M.reset)
  end
end

local function ensure_buffers()
  if not (M.transcript_buf and vim.api.nvim_buf_is_valid(M.transcript_buf)) then
    M.transcript_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[M.transcript_buf].buftype = "nofile"
    vim.bo[M.transcript_buf].bufhidden = "hide"
    vim.bo[M.transcript_buf].swapfile = false
    vim.bo[M.transcript_buf].filetype = "markdown"
    vim.bo[M.transcript_buf].modifiable = false
    pcall(vim.api.nvim_buf_set_name, M.transcript_buf, "ClaudeChat://transcript")
  end

  if not (M.input_buf and vim.api.nvim_buf_is_valid(M.input_buf)) then
    M.input_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[M.input_buf].buftype = "nofile"
    vim.bo[M.input_buf].bufhidden = "hide"
    vim.bo[M.input_buf].swapfile = false
    pcall(vim.api.nvim_buf_set_name, M.input_buf, "ClaudeChat://input")
  end
end

function M.open()
  local opts = config.ensure()

  if M.is_open() then
    vim.api.nvim_set_current_win(M.input_win)
    return
  end

  ensure_buffers()

  -- Transcript: a full-height vertical split on the chosen side.
  local split = (opts.position == "left") and "topleft vsplit" or "botright vsplit"
  vim.cmd(split)
  M.transcript_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.transcript_win, M.transcript_buf)
  vim.api.nvim_win_set_width(M.transcript_win, opts.width)
  vim.wo[M.transcript_win].number = false
  vim.wo[M.transcript_win].relativenumber = false
  vim.wo[M.transcript_win].signcolumn = "no"
  vim.wo[M.transcript_win].wrap = true
  vim.wo[M.transcript_win].winfixwidth = true
  vim.wo[M.transcript_win].winbar = " Claude Chat"

  -- Input: a short split below the transcript, sharing the same column.
  vim.cmd("belowright split")
  M.input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.input_win, M.input_buf)
  vim.api.nvim_win_set_height(M.input_win, opts.input_height)
  vim.wo[M.input_win].number = false
  vim.wo[M.input_win].relativenumber = false
  vim.wo[M.input_win].signcolumn = "no"
  vim.wo[M.input_win].wrap = true
  vim.wo[M.input_win].winfixheight = true
  vim.wo[M.input_win].winbar = " Message — "
    .. opts.keymaps.submit
    .. " send · "
    .. opts.keymaps.reset
    .. " reset · "
    .. opts.keymaps.close
    .. " close"

  setup_keymaps()
  render()

  vim.api.nvim_set_current_win(M.input_win)
  vim.cmd("startinsert")
end

function M.close()
  for _, win in ipairs({ M.input_win, M.transcript_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end
  M.input_win = nil
  M.transcript_win = nil
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

function M.reset()
  session.reset()
  M.lines = {}
  M.busy = false
  add_message("System", "Session reset. Your next message starts a new conversation.")
end

return M
