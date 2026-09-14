local busted = require("plenary.busted")

---@diagnostic disable: undefined-global

local function eq(expected, actual)
  assert(expected == actual, string.format("expected %s, got %s", expected, actual))
end

busted.describe("mini.codex", function()
  local jobs, stops, notices
  local original

  busted.before_each(function()
    pcall(vim.cmd, "Codex stop")

    jobs, stops, notices = 0, 0, {}
    original = {
      codex_home = vim.env.CODEX_HOME,
      exepath = vim.fn.exepath,
      filereadable = vim.fn.filereadable,
      jobstart = vim.fn.jobstart,
      jobstop = vim.fn.jobstop,
      notify = vim.notify,
      system = vim.fn.system,
    }

    vim.env.CODEX_HOME = vim.fn.tempname()
    vim.fn.exepath = function(command)
      return command == "codex" and "/bin/codex" or original.exepath(command)
    end
    vim.fn.filereadable = function()
      return 1
    end
    vim.fn.jobstart = function()
      jobs = jobs + 1
      return jobs
    end
    vim.fn.jobstop = function()
      stops = stops + 1
    end
    vim.notify = function(message)
      notices[#notices + 1] = message
    end
    vim.fn.system = function()
      return "only|Only session\n"
    end
  end)

  busted.after_each(function()
    pcall(vim.cmd, "Codex stop")
    vim.env.CODEX_HOME = original.codex_home or ""
    vim.fn.exepath = original.exepath
    vim.fn.filereadable = original.filereadable
    vim.fn.jobstart = original.jobstart
    vim.fn.jobstop = original.jobstop
    vim.notify = original.notify
    vim.fn.system = original.system
  end)

  busted.it("loads the module", function()
    local ok, codex = pcall(require, "mini.codex")
    assert(ok, "mini.codex module failed to load")
    assert(codex.setup, "mini.codex.setup missing")
  end)

  busted.it("creates the Codex command", function()
    require("mini.codex").setup()

    local commands = vim.api.nvim_get_commands({})
    assert(commands.Codex, "Codex command not found")
  end)

  busted.it("supports Codex toggle", function()
    require("mini.codex").setup({
      win = {
        relative = "editor",
        width = 20,
        height = 5,
        row = 1,
        col = 1,
        style = "minimal",
      },
    })

    vim.cmd("Codex")
    eq(1, jobs)
    vim.cmd("Codex toggle")
    eq(1, jobs)
    vim.cmd("Codex toggle")
    eq(1, jobs)
  end)

  busted.it("opens the only session from initial prev and next", function()
    require("mini.codex").setup({
      win = {
        relative = "editor",
        width = 20,
        height = 5,
        row = 1,
        col = 1,
        style = "minimal",
      },
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
end)
