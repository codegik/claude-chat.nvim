# claude-chat.nvim

A minimal Neovim chat sidebar for [Claude Code](https://claude.com/claude-code).
It does **not** use the Anthropic API — it shells out to the `claude` CLI you
already have installed.

- The first message starts a fresh session: `claude -p "<message>"`
- Every following message continues it: `claude -p --continue "<message>"`
- Calls run asynchronously (`vim.system`), so Neovim never blocks.

## Requirements

- Neovim 0.10+ (uses `vim.system`)
- The `claude` CLI on your `PATH` (`claude --version`)

## Install (lazy.nvim, local dev)

In your lazy setup opts (e.g. `~/.config/nvim/lua/config/lazy.lua`):

```lua
require("lazy").setup({
  spec = { ... },
  dev = { path = "~/sources/codegik", fallback = true },
})
```

Then add a spec:

```lua
-- ~/.config/nvim/lua/plugins/claude-chat.lua
return {
  {
    "codegik/claude-chat.nvim",
    dev = true, -- use the local copy in dev.path
    cmd = { "ClaudeChat", "ClaudeChatReset" },
    keys = { { "<leader>ai", "<cmd>ClaudeChat<cr>", desc = "Claude Chat" } },
    config = function()
      require("claude-chat").setup()
    end,
  },
}
```

When you publish to GitHub, drop `dev = true` (or `fallback` will clone it).

## Usage

| Action | Command / key |
|--------|---------------|
| Toggle the sidebar | `:ClaudeChat` (or `<leader>ai`) |
| Send the message | `<CR>` (Enter), in the input window |
| New line in the message | `<S-CR>` (Shift+Enter) |
| Reset the session | `<C-l>`, or `:ClaudeChatReset` |
| Close the sidebar | `q` |

Autocompletion is disabled in the chat buffers.

Type in the bottom input box, send, and the reply appears in the transcript
above. Resetting forgets the conversation so the next message starts a new
`claude -p` session.

## Configuration

`setup()` is optional. Defaults shown:

```lua
require("claude-chat").setup({
  cli = "claude",          -- CLI executable
  extra_args = {},         -- args added to every call, e.g. { "--model", "sonnet" }
  width = 64,              -- sidebar width
  position = "right",      -- "right" | "left"
  input_height = 6,        -- input window height
  timeout = 180000,        -- per-request timeout (ms)
  keymaps = {
    submit = "<CR>",     -- Enter sends (normal + insert)
    newline = "<S-CR>",  -- Shift+Enter inserts a newline
    close = "q",
    reset = "<C-l>",
  },
})
```

## Testing environment

This plugin has been developed and tested on:

| Component | Value |
|-----------|-------|
| OS / WM | Arch Linux (Omarchy) + Hyprland |
| Terminal | Alacritty |
| Neovim | 0.12.2 |
| Plugin manager | lazy.nvim (LazyVim distro) |
| Completion | blink.cmp (disabled inside the chat buffers) |
| `claude` CLI | 2.1.x |

### Shift+Enter note for this setup

Alacritty does not implement the kitty keyboard protocol, so it cannot natively
distinguish Shift+Enter from Enter. Under Omarchy, Alacritty is configured to send
`ESC`+`CR` (`\r`) for Shift+Enter — this is intentional, because the Claude
Code CLI and other TUIs rely on it for multiline input. The plugin therefore
treats that `ESC`+`CR` sequence (in addition to `<S-CR>`) as "insert a newline",
so the terminal config is left untouched. Plain Enter sends the message.

On terminals that *do* support the kitty keyboard protocol (Kitty, Ghostty, Foot),
`<S-CR>` is delivered directly and the `ESC`+`CR` fallback is not needed.

## How sessions work

`--continue` resumes the **most recent** Claude conversation. If you run other
`claude` sessions in the same directory while chatting, a follow-up could attach
to the wrong one. A more robust scheme is to capture the session id from
`--output-format json` on the first call and use `--resume <id>` after — a
possible future enhancement.
