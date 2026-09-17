local M = {}

---@alias mini.codex.Mode ""|"new"|"last"|"pick"|"prev"|"next"

local T = { next_token = 0 }
---@type mini.codex.Mode?
local current_mode

---@type mini.codex.Config
local DEFAULT_CONFIG = {
  win = {
    win = 0,
    split = "right",
    vertical = true,
    width = math.max(1, math.floor(vim.o.columns * 0.5)),
  },
  input = {
    enabled = false,
    pin = true,
    prompt = "",
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
    lsp = true,
    lsp_cmd = "codex-prompt-lsp",
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
      prev = "<M-p>",
      next = "<M-n>",
      detail = "<CR>",
    },
  },
}

local config = vim.deepcopy(DEFAULT_CONFIG)
local input, output
local storage = require("mini.codex.storage")
local setup_done = false

local function input_call(method, ...)
  return input and input[method](...)
end

local function output_call(method, ...)
  return output and output[method](...)
end

local function codex_executable()
  local path = vim.fn.exepath("codex")
  if path == "" then
    vim.notify("Codex executable not found", vim.log.levels.ERROR)
    return
  end
  return path
end

local function session_list(cwd)
  return storage.session_list(cwd)
end

local function configure_window()
  local name = T.session_id and ("Codex [" .. T.session_id .. "]") or "Codex"
  if T.bufnr then
    pcall(vim.api.nvim_buf_set_name, T.bufnr, name)
  end
  if T.winid then
    vim.wo[T.winid].winbar = name
  end
end

local function open_input()
  input_call("open", T.winid, function()
    return T.jobid
  end)
end

local function open_terminal(win_config)
  local b = T.bufnr
  if not b or not vim.api.nvim_buf_is_valid(b) then
    b = vim.api.nvim_create_buf(false, true)
  end
  T.bufnr = b
  vim.bo[b].bufhidden = "hide"
  T.winid = vim.api.nvim_open_win(b, true, win_config or config.win)
  configure_window()
end

local function close_terminal()
  input_call("close")
  output_call("close")
  if T.winid then
    pcall(vim.api.nvim_win_close, T.winid, true)
  end
  if T.bufnr then
    pcall(vim.api.nvim_buf_delete, T.bufnr, { force = true })
  end
  T.bufnr, T.winid, T.win_config = nil, nil, nil
end

local function wait_for_new_session(previous, cwd, token, attempt)
  attempt = attempt or 0
  if T.token ~= token or not T.jobid or attempt >= 100 then
    return
  end
  for _, session in ipairs(session_list(cwd)) do
    if not previous[session.id] then
      T.session_id = session.id
      configure_window()
      output_call("set_session", T.session_id, token)
      return
    end
  end
  vim.defer_fn(function()
    wait_for_new_session(previous, cwd, token, attempt + 1)
  end, 100)
end

local function clear()
  close_terminal()
  T.jobid, T.token, T.current_session_idx, T.session_id = nil, nil, nil, nil
  current_mode = nil
end

local function new_token()
  T.next_token, T.token = T.next_token + 1, T.next_token + 1
  return T.token
end

local function stop_codex()
  local id = T.jobid
  T.next_token, T.token, T.jobid = T.next_token + 1, nil, nil
  if id and id > 0 then
    vim.fn.jobstop(id)
  end
  clear()
end

local function start_job(executable, args, token, fallback)
  local id = vim.fn.jobstart(vim.list_extend({ executable }, args), {
    env = input_call("env", T.winid),
    pty = true,
    term = true,
    on_exit = function(job, code)
      if T.token ~= token or T.jobid ~= job then
        return
      end
      T.jobid = nil
      if fallback and code ~= 0 then
        close_terminal()
        open_terminal()
        return start_job(executable, fallback, token)
      end
      clear()
    end,
  })
  if id <= 0 or T.token ~= token then
    if T.token == token then
      clear()
      vim.notify("Failed to start Codex (job id " .. id .. ")", vim.log.levels.ERROR)
    elseif id > 0 then
      vim.fn.jobstop(id)
    end
    return
  end
  T.jobid = id
  vim.b[T.bufnr].terminal_job_id = id
  configure_window()
  output_call("attach", T.winid, T.session_id, token)
  open_input()
  return id
end

---@param mode mini.codex.Mode
local function start_codex(mode)
  local cwd = vim.fn.getcwd()
  local list, previous, step, session_idx
  step = ({ prev = 1, next = -1 })[mode]
  if step then
    list = session_list(cwd)
    session_idx = T.current_session_idx and T.current_session_idx + step or 1
    local message = #list == 0 and "No sessions available"
      or not list[session_idx] and (mode == "prev" and "No previous session" or "No next session")
    if message then
      vim.notify(message, #list == 0 and vim.log.levels.WARN or vim.log.levels.INFO)
      return
    end
  elseif mode == "" or mode == "new" then
    previous = {}
    for _, session in ipairs(session_list(cwd)) do
      previous[session.id] = true
    end
  end
  local active = T.bufnr and vim.api.nvim_buf_is_valid(T.bufnr)
  if active and step == nil and (mode == "" or current_mode == mode) then
    if T.winid and vim.api.nvim_win_is_valid(T.winid) then
      input_call("hide")
      output_call("hide")
      T.win_config = vim.api.nvim_win_get_config(T.winid)
      vim.api.nvim_win_hide(T.winid)
      T.winid = nil
    else
      open_terminal(T.win_config)
      open_input()
      output_call("attach", T.winid, T.session_id, T.token)
    end
    return
  elseif active then
    stop_codex()
  elseif T.winid then
    close_terminal()
  end
  local executable = codex_executable()
  if not executable then
    return
  end
  local args, fallback = {}, nil
  if mode == "last" then
    list = session_list(cwd)
    T.current_session_idx, T.session_id, args, fallback = 1, list[1] and list[1].id, { "resume", "--last" }, {}
  elseif step then
    T.current_session_idx, T.session_id, args = session_idx, list[session_idx].id, { "resume", list[session_idx].id }
  else
    T.current_session_idx, T.session_id = nil, nil
  end
  open_terminal()
  current_mode = mode
  local token = new_token()
  local jobid = start_job(executable, args, token, fallback)
  if jobid and previous then
    wait_for_new_session(previous, cwd, token)
  end
end

local function pick_session()
  local list = session_list(vim.fn.getcwd())
  if #list == 0 then
    vim.notify("No sessions found", vim.log.levels.INFO)
    return
  end
  local token, items = T.next_token, {}
  for i, s in ipairs(list) do
    items[i] = string.format("%d: %s", i, s.title)
  end
  vim.ui.select(items, { prompt = "Select Codex Session:" }, function(choice, idx)
    if not choice or T.next_token ~= token then
      return
    end
    local executable = codex_executable()
    if not executable then
      return
    end
    stop_codex()
    current_mode, T.current_session_idx, T.session_id = "pick", idx, list[idx].id
    open_terminal()
    start_job(executable, { "resume", list[idx].id }, new_token())
  end)
end

---@class mini.codex.Config
---@field win? vim.api.keyset.win_config
---@field input? mini.codex.InputConfig
---@field output? mini.codex.OutputConfig

---@param opts? mini.codex.Config
function M.setup(opts)
  opts = opts or {}
  config.win = opts.win or config.win
  if opts.input then
    local input_config = vim.tbl_deep_extend("force", config.input, opts.input)
    if opts.input.win then
      input_config.win = vim.deepcopy(opts.input.win)
    end
    config.input = input_config
    input_call("close")
    input = nil
    if config.input.enabled then
      input = require("mini.codex.input")
      input.setup(config.input)
    end
  end
  if opts.output then
    local output_config = vim.tbl_deep_extend("force", config.output, opts.output)
    if opts.output.win then
      output_config.win = vim.deepcopy(opts.output.win)
    end
    config.output = output_config
    output_call("close")
    output = nil
    if config.output.enabled then
      output = require("mini.codex.output")
      output.setup(config.output)
      if T.winid then
        output.attach(T.winid, T.session_id, T.token)
      end
    end
  end
  if setup_done then
    return
  end
  setup_done = true
  vim.api.nvim_create_user_command("Codex", function(o)
    if o.args == "stop" then
      return stop_codex()
    end
    if o.args == "pick" then
      return pick_session()
    end
    local mode = o.args == "toggle" and "" or o.args
    ---@cast mode mini.codex.Mode
    start_codex(mode)
  end, {
    nargs = "?",
    complete = function()
      return { "new", "last", "pick", "prev", "next", "stop", "toggle" }
    end,
  })
end

return M
