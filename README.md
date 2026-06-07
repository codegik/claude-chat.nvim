# claude-chat.nvim

A Neovim sidebar that hosts the **interactive [Claude Code](https://claude.com/claude-code) TUI**.

It does not use the Anthropic API and it does not wrap `claude -p`. Instead it
runs the real `claude` terminal UI inside a Neovim terminal buffer. Because it is
the actual TUI, everything behaves exactly like running `claude` in a terminal:

- streaming replies and multi-turn conversation
- **interactive permission prompts you answer yourself** (e.g. "Allow running
  `bundle exec jekyll build`?") — Claude asks, you decide
- option selection, slash commands, `/clear`, etc.
- **live editor awareness** — Claude automatically knows your open file,
  cursor/selection, and diagnostics, and can open files and propose diffs (see
  [IDE integration](#ide-integration))

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
    cmd = { "ClaudeChat", "ClaudeChatReset", "ClaudeChatFile" },
    keys = {
      { "<leader>ai", "<cmd>ClaudeChat<cr>", desc = "Claude Chat" },
      { "<leader>af", "<cmd>ClaudeChatFile<cr>", desc = "Claude Chat: add current file" },
    },
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
| Add the current file to Claude's context | `:ClaudeChatFile` (or `<leader>af`) |
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
  ide_integration = true, -- editor awareness via the WebSocket MCP server
  auto_allow_ide_tools = true, -- pass --allowedTools mcp__ide (no per-call prompt)
  auto_allow_edits = false, -- also allow Edit/Write/MultiEdit (no edit prompt)
  keymaps = {           -- terminal-mode keys, scoped to the Claude buffer
    hide = "<C-q>",
    nav = { left = "<C-h>", down = "<C-j>", up = "<C-k>", right = "<C-l>" },
    resize = { left = "<C-Left>", right = "<C-Right>", up = "<C-Up>", down = "<C-Down>" },
  },
})
```

Because Claude runs in Neovim's working directory, "build/test the project" acts
on whatever folder you launched Neovim from (override with `cwd`).

## IDE integration

When the sidebar opens, the plugin starts a small **WebSocket MCP server** (the
same protocol Claude's VS Code/JetBrains extensions use) so Claude is aware of
your editor — no `@`-mention needed. You can just ask *"what file am I in?"* or
*"explain the function I'm looking at"* and Claude knows.

How it works:

1. A WebSocket server starts on `127.0.0.1` at a random port, with a random
   per-session auth token.
2. A discovery lock file is written to `~/.claude/ide/<port>.lock`, and the CLI
   is launched with `CLAUDE_CODE_SSE_PORT` + `ENABLE_IDE_INTEGRATION=true` so it
   connects back and authenticates.
3. The plugin sends `selection_changed` as you move/select, and exposes MCP tools:
   `getCurrentSelection`, `getLatestSelection`, `getOpenEditors`,
   `getWorkspaceFolders`, `getDiagnostics`, `openFile`, `checkDocumentDirty`,
   `saveDocument`, and the diff tools `openDiff`, `close_tab`, `closeAllDiffTabs`.

By default the plugin launches the CLI with `--allowedTools mcp__ide` so Claude
uses these tools without a permission prompt on every call (set
`auto_allow_ide_tools = false` to be prompted instead). The server starting and
Claude connecting is fully automatic — you never run anything by hand.

### Editing

When Claude proposes an edit, the plugin shows it as a **live diff preview** in
the editor — current vs. proposed, side by side (in throwaway scratch buffers),
to the left of the Claude sidebar. You approve or reject in the **Claude console**
as usual; the preview is read-only and just for context (press `q` to dismiss it
early). Once you confirm and Claude writes the file, the preview closes
automatically and the editor shows the updated file, with focus back in the
console.

The plugin never writes the file itself — Claude does the real write. To skip
Claude's own "make this edit?" prompt, set `auto_allow_edits = true`
(pre-approves `Edit`/`Write`/`MultiEdit`).

The server binds to localhost only and rejects any connection whose
`x-claude-code-ide-authorization` header doesn't match the session token. The
lock file is removed when the session ends or Neovim exits.

Disable it with `ide_integration = false` in `setup()`.

## Running the tests

The Lua suite uses [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)'s
busted harness. With plenary installed (it ships with LazyVim):

```sh
make test
```

It covers SHA-1, WebSocket framing, the lock file, MCP dispatch + tools, and a
live end-to-end socket test (real handshake, auth rejection, and a JSON-RPC
round-trip through the server).

## Testing environment

Developed and tested on:

| Component | Value |
|-----------|-------|
| OS / WM | Arch Linux (Omarchy) + Hyprland |
| Terminal | Alacritty |
| Neovim | 0.12.2 |
| Plugin manager | lazy.nvim (LazyVim distro) |
| `claude` CLI | 2.1.x |
