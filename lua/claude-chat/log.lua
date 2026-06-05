-- Lightweight file logger for troubleshooting. Writes to stdpath("log").
-- Safe to call from libuv fast-event contexts (uses plain Lua io, no vim API
-- beyond stdpath which is resolved once at load).
local M = {}

M.levels = { off = 0, error = 1, warn = 2, info = 3, debug = 4 }
M._level = M.levels.info
M._path = vim.fn.stdpath("log") .. "/claude-chat.log"

function M.path()
  return M._path
end

function M.set_level(name)
  if type(name) == "string" and M.levels[name] then
    M._level = M.levels[name]
  elseif type(name) == "number" then
    M._level = name
  end
end

local function emit(level_name, level_value, msg, ...)
  if level_value > M._level then
    return
  end
  if select("#", ...) > 0 then
    msg = msg:format(...)
  end
  local line = string.format("%s %-5s %s\n", os.date("%Y-%m-%d %H:%M:%S"), level_name:upper(), msg)
  local f = io.open(M._path, "a")
  if f then
    f:write(line)
    f:close()
  end
end

function M.error(msg, ...)
  emit("error", M.levels.error, msg, ...)
end

function M.warn(msg, ...)
  emit("warn", M.levels.warn, msg, ...)
end

function M.info(msg, ...)
  emit("info", M.levels.info, msg, ...)
end

function M.debug(msg, ...)
  emit("debug", M.levels.debug, msg, ...)
end

function M.clear()
  local f = io.open(M._path, "w")
  if f then
    f:close()
  end
end

return M
