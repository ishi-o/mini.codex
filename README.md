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

The window label is automatically `Codex [session-id]`.

## Input pane

Codex's built-in Vim mode is too limited for full Neovim editing workflows, so mini.codex offers an optional input pane backed by a real normal buffer. It is not loaded or opened by default. Enable it with an `input` table; the pane is anchored to the bottom half of the Codex window and follows it wherever it is placed.

The buffer uses the `markdown.codex` filetype, allowing [nvim-codex-lsp](https://github.com/ishi-o/nvim-codex-lsp) to attach automatically and provide completions.

- `Enter` behaves normally, so it inserts a newline in insert mode and never submits to Codex.
- The sync key (default `<C-g>`) opens the mapping input with Codex's complete current draft. Press it again to replace Codex's draft with the edited text and return to the terminal.

Synchronization uses Codex's external-editor support inside the current Neovim instance. The plugin sets `VISUAL` only for the Codex process.

Configure it with the `input` table (or use `input = false` to disable an enabled pane):

```lua
require("mini.codex").setup({
	input = {
		prompt = "Codex input: ",
		height = 0.5, -- fraction of the Codex window height, or absolute rows (> 1)
		jump_key = "<C-g>", -- key that synchronizes and switches inputs
	},
})
```

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
