-- Model-callable LSP tools: expose Neovim's live language server to Claude.
--
-- This is the plugin's differentiator. Claude Code in its sandbox has no
-- language server — it finds references by grep and jumps to definitions by
-- guessing. The IDE channel offers the model none of this either (only
-- getDiagnostics). These tools give Claude *semantic* code intelligence:
-- accurate references, definitions, hover types, and symbol search, served
-- in-process from the editor's attached LSP clients via the HTTP MCP server.
--
-- Positions are resolved from a symbol name (+ optional line hint) rather than
-- a cursor, since the model addresses code by name. Column resolution is
-- byte-based, which matches LSP's UTF-16 positions for ASCII identifiers (the
-- common case for code symbols).
local M = {}

-- Seams, overridable in tests (CI has no language server to attach).
M._get_clients = function(bufnr)
  local get = vim.lsp.get_clients or vim.lsp.get_active_clients
  return get({ bufnr = bufnr })
end
M._request = function(bufnr, method, params)
  return vim.lsp.buf_request_sync(bufnr, method, params, 2000)
end

local function json(t)
  return vim.json.encode(t)
end

local function fail(msg)
  return json({ success = false, message = msg })
end

-- Load a file into a buffer, detect its filetype so the LSP attaches, and wait
-- for a client. Returns bufnr, or nil + an error message.
local function attach(file)
  if not file or file == "" then
    return nil, "filePath is required"
  end
  local path = vim.fn.fnamemodify(file, ":p")
  if vim.fn.filereadable(path) == 0 then
    return nil, "file not found: " .. path
  end
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  if vim.bo[bufnr].filetype == "" then
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("filetype detect")
    end)
  end
  local clients = M._get_clients(bufnr)
  if #clients == 0 then
    vim.wait(2000, function()
      clients = M._get_clients(bufnr)
      return #clients > 0
    end)
  end
  if #clients == 0 then
    return nil, "no language server attached for filetype '" .. vim.bo[bufnr].filetype .. "'"
  end
  return bufnr
end

-- Word-boundary search for `symbol`, honoring an optional 1-based line hint.
-- Returns 0-based row, col (LSP coordinates), or nil + error.
function M._find_position(bufnr, symbol, line)
  if not symbol or symbol == "" then
    return nil, "symbol is required"
  end
  local pat = "%f[%w_]" .. vim.pesc(symbol) .. "%f[^%w_]"
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if line then
    local c = lines[line] and lines[line]:find(pat)
    if c then
      return line - 1, c - 1
    end
    return nil, ("symbol '%s' not found on line %d"):format(symbol, line)
  end
  for i, l in ipairs(lines) do
    local c = l:find(pat)
    if c then
      return i - 1, c - 1
    end
  end
  return nil, ("symbol '%s' not found in file"):format(symbol)
end

local function position_params(bufnr, row, col, extra)
  local p = {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = row, character = col },
  }
  if extra then
    for k, v in pairs(extra) do
      p[k] = v
    end
  end
  return p
end

-- buf_request_sync returns { [client_id] = { result = ..., error = ... } }.
-- Collect the non-nil .result values into a flat list.
local function results_of(res)
  local out = {}
  if type(res) ~= "table" then
    return out
  end
  for _, r in pairs(res) do
    if r.result ~= nil then
      out[#out + 1] = r.result
    end
  end
  return out
end

local function loc_entry(loc)
  local uri = loc.uri or loc.targetUri
  local range = loc.range or loc.targetSelectionRange or loc.targetRange
  if not uri or not range then
    return nil
  end
  return {
    file = vim.uri_to_fname(uri),
    line = range.start.line + 1,
    col = range.start.character + 1,
  }
end

-- Flatten a list of (Location | Location[] | LocationLink[]) results.
local function collect_locations(results)
  local entries = {}
  for _, result in ipairs(results) do
    local list = (result.uri or result.targetUri) and { result } or result
    for _, loc in ipairs(list) do
      local e = loc_entry(loc)
      if e then
        entries[#entries + 1] = e
      end
    end
  end
  return entries
end

local function position_request(args, method, extra)
  local bufnr, err = attach(args.filePath)
  if not bufnr then
    return nil, err
  end
  local row, col, ferr = M._find_position(bufnr, args.symbol, args.line)
  if not row then
    return nil, ferr
  end
  return results_of(M._request(bufnr, method, position_params(bufnr, row, col, extra)))
end

function M.definition(args)
  local results, err = position_request(args, "textDocument/definition")
  if not results then
    return fail(err)
  end
  return json({ success = true, locations = collect_locations(results) })
end

function M.references(args)
  local results, err = position_request(args, "textDocument/references", {
    context = { includeDeclaration = true },
  })
  if not results then
    return fail(err)
  end
  return json({ success = true, references = collect_locations(results) })
end

function M.hover(args)
  local results, err = position_request(args, "textDocument/hover")
  if not results then
    return fail(err)
  end
  local text
  for _, r in ipairs(results) do
    local c = r and r.contents
    if type(c) == "string" then
      text = c
    elseif type(c) == "table" then
      if c.value then -- MarkupContent / MarkedString { language, value }
        text = c.value
      else -- MarkedString[]
        local parts = {}
        for _, m in ipairs(c) do
          parts[#parts + 1] = type(m) == "string" and m or m.value
        end
        text = table.concat(parts, "\n")
      end
    end
    if text and text ~= "" then
      break
    end
  end
  if not text or text == "" then
    return fail("no hover information")
  end
  return json({ success = true, hover = text })
end

local SYMBOL_KIND = vim.lsp.protocol.SymbolKind

local function flatten_symbols(items, out, file)
  for _, s in ipairs(items) do
    local range = s.range or (s.location and s.location.range)
    out[#out + 1] = {
      name = s.name,
      kind = SYMBOL_KIND[s.kind] or tostring(s.kind),
      file = file or (s.location and vim.uri_to_fname(s.location.uri)),
      line = range and (range.start.line + 1) or nil,
    }
    if s.children then
      flatten_symbols(s.children, out, file)
    end
  end
end

function M.document_symbols(args)
  local bufnr, err = attach(args.filePath)
  if not bufnr then
    return fail(err)
  end
  local results = results_of(M._request(bufnr, "textDocument/documentSymbol", {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
  }))
  local out = {}
  for _, r in ipairs(results) do
    flatten_symbols(r, out, args.filePath)
  end
  return json({ success = true, symbols = out })
end

function M.workspace_symbols(args)
  -- workspace/symbol is project-wide; route it through any attached buffer.
  local bufnr
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and #M._get_clients(b) > 0 then
      bufnr = b
      break
    end
  end
  if not bufnr then
    return fail("no language server is running in this session")
  end
  local results = results_of(M._request(bufnr, "workspace/symbol", { query = args.query or "" }))
  local out = {}
  for _, r in ipairs(results) do
    flatten_symbols(r, out, nil)
  end
  return json({ success = true, symbols = out })
end

return M
