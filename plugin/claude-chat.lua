-- Auto-loaded by Neovim (native package / runtimepath). Registers user commands.
-- Calling require("claude-chat").setup() is optional and only needed to override defaults.

if vim.g.loaded_claude_chat then
  return
end
vim.g.loaded_claude_chat = true

vim.api.nvim_create_user_command("ClaudeChat", function()
  require("claude-chat.ui").toggle()
end, { desc = "Toggle the Claude chat sidebar" })

vim.api.nvim_create_user_command("ClaudeChatReset", function()
  require("claude-chat.ui").reset()
end, { desc = "Reset the Claude chat session (next message starts fresh)" })

vim.api.nvim_create_user_command("ClaudeChatContinue", function()
  require("claude-chat.ui").continue()
end, { desc = "Open the chat resuming the most recent conversation (claude --continue)" })

vim.api.nvim_create_user_command("ClaudeChatSessions", function()
  require("claude-chat.ui").choose()
end, { desc = "Pick a past session for this directory to resume, or start a new one" })

vim.api.nvim_create_user_command("ClaudeChatFile", function()
  require("claude-chat.ui").add_current_file()
end, { desc = "Send the current file to Claude as an @-mention" })

vim.api.nvim_create_user_command("ClaudeChatLog", function()
  vim.cmd("tabnew " .. vim.fn.fnameescape(require("claude-chat.log").path()))
end, { desc = "Open the claude-chat log file" })
