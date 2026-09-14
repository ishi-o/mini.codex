# mini.codex

A small Neovim plugin for running and resuming the Codex CLI in a configurable Neovim terminal window.

## Setup

```lua
{
	dir = vim.fn.expand("~/Code/mini.codex"),
	name = "mini.codex",
	config = function()
		require("mini.codex").setup()
	end,
}
```

The default window configuration is:

```lua
{
	vertical = true,
	width = math.floor(vim.o.columns * 0.4),
	win = 0,
	split = "right",
}
```

Customize it only when needed by passing a `win` table to `setup()`. It is passed directly to `nvim_open_win()`, so it can also define a floating window.

```lua
require("mini.codex").setup({
	win = {
		relative = "editor",
		width = 80,
		height = 30,
		row = 2,
		col = 4,
		style = "minimal",
		border = "rounded",
	},
})
```

## Commands

```vim
:Codex
:Codex new
:Codex last
:Codex pick
:Codex prev
:Codex next
:Codex stop
```

Session navigation reads Codex's local `$CODEX_HOME/state_5.sqlite` database, falling back to `~/.codex/state_5.sqlite`.
