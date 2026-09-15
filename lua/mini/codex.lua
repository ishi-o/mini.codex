local M = {}

local T = { next_token = 0 }

local input
---@type vim.api.keyset.win_config?
local win_config
local setup_done = false

local function input_call(method, ...)
  return input and input[method](...)
end

local joinpath = vim.fs and vim.fs.joinpath or function(base, name)
  return base:gsub("[/\\]+$", "") .. "/" .. name
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
  local home = vim.env.CODEX_HOME
  local db = joinpath(vim.fn.expand(home and home ~= "" and home or "~/.codex"), "state_5.sqlite")
  if vim.fn.filereadable(db) ~= 1 then
    return {}
  end
  local sql = string.format(
    "SELECT id, title FROM threads WHERE cwd = '%s' AND archived = 0 ORDER BY created_at DESC LIMIT 20",
    cwd:gsub("'", "''")
  )
  local output = vim.fn.system({ "sqlite3", db, sql })
  if vim.v.shell_error ~= 0 or output == "" then
    return {}
  end
  local sessions = {}
  for id, title in output:gmatch("([^\n|]+)|([^\n]*)") do
    sessions[#sessions + 1] = { id = id, title = title }
  end
  return sessions
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

local function open_terminal(config)
  local b = T.bufnr
  if not b or not vim.api.nvim_buf_is_valid(b) then
    b = vim.api.nvim_create_buf(false, true)
  end
  T.bufnr = b
  vim.bo[b].bufhidden = "hide"
  config = config
    or win_config
    or {
      vertical = true,
      width = math.max(1, math.floor(vim.o.columns * 0.4)),
      win = 0,
      split = "right",
    }
  T.winid = vim.api.nvim_open_win(b, true, config)
  configure_window()
end

local function close_terminal()
  input_call("close")
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
      return
    end
  end
  vim.defer_fn(function()
    wait_for_new_session(previous, cwd, token, attempt + 1)
  end, 100)
end

local function clear()
  close_terminal()
  T.jobid, T.token, T.type, T.current_session_idx, T.session_id = nil, nil, nil, nil, nil
end

local function new_token()
  T.next_token, T.token = T.next_token + 1, T.next_token + 1
  return T.token
end

local stop_codex
local start_job

start_job = function(executable, args, token, fallback)
  local id = vim.fn.jobstart(vim.list_extend({ executable }, args), {
    env = input_call("env"),
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
  open_input()
  return id
end

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
  if active and (mode == "" or T.type == mode) then
    if T.winid and vim.api.nvim_win_is_valid(T.winid) then
      input_call("hide")
      T.win_config = vim.api.nvim_win_get_config(T.winid)
      vim.api.nvim_win_hide(T.winid)
      T.winid = nil
    else
      open_terminal(T.win_config)
      open_input()
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
  T.type = mode
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
    T.type, T.current_session_idx, T.session_id = "pick", idx, list[idx].id
    open_terminal()
    start_job(executable, { "resume", list[idx].id }, new_token())
  end)
end

stop_codex = function()
  local id = T.jobid
  T.next_token, T.token, T.jobid = T.next_token + 1, nil, nil
  if id and id > 0 then
    vim.fn.jobstop(id)
  end
  clear()
end

---@class MiniCodexConfig
---@field win? vim.api.keyset.win_config
---@field input? false|MiniCodexInputConfig

---@param opts? MiniCodexConfig
function M.setup(opts)
  opts = opts or {}
  win_config = opts.win or win_config
  if opts.input ~= nil then
    input_call("close")
    input = nil
    if opts.input ~= false and opts.input.enabled ~= false then
      input = require("mini.codex.input")
      input.setup(opts.input)
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
    start_codex(o.args == "toggle" and "" or o.args)
  end, {
    nargs = "?",
    complete = function()
      return { "new", "last", "pick", "prev", "next", "stop", "toggle" }
    end,
  })
end

return M
