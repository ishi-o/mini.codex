# mini.codex

A small Neovim plugin for running and resuming the Codex CLI in a configurable Neovim terminal window.

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

```text
:Codex        # toggle codex window
:Codex toggle # toggle codex window
:Codex new    # new a codex session
:Codex last		# codex resume --last
:Codex pick		# pick a session
:Codex prev		# previous session, pick the last if there is no active session now
:Codex next		# next session
:Codex stop		# close current session
```

Session navigation reads Codex's local `$CODEX_HOME/state_5.sqlite` database, falling back to `~/.codex/state_5.sqlite`.
