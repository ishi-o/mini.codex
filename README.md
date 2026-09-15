# mini.codex

A small Neovim plugin for running and resuming the Codex CLI in a configurable Neovim terminal window.

Requires Neovim 0.12 or later.

## Setup

```lua
{
	"ishi-o/mini.codex",
	config = function()
		require("mini.codex").setup()
	end,
}
```

The default window configuration is:

```lua
---@type vim.api.keyset.win_config
local win = {
	vertical = true,
	width = math.floor(vim.o.columns * 0.4),
	win = 0,
	split = "right",
}
```

Customize it only when needed by passing a `win` table to `setup()`. It is passed directly to `nvim_open_win()`, so it can also define a floating window.

```lua
---@type mini.codex.Config
local opts = {
	win = {
		relative = "editor",
		width = 80,
		height = 30,
		row = 2,
		col = 4,
		style = "minimal",
		border = "rounded",
	},
}

require("mini.codex").setup(opts)
```

The window label is automatically `Codex [session-id]`.

## Input pane (optional)

Codex's built-in Vim mode is too limited for full Neovim editing workflows, so mini.codex offers an optional input pane backed by a real normal buffer. It is not loaded or opened by default. Enable it with an `input` table; mini.codex divides the Codex window into an upper terminal and lower input buffer.

The two panes share the original Codex window height in both split and floating layouts. Resize either one with `nvim_win_set_height()` and the other adjusts automatically.

The buffer uses the `markdown.codex` filetype, allowing [nvim-codex-lsp](https://github.com/ishi-o/nvim-codex-lsp) to attach automatically and provide completions.

- `Enter` behaves normally, so it inserts a newline in insert mode and never submits to Codex.
- The sync key (default `<C-g>`) opens the mapping input with Codex's complete current draft. Press it again to replace Codex's draft with the edited text and return to the terminal.

Synchronization uses Codex's external-editor support inside the current Neovim instance. The plugin sets `VISUAL` only for the Codex process.

Configure it with the `input` table (or use `input = false` to disable an enabled pane):

```lua
---@type mini.codex.Config
local opts = {
	input = {
		enabled = true,
		prompt = "",
		height = 0.5, -- fraction of the Codex window height, or absolute rows (> 1)
		jump_key = "<C-g>", -- key that synchronizes and switches inputs
	},
}

require("mini.codex").setup(opts)
```

`mini.codex.Config` and `mini.codex.InputConfig` are exported LuaLS annotations. `win` uses Neovim's `vim.api.keyset.win_config`, so native window fields also receive completion and diagnostics.

## Commands

```text
:Codex        # toggle codex window
:Codex toggle # toggle codex window
:Codex new    # new a codex session
:Codex last	  # codex resume --last
:Codex pick	  # pick a session
:Codex prev	  # previous session, pick the last if there is no active session now
:Codex next	  # next session
:Codex stop	  # close current session
```

Session navigation reads Codex's local `$CODEX_HOME/state_5.sqlite` database, falling back to `~/.codex/state_5.sqlite`.
