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

## Requirements

- Neovim 0.10+ (uses `jobstart({ term = true })`)
- The `claude` CLI on your `PATH` (`claude --version`)

## Install (lazy.nvim)

Add a spec that points at the GitHub repo — lazy.nvim will clone it and keep it
updated:

```lua
-- ~/.config/nvim/lua/plugins/claude-chat.lua
return {
  {
    "codegik/claude-chat.nvim",
    cmd = { "ClaudeChat", "ClaudeChatReset", "ClaudeChatFile", "ClaudeChatContinue", "ClaudeChatSessions" },
    keys = {
      { "<leader>ai", "<cmd>ClaudeChat<cr>", desc = "Claude Chat: toggle sidebar" },
      { "<leader>af", "<cmd>ClaudeChatFile<cr>", desc = "Claude Chat: add current file" },
    },
    config = function()
      require("claude-chat").setup()
    end,
  },
}
```

Run `:Lazy update` to pull the latest changes.

## Usage

| Action                                   | Command / key                                                 |
| ---------------------------------------- | ------------------------------------------------------------- |
| Toggle the sidebar                       | `:ClaudeChat` (or `<leader>ai`)                               |
| Add the current file to Claude's context | `:ClaudeChatFile` (or `<leader>af`)                           |
| Talk to Claude                           | Just type in the terminal — it's the normal Claude TUI        |
| Answer a permission prompt               | Use the keys the prompt shows (e.g. `y`/`n`, arrows + `<CR>`) |
| Back to the editor / other window        | `<C-h>` / `<C-j>` / `<C-k>` / `<C-l>`                         |
| Resize the sidebar                       | `<C-Left>` / `<C-Right>` (and `<C-Up>` / `<C-Down>`)          |
| Hide the sidebar (Claude keeps running)  | `<C-q>`                                                       |
| Leave terminal mode (to scroll/copy)     | `<C-\><C-n>`, then normal Neovim keys                         |
| New conversation                         | `:ClaudeChatReset`                                            |

The sidebar is a real terminal, so by default every keystroke goes to Claude. The
keys above are the exception: they are terminal-mode mappings (scoped to the Claude
buffer) that Neovim intercepts, so you can jump back to the editor, resize, or hide
the sidebar without leaving the TUI. They mirror LazyVim's window keys and are all
configurable (see below) — set one to `false` to free that key for Claude.

Navigating away with `<C-h>` and back with `<C-l>` keeps the conversation running;
you return to the same live session and land straight in insert mode. Toggling the
sidebar closed only **hides** it. `:ClaudeChatReset` stops the process and starts fresh.

When you open the sidebar with no live session and this directory already has past
Claude conversations, `:ClaudeChat` shows a picker (Claude's own persisted sessions
from `~/.claude/projects/`, listed by title and recency) so you can resume one or pick
**New session**. With a session already running, or in a directory with no history, it
just opens — no prompt. Set `session_picker = false` to always start fresh; either way
`:ClaudeChatSessions` opens the picker on demand. Resuming runs `claude --resume <id>`.

## Configuration

`setup()` is optional. Defaults shown:

```lua
require("claude-chat").setup({
  cli = "claude",       -- CLI executable
  extra_args = {},      -- args passed to the TUI, e.g. { "--model", "sonnet" }
  width = 80,           -- sidebar width
  position = "right",   -- "right" | "left"
  cwd = nil,            -- working dir for the session (nil = Neovim's cwd)
  session_picker = true, -- on open with no live session, list this dir's past sessions
  start_insert = true,  -- enter terminal mode when the sidebar opens
  ide_integration = true, -- editor awareness via the WebSocket MCP server
  auto_allow_ide_tools = true, -- pass --allowedTools mcp__ide (no per-call prompt)
  auto_allow_edits = false, -- also allow Edit/Write/MultiEdit (no edit prompt)
  open_file_tool = true,    -- expose an open_file tool so "open the readme" opens it
  open_in_editor_hint = true, -- nudge Claude to prefer open_file over its Read tool
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
your editor — no `@`-mention needed. You can just ask _"what file am I in?"_ or
_"explain the function I'm looking at"_ and Claude knows.

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

### Opening files in the editor

Asking _"open the readme"_ should put the file in your editor — but Claude Code's
IDE channel keeps `openFile` for its **own** use and never offers it to the model
(the only IDE tools the model can call are `getDiagnostics` and `executeCode`).
Left alone, Claude just reads and summarizes the file instead.

So the plugin also hosts a **second MCP server inside Neovim**
(`lua/claude-chat/mcp_http.lua`), registered with the CLI by URL
(`--mcp-config` with `type: "http"`). Claude's MCP client connects to it over
HTTP and the tools run in-process against the editor — no child process:

- `open_file` — opens a file in a real editor window. A short system-prompt hint
  nudges Claude to prefer it over `Read` for "open/show/go to" requests.
- `current_file` — asks the editor which file you currently have open, returning
  the absolute path, cursor position, and any selected text — so Claude can
  answer _"what file am I looking at?"_ rather than guessing.

Both are pre-approved via `--allowedTools mcp__claude-chat`. The server binds to
localhost only and rejects any request whose `Authorization` bearer token
doesn't match the per-session token. Turn it off with `open_file_tool = false`,
or drop the open-file hint with `open_in_editor_hint = false`.

### Semantic code intelligence (LSP)

Claude Code in its own sandbox has **no language server** — it finds references
by grepping and jumps to definitions by guessing, and the IDE channel offers the
model nothing here either (only `getDiagnostics`). This plugin bridges your
editor's **live LSP** to the model over the same in-process MCP server, so Claude
gets accurate, semantic navigation instead of text search:

- `lsp_definition` — where a symbol is defined (exact, across the project and
  into dependencies).
- `lsp_references` — every reference to a symbol — no false hits in comments or
  strings, resolves overloads/dynamic dispatch that grep misses.
- `lsp_hover` — the symbol's real resolved type, signature, and doc comment.
- `lsp_document_symbols` — a structural outline of a file.
- `lsp_workspace_symbols` — project-wide symbol search by name.

A symbol is addressed by name (`{ filePath, symbol, line? }`); the plugin loads
the file, lets your LSP attach, resolves the position, and forwards the request.
If no language server is attached for the filetype, the tool says so rather than
guessing. These ride the same MCP server as the open-file tools, so they need
`open_file_tool` enabled; turn just the LSP tools off with `lsp_tools = false`.

**Why this matters:**

- **Accuracy over guesswork.** A grep for `start` matches comments, strings, and
  every unrelated `start` in the project; `lsp_references` returns the _actual_
  references to the symbol you mean — and finds the ones grep misses, like calls
  through dynamic dispatch, overloads, or re-exports.
- **Fewer wrong edits.** When Claude knows every real call site before it changes
  a signature, it updates all of them and skips the false matches — instead of a
  find-and-replace that breaks a string literal or misses a caller in another file.
- **Real types, not inferred ones.** `lsp_hover` gives the language server's
  resolved signature and docs, so Claude reasons from the truth rather than
  pattern-matching the surrounding code (which is where hallucinated APIs come from).
- **Cheaper and faster.** One LSP request returns the exact locations; the
  alternative is Claude reading many files to reconstruct what the language server
  already knows, burning tokens and turns to arrive at a less reliable answer.
- **Your toolchain, for free.** It uses whatever language servers you already have
  configured in Neovim — every language, no extra setup, no servers running in
  Claude's sandbox.

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

| Component      | Value                           |
| -------------- | ------------------------------- |
| OS / WM        | Arch Linux (Omarchy) + Hyprland |
| Terminal       | Alacritty                       |
| Neovim         | 0.12.2                          |
| Plugin manager | lazy.nvim (LazyVim distro)      |
| `claude` CLI   | 2.1.x                           |
