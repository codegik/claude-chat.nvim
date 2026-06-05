local config = require("claude-chat.config")

-- Manages a single Claude CLI conversation.
--
-- The very first message starts a fresh session:   claude -p "<msg>"
-- Every following message continues that session:   claude -p --continue "<msg>"
local M = {}

-- Whether a conversation has been started yet (controls --continue).
M.has_session = false
-- Whether a CLI call is currently in flight.
M.running = false

local function build_cmd(prompt)
  local opts = config.options
  local cmd = { opts.cli, "-p" }
  if M.has_session then
    table.insert(cmd, "--continue")
  end
  vim.list_extend(cmd, opts.extra_args)
  -- Prompt is passed as a distinct argv entry, so no shell quoting is needed.
  table.insert(cmd, prompt)
  return cmd
end

-- Send a prompt to the CLI.
-- callbacks.on_done(text, err) is invoked on the main loop when the call finishes.
function M.send(prompt, callbacks)
  if M.running then
    callbacks.on_done(nil, "A request is already in progress.")
    return
  end

  local opts = config.options
  if vim.fn.executable(opts.cli) == 0 then
    callbacks.on_done(nil, ("'%s' was not found on your PATH."):format(opts.cli))
    return
  end

  M.running = true
  local cmd = build_cmd(prompt)

  vim.system(cmd, { text = true, timeout = opts.timeout }, function(obj)
    -- vim.system callbacks run in a fast event context; defer buffer work.
    vim.schedule(function()
      M.running = false

      if obj.code ~= 0 then
        local msg = obj.stderr
        if msg == nil or msg == "" then
          msg = ("claude exited with code %d"):format(obj.code)
        end
        callbacks.on_done(nil, vim.trim(msg))
        return
      end

      -- A successful call means the conversation now exists; continue it next time.
      M.has_session = true
      callbacks.on_done(vim.trim(obj.stdout or ""), nil)
    end)
  end)
end

-- Forget the current conversation; the next message starts fresh.
function M.reset()
  M.has_session = false
end

return M
