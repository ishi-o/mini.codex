local jobs, stops, notices = 0, 0, {}
local original = {
  codex_home = vim.env.CODEX_HOME,
  exepath = vim.fn.exepath,
  filereadable = vim.fn.filereadable,
  jobstart = vim.fn.jobstart,
  jobstop = vim.fn.jobstop,
  nvm_bin = vim.env.NVM_BIN,
  notify = vim.notify,
  system = vim.fn.system,
}

vim.env.CODEX_HOME = vim.fn.tempname()
vim.env.NVM_BIN = ""
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
assert(jobs == 1, "initial prev did not open the only session")

local win = vim.api.nvim_get_current_win()
vim.cmd("Codex next")
assert(jobs == 1 and stops == 0, "unavailable next changed the pane")
assert(vim.api.nvim_win_is_valid(win), "unavailable next closed the pane")
assert(notices[#notices] == "No next session", "missing next-session notification")

vim.cmd("Codex stop")
vim.cmd("Codex next")
assert(jobs == 2, "initial next did not open the only session")

vim.cmd("Codex stop")
vim.env.CODEX_HOME = original.codex_home
vim.env.NVM_BIN = original.nvm_bin
vim.fn.exepath = original.exepath
vim.fn.filereadable = original.filereadable
vim.fn.jobstart = original.jobstart
vim.fn.jobstop = original.jobstop
vim.notify = original.notify
vim.fn.system = original.system

print("codex test: ok")
