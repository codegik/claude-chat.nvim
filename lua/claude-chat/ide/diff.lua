-- Implements the blocking `openDiff` flow: show Claude's proposed changes in a
-- diff view; the user accepts (`:w`) or rejects (`q`), which resolves the call.
local log = require("claude-chat.log")

local M = {}

-- Return focus to the Claude sidebar in terminal mode, so the next keystroke
-- goes to the TUI (e.g. answering Claude's follow-up) and not to Neovim.
local function refocus_chat()
  vim.schedule(function()
    pcall(function()
      require("claude-chat.ui").focus()
    end)
  end)
end

-- tab_name -> { tab, resolve, resolved }
M.active = {}

local function content(text)
  return { content = { { type = "text", text = text } } }
end

local function close_entry(name)
  local entry = M.active[name]
  M.active[name] = nil
  if entry and entry.tab and vim.api.nvim_tabpage_is_valid(entry.tab) then
    pcall(function()
      vim.api.nvim_set_current_tabpage(entry.tab)
      vim.cmd("tabclose")
    end)
  end
end

-- Build an unlisted scratch buffer that wipes itself when its window closes.
local function scratch_buf(lines, ft, bufname)
  local buf = vim.api.nvim_create_buf(false, true) -- unlisted, scratch
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  if ft and ft ~= "" then
    vim.bo[buf].filetype = ft
  end
  if bufname then
    pcall(vim.api.nvim_buf_set_name, buf, bufname)
  end
  return buf
end

function M.open(args, cb)
  local name = args.tab_name or ("Claude diff " .. os.time())
  local resolved = false
  local function resolve(result)
    if resolved then
      return
    end
    resolved = true
    cb(result)
  end

  local ft = vim.filetype.match({ filename = args.new_file_path }) or ""
  local old_lines = {}
  if args.old_file_path and vim.fn.filereadable(args.old_file_path) == 1 then
    old_lines = vim.fn.readfile(args.old_file_path)
  end
  local new_lines = vim.split(args.new_file_contents or "", "\n", { plain = true })

  -- New tab; remember its throwaway [No Name] buffer so we can wipe it.
  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  local placeholder = vim.api.nvim_get_current_buf()

  -- Left: current contents (read-only scratch, not the real file buffer, so we
  -- never touch/lock the actual file or pollute the buffer list).
  local current = scratch_buf(old_lines, ft, name .. " (current)")
  vim.bo[current].modifiable = false
  vim.api.nvim_win_set_buf(0, current)
  vim.cmd("diffthis")

  -- Right: proposed contents. acwrite so `:w` fires BufWriteCmd (= accept).
  vim.cmd("vsplit")
  local proposed = scratch_buf(new_lines, ft, name)
  vim.bo[proposed].buftype = "acwrite"
  vim.bo[proposed].modified = false
  vim.api.nvim_win_set_buf(0, proposed)
  vim.cmd("diffthis")

  -- Drop the empty [No Name] buffer tabnew created.
  if vim.api.nvim_buf_is_valid(placeholder) and vim.api.nvim_buf_get_name(placeholder) == "" then
    pcall(vim.api.nvim_buf_delete, placeholder, { force = true })
  end

  M.active[name] = { tab = tab, resolve = resolve }

  local tabclosed_au
  local function finish(result, label)
    log.info("openDiff '%s' -> %s", name, label)
    if tabclosed_au then
      pcall(vim.api.nvim_del_autocmd, tabclosed_au)
      tabclosed_au = nil
    end
    resolve(result)
    close_entry(name)
    refocus_chat()
  end

  -- Accept: signal FILE_SAVED only. Claude performs the real write itself; if we
  -- wrote the file here, Claude's follow-up edit would fail with "file content
  -- has changed since it was last read".
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = proposed,
    callback = function()
      vim.bo[proposed].modified = false
      finish(content("FILE_SAVED"), "FILE_SAVED")
    end,
  })

  -- Reject: `q` in the proposed buffer.
  vim.keymap.set("n", "q", function()
    finish(content("DIFF_REJECTED"), "DIFF_REJECTED")
  end, { buffer = proposed, nowait = true, silent = true })

  -- Closing the diff tab without deciding counts as a rejection.
  tabclosed_au = vim.api.nvim_create_autocmd("TabClosed", {
    callback = function()
      if not resolved and not vim.api.nvim_tabpage_is_valid(tab) then
        finish(content("DIFF_REJECTED"), "DIFF_REJECTED (tab closed)")
      end
    end,
  })

  vim.notify("Claude proposed changes — :w to accept, q to reject", vim.log.levels.INFO)
end

function M.close(name)
  close_entry(name)
  return content("TAB_CLOSED")
end

function M.close_all()
  local count = 0
  for name in pairs(M.active) do
    count = count + 1
    close_entry(name)
  end
  return content("CLOSED_" .. count .. "_DIFF_TABS")
end

return M
