-- MCP tool implementations. Each returns the standard
-- { content = { { type = "text", text = ... } } } shape.
local selection = require("claude-chat.ide.selection")
local diff = require("claude-chat.ide.diff")

local M = {}

local function text_content(s)
  return { content = { { type = "text", text = s } } }
end

-- Encode a table, forcing empty tables to JSON arrays where needed.
local function json_content(t)
  return text_content(vim.json.encode(t))
end

local function file_url(path)
  return "file://" .. (path:gsub(" ", "%%20"))
end

local function strip_uri(uri)
  return (uri:gsub("^file://", ""))
end

local function find_buf_by_path(path)
  local target = vim.fs.normalize(path)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" and vim.fs.normalize(name) == target then
        return b
      end
    end
  end
  return nil
end

-- The buffer the user is actively editing (falls back to the tracked file).
local function active_editor_buf()
  local b = vim.api.nvim_get_current_buf()
  if vim.bo[b].buftype == "" and vim.api.nvim_buf_get_name(b) ~= "" then
    return b
  end
  local cur = selection.get()
  if cur then
    return find_buf_by_path(cur.filePath)
  end
  return nil
end

local function pick_editor_window()
  local cur = vim.api.nvim_get_current_win()
  if vim.bo[vim.api.nvim_win_get_buf(cur)].buftype == "" then
    return cur
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(w)].buftype == "" then
      return w
    end
  end
  vim.cmd("topleft vsplit")
  return vim.api.nvim_get_current_win()
end

local handlers = {}

function handlers.getCurrentSelection()
  local cur = selection.get()
  if not cur then
    return json_content({ success = false, message = "No active editor found" })
  end
  return json_content({
    success = true,
    text = cur.text,
    filePath = cur.filePath,
    selection = { start = cur.selection.start, ["end"] = cur.selection["end"] },
  })
end

function handlers.getLatestSelection()
  local cur = selection.get_latest()
  if not cur then
    return json_content({ success = false, message = "No selection available" })
  end
  return json_content({
    success = true,
    text = cur.text,
    filePath = cur.filePath,
    selection = { start = cur.selection.start, ["end"] = cur.selection["end"] },
  })
end

function handlers.getOpenEditors()
  local active = active_editor_buf()
  local tabs = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buflisted and vim.bo[b].buftype == "" then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" then
        tabs[#tabs + 1] = {
          uri = file_url(name),
          isActive = (b == active),
          label = vim.fn.fnamemodify(name, ":t"),
          languageId = vim.bo[b].filetype,
          isDirty = vim.bo[b].modified,
        }
      end
    end
  end
  return text_content(vim.json.encode({ tabs = tabs }))
end

function handlers.getWorkspaceFolders()
  local cwd = vim.fn.getcwd()
  return json_content({
    success = true,
    folders = { { name = vim.fn.fnamemodify(cwd, ":t"), uri = file_url(cwd), path = cwd } },
    rootPath = cwd,
  })
end

local SEVERITY = { "Error", "Warning", "Information", "Hint" }

function handlers.getDiagnostics(args)
  local function for_buf(b)
    local out = {}
    for _, d in ipairs(vim.diagnostic.get(b)) do
      out[#out + 1] = {
        message = d.message,
        severity = SEVERITY[d.severity] or "Error",
        range = {
          start = { line = d.lnum, character = d.col },
          ["end"] = { line = d.end_lnum or d.lnum, character = d.end_col or d.col },
        },
        source = d.source,
      }
    end
    return out
  end

  local result = {}
  if args and args.uri and args.uri ~= "" then
    local b = find_buf_by_path(strip_uri(args.uri))
    if b then
      result[#result + 1] = { uri = args.uri, diagnostics = for_buf(b) }
    end
  else
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(b)
      if vim.api.nvim_buf_is_loaded(b) and name ~= "" then
        local diags = for_buf(b)
        if #diags > 0 then
          result[#result + 1] = { uri = file_url(name), diagnostics = diags }
        end
      end
    end
  end
  return text_content(#result == 0 and "[]" or vim.json.encode(result))
end

-- Open a path in a real editor window (not the chat terminal) and optionally
-- place the cursor on the first line containing `startText`. Returns a short
-- status string. Public so the stdio MCP bridge can call it over RPC — that
-- bridge exposes "open file" to the model, which the internal IDE channel does not.
function M.open_in_editor(path, startText)
  if not path or path == "" then
    return "Error: filePath is required"
  end
  vim.api.nvim_set_current_win(pick_editor_window())
  vim.cmd("edit " .. vim.fn.fnameescape(path))

  if startText and startText ~= "" then
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    for i, l in ipairs(lines) do
      local c = l:find(startText, 1, true)
      if c then
        pcall(vim.api.nvim_win_set_cursor, 0, { i, c - 1 })
        break
      end
    end
  end
  return "Opened " .. path .. " in the editor"
end

function handlers.openFile(args)
  local path = args.filePath
  if not path then
    return text_content("Error: filePath is required")
  end

  if args.makeFrontmost == false then
    local b = vim.fn.bufadd(path)
    vim.fn.bufload(b)
    return json_content({
      success = true,
      filePath = path,
      languageId = vim.bo[b].filetype,
      lineCount = vim.api.nvim_buf_line_count(b),
    })
  end

  return text_content(M.open_in_editor(path, args.startText))
end

function handlers.checkDocumentDirty(args)
  local b = find_buf_by_path(args.filePath)
  if not b then
    return json_content({ success = false, message = "Document not open: " .. tostring(args.filePath) })
  end
  return json_content({
    success = true,
    filePath = args.filePath,
    isDirty = vim.bo[b].modified,
    isUntitled = false,
  })
end

function handlers.saveDocument(args)
  local b = find_buf_by_path(args.filePath)
  if not b then
    return json_content({ success = false, message = "Document not open: " .. tostring(args.filePath) })
  end
  vim.api.nvim_buf_call(b, function()
    vim.cmd("silent write")
  end)
  return json_content({
    success = true,
    filePath = args.filePath,
    saved = true,
    message = "Document saved successfully",
  })
end

function handlers.close_tab(args)
  return diff.close(args.tab_name)
end

function handlers.closeAllDiffTabs()
  return diff.close_all()
end

function handlers.executeCode()
  return text_content("executeCode is not supported in this editor.")
end

-- Tool schemas advertised via tools/list.
local function obj(props, required)
  return { type = "object", properties = props or vim.empty_dict(), required = required }
end

local SCHEMAS = {
  getCurrentSelection = { desc = "Get the current text selection in the active editor", input = obj() },
  getLatestSelection = { desc = "Get the most recent text selection", input = obj() },
  getOpenEditors = { desc = "Get information about currently open editors", input = obj() },
  getWorkspaceFolders = { desc = "Get all workspace folders currently open in the IDE", input = obj() },
  getDiagnostics = {
    desc = "Get language diagnostics",
    input = obj({ uri = { type = "string" } }),
  },
  openFile = {
    desc = "Open a file in the editor and optionally select a range of text",
    input = obj({
      filePath = { type = "string" },
      preview = { type = "boolean" },
      startText = { type = "string" },
      endText = { type = "string" },
      selectToEndOfLine = { type = "boolean" },
      makeFrontmost = { type = "boolean" },
    }, { "filePath" }),
  },
  openDiff = {
    desc = "Open a diff of proposed changes (blocks until the user accepts or rejects)",
    input = obj({
      old_file_path = { type = "string" },
      new_file_path = { type = "string" },
      new_file_contents = { type = "string" },
      tab_name = { type = "string" },
    }, { "old_file_path", "new_file_path", "new_file_contents", "tab_name" }),
  },
  checkDocumentDirty = {
    desc = "Check if a document has unsaved changes",
    input = obj({ filePath = { type = "string" } }, { "filePath" }),
  },
  saveDocument = {
    desc = "Save a document with unsaved changes",
    input = obj({ filePath = { type = "string" } }, { "filePath" }),
  },
  close_tab = {
    desc = "Close a tab by name",
    input = obj({ tab_name = { type = "string" } }, { "tab_name" }),
  },
  closeAllDiffTabs = { desc = "Close all diff tabs in the editor", input = obj() },
  executeCode = {
    desc = "Execute code (not supported)",
    input = obj({ code = { type = "string" } }, { "code" }),
  },
}

function M.list()
  local tools = {}
  for name, spec in pairs(SCHEMAS) do
    tools[#tools + 1] = { name = name, description = spec.desc, inputSchema = spec.input }
  end
  return tools
end

-- Dispatch a tool call. cb(result) is invoked when done (async for openDiff).
function M.call(name, args, cb)
  args = args or {}
  if name == "openDiff" then
    local ok, err = pcall(diff.open, args, cb)
    if not ok then
      cb(text_content("Error: " .. tostring(err)))
    end
    return
  end

  local handler = handlers[name]
  if not handler then
    cb(text_content("Tool not found: " .. tostring(name)))
    return
  end
  local ok, result = pcall(handler, args)
  cb(ok and result or text_content("Error: " .. tostring(result)))
end

return M
