# mini.codex

A small Neovim plugin for running and resuming the Codex CLI in a configurable Neovim terminal window.

Requires Neovim 0.12 or later.

## Setup

<details>
<summary>lazy.nvim</summary>

```lua
{
	"ishi-o/mini.codex",
	config = function()
		require("mini.codex").setup()
	end,
}
```

</details>

<details>
<summary>vim.pack</summary>

```lua
vim.pack.add({
	{ src = "https://github.com/ishi-o/mini.codex" },
})

require("mini.codex").setup()
```

</details>

<details>
<summary>mini.deps</summary>

```lua
MiniDeps.add({ source = "https://github.com/ishi-o/mini.codex" })

require("mini.codex").setup()
```

</details>

The complete default configuration is:

```lua
---@type mini.codex.Config
local DEFAULT_CONFIG = {
	win = {
		vertical = true,
		width = math.max(1, math.floor(vim.o.columns * 0.4)),
		win = 0,
		split = "right",
	},
	input = {
		enabled = false,
		pin = true,
		prompt = "",
		height = 0.5,
		jump_key = "<C-g>",
		lsp = true,
		lsp_cmd = "codex-prompt-lsp",
	},
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

The buffer uses the `markdown.codex` filetype, allowing the [codex-prompt-lsp](https://github.com/ishi-o/codex-prompt-lsp) Neovim adapter to attach automatically and provide completions. The adapter is optional; mini.codex does not depend on it.

If you are migrating from `ishi-o/nvim-codex-lsp`, change the plugin source to
`ishi-o/codex-prompt-lsp`; the Neovim adapter's `require("nvim-codex-lsp")`
module name remains unchanged.

- `Enter` behaves normally, so it inserts a newline in insert mode and never submits to Codex.
- The sync key (default `<C-g>`) opens the mapping input with Codex's complete current draft. Press it again to replace Codex's draft with the edited text and return to the terminal.

Synchronization uses Codex's external-editor support inside the current Neovim instance. The plugin sets `VISUAL` only for the Codex process.

### Standalone LSP server (optional)

The input pane automatically attaches the editor-neutral
`codex-prompt-lsp --stdio` executable when it is available. Install
`codex-prompt-lsp` with npm or Mason; no additional configuration is needed:

```lua
---@type mini.codex.Config
local opts = {
	input = {
		enabled = true,
	},
}

require("mini.codex").setup(opts)
```

This standalone integration provides the server's completions and hover
information. It deliberately does not enable the Neovim adapter's mention
highlighting or atomic completion deletion. The `lsp` option defaults to
`true`, but has no effect when `nvim-codex-lsp` can be loaded: mini.codex
always leaves server startup to that adapter. The adapter provides the richer
integration, including Codex buffer detection, mention highlighting, and
atomic completion deletion. Set `lsp = false` to disable standalone startup,
or set `lsp_cmd` when the executable is not named `codex-prompt-lsp`.

Enable and configure it with the `input` table. Set `input.enabled = false` to disable it again:

```lua
---@type mini.codex.Config
local opts = {
	input = {
		enabled = true,
		pin = true, -- keep the input pane visible when it is not focused
		prompt = "",
		height = 0.5, -- fraction of the Codex window height, or absolute rows (> 1)
		jump_key = "<C-g>", -- key that synchronizes and switches inputs
		lsp = true, -- attach codex-prompt-lsp --stdio when available
		lsp_cmd = "codex-prompt-lsp",
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
