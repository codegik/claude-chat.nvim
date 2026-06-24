local M = {}

function M.encode_cwd(cwd)
  return (cwd:gsub("[^%w]", "-"))
end

function M.dir(cwd)
  return vim.fn.expand("~/.claude/projects/") .. M.encode_cwd(cwd)
end

local function title_of(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end

  local title, prompt
  for _, line in ipairs(lines) do
    if line:find('"aiTitle"', 1, true) then
      local decoded = vim.json.decode(line)
      if type(decoded) == "table" and decoded.aiTitle then
        title = decoded.aiTitle
      end
    elseif line:find('"lastPrompt"', 1, true) then
      local decoded = vim.json.decode(line)
      if type(decoded) == "table" and decoded.lastPrompt then
        prompt = decoded.lastPrompt
      end
    end
  end

  local label = title or prompt
  if not label then
    return "(untitled)"
  end
  label = label:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if #label > 70 then
    label = label:sub(1, 67) .. "..."
  end
  return label
end

function M.list(cwd)
  local dir = M.dir(cwd)
  local entries = {}
  for _, path in ipairs(vim.fn.glob(dir .. "/*.jsonl", true, true)) do
    local id = vim.fn.fnamemodify(path, ":t:r")
    table.insert(entries, {
      id = id,
      title = title_of(path) or "(untitled)",
      mtime = vim.fn.getftime(path),
    })
  end
  table.sort(entries, function(a, b)
    return a.mtime > b.mtime
  end)
  return entries
end

function M.reltime(mtime, now)
  local diff = now - mtime
  if diff < 0 then
    diff = 0
  end
  if diff < 60 then
    return "just now"
  elseif diff < 3600 then
    return math.floor(diff / 60) .. "m ago"
  elseif diff < 86400 then
    return math.floor(diff / 3600) .. "h ago"
  elseif diff < 172800 then
    return "yesterday"
  elseif diff < 604800 then
    return math.floor(diff / 86400) .. "d ago"
  end
  return os.date("%b %d", mtime)
end

return M
