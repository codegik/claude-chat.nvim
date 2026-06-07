-- Implements the `openDiff` flow as a *live preview*: when Claude proposes a
-- change it shows current-vs-proposed side by side in the editor (left of the
-- Claude sidebar), then returns immediately so Claude's own console prompt is
-- the single approval. The preview stays up until Claude actually writes the
-- file (detected by watching it on disk), at which point it auto-closes.
local log = require("claude-chat.log")

local M = {}

-- Return focus to the Claude sidebar in terminal mode, so the next keystroke
-- goes to the TUI (e.g. answering Claude's prompt) and not to Neovim.
local function refocus_chat()
  vim.schedule(function()
    pcall(function()
      require("claude-chat.ui").focus()
    end)
  end)
end

-- tab_name -> { win_current, win_proposed, created_host, target_path, cancel }
M.active = {}

local function content(text)
  return { content = { { type = "text", text = text } } }
end

-- The preview panes force their own, always-visible diff colors via
-- winhighlight, so the change is readable even under colorschemes that leave
-- DiffChange/DiffText nearly invisible (e.g. a near-black DiffChange). Scoped to
-- the preview windows only, so global Diff colors (gitsigns, fugitive, …) are
-- untouched. Defined with default=true so a theme/user can override ClaudeDiff*.
local DIFF_WINHL =
  "DiffAdd:ClaudeDiffAdd,DiffChange:ClaudeDiffChange,DiffText:ClaudeDiffText,DiffDelete:ClaudeDiffDelete"

local function ensure_hl()
  local function hl(name, opts)
    opts.default = true
    pcall(vim.api.nvim_set_hl, 0, name, opts)
  end
  hl("ClaudeDiffAdd", { bg = "#284d28" })
  hl("ClaudeDiffChange", { bg = "#2b3a55" })
  hl("ClaudeDiffText", { bg = "#3b5e8c", bold = true })
  hl("ClaudeDiffDelete", { bg = "#5a2a2a" })
end

-- Tear down a preview: stop its watcher, drop the proposed pane, and either
-- close the host window (if we created it) or restore it to the real file so
-- the editor shows the result in context.
local function close_entry(name)
  local entry = M.active[name]
  M.active[name] = nil
  if not entry then
    return
  end
  if entry.cancel then
    entry.cancel()
  end
  if entry.win_proposed and vim.api.nvim_win_is_valid(entry.win_proposed) then
    pcall(vim.api.nvim_win_close, entry.win_proposed, true)
  end
  if entry.win_current and vim.api.nvim_win_is_valid(entry.win_current) then
    if entry.created_host then
      pcall(vim.api.nvim_win_close, entry.win_current, true)
    elseif entry.target_path then
      pcall(vim.api.nvim_win_call, entry.win_current, function()
        vim.cmd("diffoff")
        vim.wo.winhighlight = ""
        vim.cmd("edit! " .. vim.fn.fnameescape(entry.target_path))
      end)
    end
  end
  refocus_chat()
end

-- The Claude sidebar window, if the chat UI is open.
local function get_sidebar_win()
  local ok, ui = pcall(require, "claude-chat.ui")
  if ok and ui.win and vim.api.nvim_win_is_valid(ui.win) then
    return ui.win
  end
  return nil
end

-- A normal editor window in the current tab (skips the sidebar and tree/special
-- windows, which have a non-empty buftype).
local function find_editor_win(exclude)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= exclude and vim.bo[vim.api.nvim_win_get_buf(w)].buftype == "" then
      return w
    end
  end
  return nil
end

-- Watch a file's on-disk identity (mtime + size) and fire `on_saved` once it
-- changes from the baseline, i.e. Claude wrote the approved edit to disk. We
-- can't block on this from openDiff (Claude only writes *after* the call
-- returns), so we poll instead and give up after a timeout so a change the user
-- rejects in the console doesn't leave a poller running forever. Returns a
-- cancel function.
local function watch_until_saved(path, on_saved)
  if not path or path == "" then
    return function() end
  end
  local function stat_key()
    local st = vim.uv.fs_stat(path)
    return st and (st.mtime.sec .. ":" .. st.mtime.nsec .. ":" .. st.size) or nil
  end
  local baseline = stat_key()
  local timer = vim.uv.new_timer()
  local INTERVAL, TIMEOUT, elapsed = 250, 5 * 60 * 1000, 0

  local stopped = false
  local function stop()
    if stopped then
      return
    end
    stopped = true
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
  end

  timer:start(INTERVAL, INTERVAL, function()
    elapsed = elapsed + INTERVAL
    local cur = stat_key()
    local saved = cur ~= nil and cur ~= baseline
    if saved or elapsed >= TIMEOUT then
      stop()
      if saved then
        vim.schedule(on_saved)
      end
    end
  end)

  return stop
end

-- Build an unlisted scratch buffer that wipes itself when its window closes.
local function scratch_buf(lines, ft, bufname)
  local buf = vim.api.nvim_create_buf(false, true) -- unlisted, scratch
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  if ft and ft ~= "" then
    vim.bo[buf].filetype = ft
  end
  if bufname then
    pcall(vim.api.nvim_buf_set_name, buf, bufname)
  end
  return buf
end

-- When we host the diff in an existing editor window we swap its buffer out with
-- nvim_win_set_buf, which (unlike `:edit`) leaves an empty throwaway [No Name]
-- buffer stranded in the buffer list. Drop it, but only if it is genuinely a
-- disposable placeholder: unnamed, unmodified, empty, normal buftype, and no
-- longer shown in any window.
local function maybe_wipe_placeholder(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if vim.api.nvim_buf_get_name(buf) ~= "" or vim.bo[buf].modified then
    return
  end
  if vim.bo[buf].buftype ~= "" or #vim.fn.win_findbuf(buf) > 0 then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  if #lines > 1 or (lines[1] and lines[1] ~= "") then
    return
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

function M.open(args, cb)
  local name = args.tab_name or ("Claude diff " .. os.time())

  -- Only one live preview at a time.
  for n in pairs(M.active) do
    close_entry(n)
  end

  local ft = vim.filetype.match({ filename = args.new_file_path }) or ""
  local old_lines = {}
  if args.old_file_path and vim.fn.filereadable(args.old_file_path) == 1 then
    old_lines = vim.fn.readfile(args.old_file_path)
  end
  local new_lines = vim.split(args.new_file_contents or "", "\n", { plain = true })
  local target_path = args.new_file_path or args.old_file_path

  local sidebar = get_sidebar_win()
  local prev_win = vim.api.nvim_get_current_win()

  -- Host the diff in an editor window of the CURRENT tab (left of the Claude
  -- sidebar) so it sits right next to the console prompt, instead of being
  -- buried in a separate tab the user never switches to.
  local host = find_editor_win(sidebar)
  local created_host = false
  if host then
    vim.api.nvim_set_current_win(host)
  elseif sidebar then
    vim.api.nvim_set_current_win(sidebar)
    vim.cmd("leftabove vsplit")
    host = vim.api.nvim_get_current_win()
    created_host = true
  else
    vim.cmd("topleft vsplit")
    host = vim.api.nvim_get_current_win()
    created_host = true
  end

  -- Left pane: current contents (read-only scratch — never the real buffer, so
  -- we never lock the file or pollute the buffer list).
  ensure_hl()

  local win_current = host
  local placeholder = vim.api.nvim_win_get_buf(win_current)
  local current = scratch_buf(old_lines, ft, name .. " (current)")
  vim.api.nvim_win_set_buf(win_current, current)
  maybe_wipe_placeholder(placeholder)
  vim.wo[win_current].winhighlight = DIFF_WINHL
  vim.api.nvim_win_call(win_current, function()
    vim.cmd("diffthis")
  end)

  -- Right pane: proposed contents.
  vim.api.nvim_set_current_win(win_current)
  vim.cmd("belowright vsplit")
  local win_proposed = vim.api.nvim_get_current_win()
  local proposed = scratch_buf(new_lines, ft, name .. " (proposed)")
  vim.api.nvim_win_set_buf(win_proposed, proposed)
  vim.wo[win_proposed].winhighlight = DIFF_WINHL
  vim.api.nvim_win_call(win_proposed, function()
    vim.cmd("diffthis")
  end)

  -- `q` dismisses the preview; it is not a reject decision (that's in the
  -- Claude console).
  for _, b in ipairs({ current, proposed }) do
    vim.keymap.set("n", "q", function()
      close_entry(name)
    end, { buffer = b, nowait = true, silent = true })
  end

  -- Close the preview once Claude writes the approved change to disk.
  local cancel = watch_until_saved(target_path, function()
    log.info("openDiff '%s' file saved; closing preview", name)
    close_entry(name)
  end)

  M.active[name] = {
    win_current = win_current,
    win_proposed = win_proposed,
    created_host = created_host,
    target_path = target_path,
    cancel = cancel,
  }

  -- Hand focus back to the console so the user can answer the prompt.
  if sidebar then
    refocus_chat()
  elseif vim.api.nvim_win_is_valid(prev_win) then
    vim.api.nvim_set_current_win(prev_win)
  end

  -- Acknowledge immediately and never block: the user approves in the console,
  -- not here. Returning doesn't write anything; Claude performs the real write
  -- after the user confirms, which our watcher then detects.
  log.info("openDiff '%s' -> FILE_SAVED (preview; awaiting console confirm)", name)
  cb(content("FILE_SAVED"))
  vim.notify("Claude proposed changes — confirm in the Claude console", vim.log.levels.INFO)
end

-- Claude calls close_tab / closeAllDiffTabs reflexively right after openDiff
-- returns. We own the preview's lifecycle (it stays until the file is saved or
-- the user dismisses it with `q`), so we just acknowledge without tearing the
-- visible preview down — otherwise it would vanish before the user can answer.
function M.close(_)
  return content("TAB_CLOSED")
end

function M.close_all()
  return content("CLOSED_0_DIFF_TABS")
end

return M
