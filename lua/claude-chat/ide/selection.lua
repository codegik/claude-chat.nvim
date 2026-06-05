-- Tracks the active editor file + selection and emits `selection_changed`.
-- This is what gives Claude live awareness of what you're looking at.
local log = require("claude-chat.log")

local M = {}

M.emit = nil -- function(payload) called on change
M.current = nil -- latest computed payload
M.latest = nil -- latest *non-empty* selection
M.augroup = nil
M.timer = nil

local function is_file_buf(buf)
  return vim.api.nvim_buf_is_valid(buf)
    and vim.bo[buf].buftype == ""
    and vim.api.nvim_buf_get_name(buf) ~= ""
end

local function file_url(path)
  return "file://" .. (path:gsub(" ", "%%20"))
end

-- Build the payload from the focused window, or nil if it isn't a real file
-- (e.g. the Claude terminal is focused) so we keep the previous value.
local function compute()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  if not is_file_buf(buf) then
    return nil
  end

  local path = vim.api.nvim_buf_get_name(buf)
  local mode = vim.fn.mode()
  local sel, text

  if mode == "v" or mode == "V" or mode == "\22" then
    local p1, p2 = vim.fn.getpos("v"), vim.fn.getpos(".")
    local function before(a, b)
      if a[2] ~= b[2] then
        return a[2] < b[2]
      end
      return a[3] < b[3]
    end
    local s, e = p1, p2
    if before(p2, p1) then
      s, e = p2, p1
    end
    sel = {
      start = { line = s[2] - 1, character = s[3] - 1 },
      ["end"] = { line = e[2] - 1, character = e[3] },
      isEmpty = false,
    }
    local ok, region = pcall(vim.fn.getregion, p1, p2, { type = mode })
    text = (ok and region) and table.concat(region, "\n") or ""
  else
    local cur = vim.api.nvim_win_get_cursor(win)
    sel = {
      start = { line = cur[1] - 1, character = cur[2] },
      ["end"] = { line = cur[1] - 1, character = cur[2] },
      isEmpty = true,
    }
    text = ""
  end

  return { text = text, filePath = path, fileUrl = file_url(path), selection = sel }
end

local function update()
  local payload = compute()
  if not payload then
    return
  end
  M.current = payload
  if not payload.selection.isEmpty then
    M.latest = payload
  end
  if M.emit then
    M.emit(payload)
  end
end

-- Seed the current context from a specific buffer (the file that was focused
-- before the sidebar stole focus). Without this, Claude connects with no
-- open-file context because the terminal is the active window.
function M.prime(buf)
  if not is_file_buf(buf) then
    return
  end
  local path = vim.api.nvim_buf_get_name(buf)
  local line, col = 1, 0
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    local cur = vim.api.nvim_win_get_cursor(win)
    line, col = cur[1], cur[2]
  end
  M.current = {
    text = "",
    filePath = path,
    fileUrl = file_url(path),
    selection = {
      start = { line = line - 1, character = col },
      ["end"] = { line = line - 1, character = col },
      isEmpty = true,
    },
  }
  log.info("selection primed with %s", path)
  if M.emit then
    M.emit(M.current)
  end
end

function M.get()
  return M.current
end

function M.get_latest()
  return M.latest or M.current
end

-- Push the current selection to a single client (used right after it connects).
function M.send_to(client)
  if M.current then
    client.send({ jsonrpc = "2.0", method = "selection_changed", params = M.current })
  end
end

function M.start(emit)
  M.emit = emit
  M.augroup = vim.api.nvim_create_augroup("ClaudeChatIdeSelection", { clear = true })
  M.timer = vim.uv.new_timer()

  vim.api.nvim_create_autocmd(
    { "BufEnter", "WinEnter", "CursorMoved", "CursorMovedI", "ModeChanged" },
    {
      group = M.augroup,
      callback = function()
        -- Debounce: restart the 80ms timer on each event.
        M.timer:stop()
        M.timer:start(80, 0, vim.schedule_wrap(update))
      end,
    }
  )

  vim.schedule(update)
end

function M.stop()
  if M.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, M.augroup)
    M.augroup = nil
  end
  if M.timer then
    M.timer:stop()
    if not M.timer:is_closing() then
      M.timer:close()
    end
    M.timer = nil
  end
  M.emit = nil
  M.current = nil
  M.latest = nil
end

return M
