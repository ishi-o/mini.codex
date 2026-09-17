local busted = require("plenary.busted")

---@diagnostic disable: undefined-global

local function eq(expected, actual)
  assert(expected == actual, string.format("expected %s, got %s", expected, actual))
end

busted.describe("mini.codex", function()
  local jobs, stops, notices, temp_files, job_opts, lsp_config
  local original

  local function split_win()
    return { split = "right", width = 20 }
  end

  local function codex_win()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.wo[win].winbar:match("^Codex") then
        return win
      end
    end
  end

  local function open_editor(text)
    local path = vim.fn.tempname() .. ".md"
    temp_files[#temp_files + 1] = path
    vim.fn.writefile(vim.split(text, "\n", { plain = true }), path, "b")
    require("mini.codex.input")._editor_start(path)
    return path
  end

  busted.before_each(function()
    pcall(vim.cmd, "Codex stop")
    vim.o.swapfile = false

    jobs, stops, notices, temp_files, job_opts, lsp_config = 0, 0, {}, {}, nil, nil
    original = {
      codex_home = vim.env.CODEX_HOME,
      exepath = vim.fn.exepath,
      filereadable = vim.fn.filereadable,
      jobstart = vim.fn.jobstart,
      jobstop = vim.fn.jobstop,
      chansend = vim.fn.chansend,
      complete_info = vim.fn.complete_info,
      notify = vim.notify,
      pumvisible = vim.fn.pumvisible,
      serverstart = vim.fn.serverstart,
      system = vim.fn.system,
      lsp_start = vim.lsp.start,
      lsp_get_clients = vim.lsp.get_clients,
      lsp_get_configs = vim.lsp.get_configs,
      nvim_codex_lsp = package.loaded["nvim-codex-lsp"],
    }

    vim.env.CODEX_HOME = vim.fn.tempname()
    vim.fn.exepath = function(command)
      return command == "codex" and "/bin/codex" or original.exepath(command)
    end
    vim.fn.filereadable = function()
      return 1
    end
    vim.fn.jobstart = function(_, opts)
      jobs = jobs + 1
      job_opts = opts
      vim.api.nvim_buf_set_name(vim.api.nvim_get_current_buf(), "term://codex//codex")
      return jobs
    end
    vim.fn.jobstop = function()
      stops = stops + 1
    end
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    vim.fn.serverstart = function()
      return "/tmp/mini-codex-test.sock"
    end
    vim.fn.system = function()
      return '[{"id":"only","title":"Only | session"}]'
    end
  end)

  busted.after_each(function()
    pcall(vim.cmd, "Codex stop")
    require("mini.codex").setup({
      input = {
        enabled = false,
        pin = true,
        lsp = true,
        lsp_cmd = "codex-prompt-lsp",
        win = {
          win = 0,
          split = "below",
          height = math.max(1, math.floor(vim.o.lines * 0.3)),
        },
        keymap = {
          jump = "<C-g>",
          prev = "<M-p>",
          next = "<M-n>",
        },
      },
      output = {
        enabled = false,
        win = {
          win = 0,
          split = "right",
          vertical = true,
        },
        keymap = {
          toggle = "<C-t>",
          refresh = "<C-r>",
        },
      },
    })
    vim.env.CODEX_HOME = original.codex_home or ""
    vim.fn.exepath = original.exepath
    vim.fn.filereadable = original.filereadable
    vim.fn.jobstart = original.jobstart
    vim.fn.jobstop = original.jobstop
    vim.fn.chansend = original.chansend
    vim.fn.complete_info = original.complete_info
    vim.notify = original.notify
    vim.fn.pumvisible = original.pumvisible
    vim.fn.serverstart = original.serverstart
    vim.fn.system = original.system
    vim.lsp.start = original.lsp_start
    vim.lsp.get_clients = original.lsp_get_clients
    vim.lsp.get_configs = original.lsp_get_configs
    package.loaded["nvim-codex-lsp"] = original.nvim_codex_lsp
    for _, path in ipairs(temp_files) do
      vim.fn.delete(path)
    end
  end)

  busted.it("loads the module", function()
    local ok, codex = pcall(require, "mini.codex")
    assert(ok, "mini.codex module failed to load")
    assert(codex.setup, "mini.codex.setup missing")
    assert(not package.loaded["mini.codex.input"], "optional input module loaded eagerly")
    assert(not package.loaded["mini.codex.output"], "optional output module loaded eagerly")
  end)

  busted.it("creates the Codex command", function()
    require("mini.codex").setup()

    local commands = vim.api.nvim_get_commands({})
    assert(commands.Codex, "Codex command not found")
  end)

  busted.it("supports Codex toggle", function()
    require("mini.codex").setup({
      win = split_win(),
    })

    vim.cmd("Codex")
    eq(1, jobs)
    vim.cmd("Codex toggle")
    eq(1, jobs)
    vim.cmd("Codex toggle")
    eq(1, jobs)
  end)

  busted.it("uses the session id in the window name", function()
    local queries = 0
    vim.fn.system = function()
      queries = queries + 1
      return queries == 1 and '[{"id":"old","title":"Old session"}]' or '[{"id":"new","title":"New session"}]'
    end

    require("mini.codex").setup({
      input = { enabled = true, prompt = "Input: " },
      win = split_win(),
    })

    vim.cmd("Codex")
    local input_win = vim.api.nvim_get_current_win()
    local main_win
    vim.wait(500, function()
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.wo[win].winbar == "Codex [new]" then
          main_win = win
          return true
        end
      end
      return false
    end, 10)
    local buf = vim.api.nvim_win_get_buf(main_win)
    local input_buf = vim.api.nvim_win_get_buf(input_win)
    eq("Codex [new]", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t"))
    eq("", vim.bo[input_buf].buftype)
    eq("markdown.codex", vim.bo[input_buf].filetype)
    eq("mini-codex://input", vim.api.nvim_buf_get_name(input_buf))
  end)

  busted.it("uses the native input split configuration", function()
    require("mini.codex").setup({
      input = {
        enabled = true,
        win = {
          split = "below",
          height = 4,
          win = 0,
        },
      },
      win = split_win(),
    })

    vim.cmd("Codex")
    eq(1, jobs)

    local input_win = vim.api.nvim_get_current_win()
    local input_buf = vim.api.nvim_win_get_buf(input_win)
    eq("", vim.bo[input_buf].buftype)
    eq("markdown.codex", vim.bo[input_buf].filetype)

    local main_win = codex_win()
    local main_height = vim.api.nvim_win_get_height(main_win)
    local input_height = vim.api.nvim_win_get_height(input_win)
    local total_height = main_height + input_height + 1
    eq(4, input_height)
    eq(vim.api.nvim_win_get_width(main_win), vim.api.nvim_win_get_width(input_win))
    eq(vim.api.nvim_win_get_position(main_win)[1] + main_height + 1, vim.api.nvim_win_get_position(input_win)[1])

    vim.api.nvim_win_set_height(input_win, input_height + 1)
    eq(total_height, vim.api.nvim_win_get_height(main_win) + vim.api.nvim_win_get_height(input_win) + 1)
  end)

  busted.it("can attach the standalone prompt LSP server", function()
    vim.fn.exepath = function(command)
      return command == "codex" and "/bin/codex"
        or command == "codex-prompt-lsp" and "/bin/codex-prompt-lsp"
        or original.exepath(command)
    end
    vim.lsp.get_configs = function()
      return {}
    end
    vim.lsp.get_clients = function()
      return {}
    end
    vim.lsp.start = function(config)
      lsp_config = config
    end

    require("mini.codex").setup({
      input = { enabled = true, lsp = true },
      win = split_win(),
    })

    vim.cmd("Codex")
    eq("codex-prompt", lsp_config.name)
    eq("/bin/codex-prompt-lsp", lsp_config.cmd[1])
    eq("--stdio", lsp_config.cmd[2])
    eq(vim.fn.getcwd(), lsp_config.root_dir)
    eq(vim.api.nvim_get_current_buf(), lsp_config.bufnr)
  end)

  busted.it("defers to the Neovim adapter when it is installed", function()
    package.loaded["nvim-codex-lsp"] = {}
    vim.fn.exepath = function(command)
      return command == "codex" and "/bin/codex"
        or command == "codex-prompt-lsp" and "/bin/codex-prompt-lsp"
        or original.exepath(command)
    end
    vim.lsp.get_clients = function()
      return {}
    end
    vim.lsp.start = function(config)
      lsp_config = config
    end

    require("mini.codex").setup({
      input = { enabled = true, lsp = true },
      win = split_win(),
    })

    vim.cmd("Codex")
    assert(not lsp_config, "standalone server should defer to the Neovim adapter")
  end)

  busted.it("uses the native input floating configuration", function()
    require("mini.codex").setup({
      input = {
        enabled = true,
        win = {
          relative = "editor",
          row = 15,
          col = 4,
          width = 30,
          height = 4,
          style = "minimal",
          border = "rounded",
        },
      },
      win = {
        relative = "editor",
        row = 2,
        col = 4,
        width = 30,
        height = 12,
        border = "rounded",
      },
    })

    vim.cmd("Codex")
    local input_win = vim.api.nvim_get_current_win()
    local main_win = codex_win()
    local input_config = vim.api.nvim_win_get_config(input_win)
    eq("editor", input_config.relative)
    eq(15, input_config.row)
    eq(4, input_config.col)
    eq(30, input_config.width)
    eq(4, vim.api.nvim_win_get_height(input_win))
    eq("minimal", input_config.style)
    eq(12, vim.api.nvim_win_get_height(main_win))

    vim.cmd("Codex toggle")
    vim.cmd("Codex toggle")
    eq(12, vim.api.nvim_win_get_height(codex_win()))
    eq(4, vim.api.nvim_win_get_height(vim.api.nvim_get_current_win()))
  end)

  busted.it("adapts the default input to a floating Codex window", function()
    require("mini.codex").setup({
      input = { enabled = true },
      win = {
        relative = "editor",
        row = 2,
        col = 4,
        width = 30,
        height = 12,
        border = "rounded",
      },
    })

    vim.cmd("Codex")
    local input_win = vim.api.nvim_get_current_win()
    local main_win = codex_win()
    local input_config = vim.api.nvim_win_get_config(input_win)
    eq("win", input_config.relative)
    eq(main_win, input_config.win)
    eq(vim.api.nvim_win_get_height(main_win) + 2, input_config.row)
    eq(vim.api.nvim_win_get_width(main_win), input_config.width)
    eq(math.max(1, math.floor(vim.o.lines * 0.3)), input_config.height)

    vim.api.nvim_win_set_height(main_win, 10)
    vim.cmd("doautocmd WinResized")
    eq(12, vim.api.nvim_win_get_config(input_win).row)
  end)

  busted.it("fully replaces the terminal input from the mapping input", function()
    local sent = {}
    vim.fn.chansend = function(job, data)
      sent[#sent + 1] = { job, data }
    end

    require("mini.codex").setup({
      input = { enabled = true },
      win = split_win(),
    })

    vim.cmd("Codex")
    local input_win = vim.api.nvim_get_current_win()
    assert(not job_opts.env.VISUAL:find("remote%-wait"), "input editor must not use an unsupported wait command")
    local input_buf = vim.api.nvim_win_get_buf(input_win)
    local main_win = codex_win()
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "hello", "world" })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-g>", true, false, true), "mx", false)
    eq("\7", sent[1][2])

    local path = open_editor("old terminal input")
    vim.wait(500, function()
      return vim.api.nvim_get_current_win() == main_win
    end, 10)
    eq("hello\nworld", table.concat(vim.fn.readfile(path, "b"), "\n"))
    eq("hello\nworld", table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n"))
    eq(main_win, vim.api.nvim_get_current_win())
  end)

  busted.it("hides and restores the input window on toggle", function()
    require("mini.codex").setup({
      input = { enabled = true },
      win = split_win(),
    })

    vim.cmd("Codex")
    local input_win = vim.api.nvim_get_current_win()
    assert(vim.api.nvim_win_is_valid(input_win), "input window not opened")

    vim.cmd("Codex toggle")
    assert(not vim.api.nvim_win_is_valid(input_win), "input window not hidden")

    vim.cmd("Codex toggle")
    local restored = false
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "markdown.codex" then
        restored = true
      end
    end
    assert(restored, "input window not restored")
  end)

  busted.it("does not leave an unsaved input buffer", function()
    require("mini.codex").setup({
      input = { enabled = true },
      win = split_win(),
    })

    vim.cmd("Codex")
    local input_win = vim.api.nvim_get_current_win()
    local input_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "draft" })
    local ok = pcall(vim.cmd, "q")
    assert(ok, "input buffer should accept :q without !")
    assert(not vim.api.nvim_win_is_valid(input_win), "input window should close")
    assert(not vim.bo[input_buf].modified, "hidden input buffer should not block editor quit")
  end)

  busted.it("keeps the input optional", function()
    require("mini.codex").setup({
      input = {},
      win = split_win(),
    })

    vim.cmd("Codex")
    eq(1, jobs)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local filetype = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
      assert(filetype ~= "markdown.codex", "optional input window opened by default")
    end

    vim.cmd("Codex stop")
    require("mini.codex").setup({ input = { enabled = false } })
    vim.cmd("Codex")
    eq(2, jobs)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local filetype = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
      assert(filetype ~= "markdown.codex", "input window found while input.enabled is false")
    end
  end)

  busted.it("uses the configured input window height", function()
    require("mini.codex").setup({
      input = {
        enabled = true,
        win = {
          split = "below",
          height = 3,
          win = 0,
        },
      },
      win = split_win(),
    })

    vim.cmd("Codex")
    eq(3, vim.api.nvim_win_get_height(vim.api.nvim_get_current_win()))
  end)

  busted.it("only shows an unpinned input while it is focused", function()
    local sent = {}
    vim.fn.chansend = function(job, data)
      sent[#sent + 1] = { job, data }
    end

    require("mini.codex").setup({
      input = { enabled = true, pin = false },
      win = split_win(),
    })

    vim.cmd("Codex")
    local main_win = codex_win()
    eq(main_win, vim.api.nvim_get_current_win())
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      assert(vim.bo[vim.api.nvim_win_get_buf(win)].filetype ~= "markdown.codex", "unpinned input opened eagerly")
    end

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-g>", true, false, true), "mx", false)
    eq("\7", sent[1][2])
    local path = open_editor("terminal draft")
    vim.wait(500, function()
      return vim.bo[vim.api.nvim_get_current_buf()].filetype == "markdown.codex"
    end, 10)
    local input_win = vim.api.nvim_get_current_win()
    assert(input_win ~= main_win, "unpinned input did not receive focus")

    vim.api.nvim_set_current_win(main_win)
    vim.wait(500, function()
      return not vim.api.nvim_win_is_valid(input_win)
    end, 10)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-g>", true, false, true), "mx", false)
    eq(1, #sent)
    input_win = vim.api.nvim_get_current_win()
    assert(input_win ~= main_win, "unpinned input did not regain focus")

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-g>", true, false, true), "mx", false)
    eq(main_win, vim.api.nvim_get_current_win())
    assert(not vim.api.nvim_win_is_valid(input_win), "unpinned input remained visible without focus")
    assert(require("mini.codex.input")._editor_done(path), "editor helper should be released")
  end)

  busted.it("copies the terminal input into the mapping input", function()
    local sent = {}
    vim.fn.chansend = function(job, data)
      sent[#sent + 1] = { job, data }
    end

    require("mini.codex").setup({
      input = { enabled = true },
      win = split_win(),
    })

    vim.cmd("Codex")
    local input_win = vim.api.nvim_get_current_win()
    local input_buf = vim.api.nvim_win_get_buf(input_win)
    local main_win = codex_win()

    vim.api.nvim_set_current_win(main_win)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-g>", true, false, true), "mx", false)
    eq(1, sent[1][1])
    eq("\7", sent[1][2])

    local path = open_editor("current terminal input")
    vim.wait(500, function()
      return vim.api.nvim_get_current_win() == input_win
    end, 10)
    eq(input_win, vim.api.nvim_get_current_win())
    eq("current terminal input", table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n"))

    vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "edited" })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-g>", true, false, true), "mx", false)
    eq(main_win, vim.api.nvim_get_current_win())
    assert(require("mini.codex.input")._editor_done(path), "editor helper should be released")
    eq("edited", table.concat(vim.fn.readfile(path, "b"), "\n"))
  end)

  busted.it("copies Codex history into the mapping input", function()
    local sent = {}
    vim.fn.chansend = function(job, data)
      sent[#sent + 1] = { job, data }
    end

    require("mini.codex").setup({
      input = {
        enabled = true,
        keymap = { prev = "<F5>", next = "<F6>" },
      },
      win = split_win(),
    })

    vim.cmd("Codex")
    local input_win = vim.api.nvim_get_current_win()
    local input_buf = vim.api.nvim_win_get_buf(input_win)

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<F5>", true, false, true), "mx", false)
    eq("\27[A", sent[1][2])
    eq("\7", sent[2][2])

    local path = open_editor("last confirmed input")
    vim.wait(500, function()
      return vim.api.nvim_get_current_win() == input_win
    end, 10)
    eq("last confirmed input", vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1])

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<F5>", true, false, true), "mx", false)
    eq(2, #sent)
    assert(require("mini.codex.input")._editor_done(path), "first history editor should be released")
    vim.wait(500, function()
      return #sent == 4
    end, 10)
    eq("\27[A", sent[3][2])
    eq("\7", sent[4][2])

    path = open_editor("older confirmed input")
    vim.wait(500, function()
      return vim.api.nvim_get_current_win() == input_win
    end, 10)
    eq("older confirmed input", vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1])

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<F5>", true, false, true), "mx", false)
    eq(4, #sent)
    assert(require("mini.codex.input")._editor_done(path), "second history editor should be released")
    vim.wait(500, function()
      return #sent == 6
    end, 10)
    eq("\27[A", sent[5][2])
    eq("\7", sent[6][2])

    path = open_editor("oldest confirmed input")
    vim.wait(500, function()
      return vim.api.nvim_get_current_win() == input_win
    end, 10)
    eq("oldest confirmed input", vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1])

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<F6>", true, false, true), "mx", false)
    eq(6, #sent)
    assert(require("mini.codex.input")._editor_done(path), "third history editor should be released")
    vim.wait(500, function()
      return #sent == 8
    end, 10)
    eq("\27[B", sent[7][2])
    eq("\7", sent[8][2])

    path = open_editor("older confirmed input")
    vim.wait(500, function()
      return vim.api.nvim_get_current_win() == input_win
    end, 10)
    eq("older confirmed input", vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1])

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<F6>", true, false, true), "mx", false)
    eq(8, #sent)
    assert(require("mini.codex.input")._editor_done(path), "fourth history editor should be released")
    vim.wait(500, function()
      return #sent == 10
    end, 10)
    eq("\27[B", sent[9][2])
    eq("\7", sent[10][2])

    path = open_editor("last confirmed input")
    vim.wait(500, function()
      return vim.api.nvim_get_current_win() == input_win
    end, 10)
    eq("last confirmed input", vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1])
    require("mini.codex.input")._apply()
    assert(require("mini.codex.input")._editor_done(path), "history editor helper should be released")
  end)

  busted.it("uses Enter only to edit the mapping input", function()
    local sent
    vim.fn.chansend = function(job, data)
      sent = { job, data }
    end

    require("mini.codex").setup({
      input = { enabled = true },
      win = split_win(),
    })

    vim.cmd("Codex")
    local input_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("Ahello<CR>world<Esc>", true, false, true), "mx", false)
    assert(not sent, "Enter should not write to the terminal")
    eq("hello\nworld", table.concat(vim.api.nvim_buf_get_lines(input_buf, 0, -1, false), "\n"))
  end)

  busted.it("keeps synchronization working while completion is active", function()
    local sent = {}
    vim.fn.chansend = function(job, data)
      sent[#sent + 1] = { job, data }
    end

    require("mini.codex").setup({
      input = { enabled = true },
      win = split_win(),
    })

    vim.cmd("Codex")
    local input_win = vim.api.nvim_get_current_win()
    local main_win = codex_win()
    vim.fn.pumvisible = function()
      return 0
    end
    vim.fn.complete_info = function()
      return { mode = "keyword" }
    end

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("ihel<C-g>", true, false, true), "mx", false)
    vim.wait(500, function()
      return #sent == 1
    end, 10)
    eq("\7", sent[1][2])
    eq("hel", table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(input_win), 0, -1, false), "\n"))

    open_editor("old input")
    vim.wait(500, function()
      return vim.api.nvim_get_current_win() == main_win
    end, 10)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-g>", true, false, true), "mx", false)
    eq(2, #sent)
    eq("\7", sent[2][2])
  end)

  busted.it("previews the Codex response history", function()
    local rollout = vim.fn.tempname() .. ".jsonl"
    temp_files[#temp_files + 1] = rollout
    vim.fn.writefile({
      vim.json.encode({
        type = "response_item",
        payload = {
          type = "message",
          role = "user",
          content = { { type = "input_text", text = "old question" } },
        },
      }),
      vim.json.encode({
        type = "response_item",
        payload = {
          type = "message",
          role = "assistant",
          content = { { type = "output_text", text = "old answer" } },
        },
      }),
      vim.json.encode({
        type = "event_msg",
        payload = {
          type = "item_completed",
          turn_id = "turn-2",
          item = {
            type = "user_message",
            content = { { type = "input_text", text = "latest question" } },
          },
        },
      }),
      vim.json.encode({
        type = "event_msg",
        payload = {
          type = "item_completed",
          turn_id = "turn-2",
          item = {
            type = "agent_message",
            content = { { type = "output_text", text = "# latest\n\nvalue | preserved" } },
          },
        },
      }),
    }, rollout, "b")
    vim.fn.system = function(args)
      if args[#args]:find("rollout_path", 1, true) then
        return vim.json.encode({ { rollout_path = rollout } })
      end
      return vim.json.encode({ { id = "only", title = "Only session" } })
    end

    require("mini.codex").setup({
      output = {
        enabled = true,
        win = {
          relative = "editor",
          row = 1,
          col = 2,
          width = 40,
          height = 8,
          style = "minimal",
          border = "rounded",
        },
      },
      win = split_win(),
    })

    vim.cmd("Codex prev")
    local main_win = codex_win()
    vim.api.nvim_set_current_win(main_win)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-t>", true, false, true), "mx", false)

    local output_buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
    local output_config = vim.api.nvim_win_get_config(vim.api.nvim_get_current_win())
    eq("editor", output_config.relative)
    eq(1, output_config.row)
    eq(2, output_config.col)
    eq(40, output_config.width)
    eq(8, output_config.height)
    eq("minimal", output_config.style)
    eq("Codex output · turn 2/2 · for latest question", vim.wo[vim.api.nvim_get_current_win()].winbar)
    eq("markdown", vim.bo[output_buf].filetype)
    eq(
      "## Turn 1 · for old question\n\nold answer\n\n---\n\n## Turn 2 · for latest question\n\n# latest\n\nvalue | preserved",
      table.concat(vim.api.nvim_buf_get_lines(output_buf, 0, -1, false), "\n")
    )

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-r>", true, false, true), "mx", false)
    eq(
      "## Turn 1 · for old question\n\nold answer\n\n---\n\n## Turn 2 · for latest question\n\n# latest\n\nvalue | preserved",
      table.concat(vim.api.nvim_buf_get_lines(output_buf, 0, -1, false), "\n")
    )
  end)

  busted.it("opens the default output beside the Codex window", function()
    require("mini.codex").setup({
      output = { enabled = true },
      win = split_win(),
    })

    vim.cmd("Codex")
    local main_win = codex_win()
    local main_width = vim.api.nvim_win_get_width(main_win)
    local main_height = vim.api.nvim_win_get_height(main_win)
    vim.api.nvim_set_current_win(main_win)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-t>", true, false, true), "mx", false)

    local output_config = vim.api.nvim_win_get_config(vim.api.nvim_get_current_win())
    eq("", output_config.relative)
    eq("right", output_config.split)
    eq(math.max(1, math.floor(main_width * 0.5)), output_config.width)
    eq(main_height, output_config.height)
  end)

  busted.it("does not block repeated editor requests", function()
    local sent = {}
    vim.fn.chansend = function(job, data)
      sent[#sent + 1] = { job, data }
    end

    require("mini.codex").setup({
      input = { enabled = true },
      win = split_win(),
    })

    vim.cmd("Codex")
    local input_win = vim.api.nvim_get_current_win()
    local main_win = codex_win()
    vim.api.nvim_set_current_win(main_win)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-g>", true, false, true), "mx", false)
    eq(1, #sent)
    eq("\7", sent[1][2])
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-g>", true, false, true), "mx", false)
    eq(2, #sent)
    eq("\7", sent[2][2])

    open_editor("$completion")
    vim.wait(500, function()
      return vim.api.nvim_get_current_win() == input_win
    end, 10)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-g>", true, false, true), "mx", false)
    eq(main_win, vim.api.nvim_get_current_win())
  end)

  busted.it("opens the only session from initial prev and next", function()
    require("mini.codex").setup({
      win = split_win(),
    })

    vim.cmd("Codex prev")
    eq(1, jobs)

    local win = vim.api.nvim_get_current_win()
    vim.cmd("Codex next")
    eq(1, jobs)
    eq(0, stops)
    assert(vim.api.nvim_win_is_valid(win), "unavailable next closed the pane")
    eq("No next session", notices[#notices])

    vim.cmd("Codex stop")
    vim.cmd("Codex next")
    eq(2, jobs)
  end)

  busted.it("navigates repeatedly through sessions", function()
    vim.fn.system = function()
      return '[{"id":"one","title":"One session"},{"id":"two","title":"Two session"},{"id":"three","title":"Three session"}]'
    end

    require("mini.codex").setup({
      win = split_win(),
    })

    vim.cmd("Codex prev")
    eq(1, jobs)
    eq("Codex [one]", vim.wo[codex_win()].winbar)

    vim.cmd("Codex prev")
    eq(2, jobs)
    eq(1, stops)
    eq("Codex [two]", vim.wo[codex_win()].winbar)

    vim.cmd("Codex prev")
    eq(3, jobs)
    eq(2, stops)
    eq("Codex [three]", vim.wo[codex_win()].winbar)

    vim.cmd("Codex next")
    eq(4, jobs)
    eq(3, stops)
    eq("Codex [two]", vim.wo[codex_win()].winbar)

    vim.cmd("Codex next")
    eq(5, jobs)
    eq(4, stops)
    eq("Codex [one]", vim.wo[codex_win()].winbar)
  end)
end)
