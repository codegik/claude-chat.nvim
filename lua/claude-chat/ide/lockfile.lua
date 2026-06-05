-- Reads/writes the discovery lock file Claude looks for: ~/.claude/ide/<port>.lock
local M = {}

local function dir()
  local home = vim.uv.os_homedir() or os.getenv("HOME")
  return home .. "/.claude/ide"
end

function M.path(port)
  return dir() .. "/" .. tostring(port) .. ".lock"
end

function M.write(port, token, workspace)
  vim.fn.mkdir(dir(), "p")
  local data = vim.json.encode({
    pid = vim.uv.os_getpid(),
    workspaceFolders = { workspace or vim.fn.getcwd() },
    ideName = "Neovim",
    transport = "ws",
    authToken = token,
  })
  local f = io.open(M.path(port), "w")
  if not f then
    return false
  end
  f:write(data)
  f:close()
  return true
end

function M.remove(port)
  if port then
    os.remove(M.path(port))
  end
end

return M
