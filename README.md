# claude-chat.nvim

A Neovim sidebar that hosts the **interactive [Claude Code](https://claude.com/claude-code) TUI**.

It does not use the Anthropic API and it does not wrap `claude -p`. Instead it
runs the real `claude` terminal UI inside a Neovim terminal buffer. Because it is
the actual TUI, everything behaves exactly like running `claude` in a terminal:

- streaming replies and multi-turn conversation
- **interactive permission prompts you answer yourself** (e.g. "Allow running
  `bundle exec jekyll build`?") — Claude asks, you decide
- option selection, slash commands, `/clear`, etc.

> Earlier versions of this plugin shelled out to `claude -p --continue`. That
> approach can never show interactive permission prompts: `-p` (print) mode
> computes one reply and exits, with no live process to ask you anything. Hosting
> the interactive TUI is the only way to get "Claude asks, you decide".

## Requirements

- Neovim 0.10+ (uses `jobstart({ term = true })`)
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
| Talk to Claude | Just type in the terminal — it's the normal Claude TUI |
| Answer a permission prompt | Use the keys the prompt shows (e.g. `y`/`n`, arrows + `<CR>`) |
| Back to the editor / other window | `<C-h>` / `<C-j>` / `<C-k>` / `<C-l>` |
| Resize the sidebar | `<C-Left>` / `<C-Right>` (and `<C-Up>` / `<C-Down>`) |
| Hide the sidebar (Claude keeps running) | `<C-q>` |
| Leave terminal mode (to scroll/copy) | `<C-\><C-n>`, then normal Neovim keys |
| New conversation | `:ClaudeChatReset` |

The sidebar is a real terminal, so by default every keystroke goes to Claude. The
keys above are the exception: they are terminal-mode mappings (scoped to the Claude
buffer) that Neovim intercepts, so you can jump back to the editor, resize, or hide
the sidebar without leaving the TUI. They mirror LazyVim's window keys and are all
configurable (see below) — set one to `false` to free that key for Claude.

Navigating away with `<C-h>` and back with `<C-l>` keeps the conversation running;
you return to the same live session and land straight in insert mode. Toggling the
sidebar closed only **hides** it. `:ClaudeChatReset` stops the process and starts fresh.

## Configuration

`setup()` is optional. Defaults shown:

```lua
require("claude-chat").setup({
  cli = "claude",       -- CLI executable
  extra_args = {},      -- args passed to the TUI, e.g. { "--model", "sonnet" }
  width = 80,           -- sidebar width
  position = "right",   -- "right" | "left"
  cwd = nil,            -- working dir for the session (nil = Neovim's cwd)
  start_insert = true,  -- enter terminal mode when the sidebar opens
  keymaps = {           -- terminal-mode keys, scoped to the Claude buffer
    hide = "<C-q>",
    nav = { left = "<C-h>", down = "<C-j>", up = "<C-k>", right = "<C-l>" },
    resize = { left = "<C-Left>", right = "<C-Right>", up = "<C-Up>", down = "<C-Down>" },
  },
})
```

Because Claude runs in Neovim's working directory, "build/test the project" acts
on whatever folder you launched Neovim from (override with `cwd`).

## Testing environment

Developed and tested on:

| Component | Value |
|-----------|-------|
| OS / WM | Arch Linux (Omarchy) + Hyprland |
| Terminal | Alacritty |
| Neovim | 0.12.2 |
| Plugin manager | lazy.nvim (LazyVim distro) |
| `claude` CLI | 2.1.x |
