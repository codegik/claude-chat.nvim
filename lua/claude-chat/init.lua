local config = require("claude-chat.config")
local ui = require("claude-chat.ui")

local M = {}

-- Optional: only needed to override defaults. The plugin works without it.
function M.setup(opts)
  config.setup(opts)
end

M.toggle = ui.toggle
M.open = ui.open
M.close = ui.close
M.reset = ui.reset

return M
