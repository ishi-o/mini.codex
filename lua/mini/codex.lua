local M = {}

local T = {
  bufnr = nil,
  winid = nil,
  jobid = nil,
  type = nil,
  win_config = nil,
  current_session_idx = nil,
  token = nil,
  next_token = 0,
}

local win_config
local setup_done = false

local function codex_executable()
  local nvm = vim.env.NVM_BIN
  if nvm and nvm ~= "" then
    local path = vim.fs.joinpath(nvm, "codex")
    if vim.fn.executable(path) == 1 then
      return path
    end
  end
  local path = vim.fn.exepath("codex")
  if path ~= "" then
    return path
  end
  vim.notify("Codex executable not found", vim.log.levels.ERROR)
  return nil
end

local function session_list(cwd)
  local db =
    vim.fs.joinpath(vim.fn.expand((vim.env.CODEX_HOME ~= "" and vim.env.CODEX_HOME) or "~/.codex"), "state_5.sqlite")
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
  for line in output:gmatch("[^\n]+") do
    local id, title = line:match("^([^|]+)|(.*)$")
    if id and title then
      sessions[#sessions + 1] = { id = id, title = title }
    end
  end
  return sessions
end

local function open_terminal(config)
  local b = T.bufnr or vim.api.nvim_create_buf(false, true)
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
end

local function close_terminal()
  local b, w = T.bufnr, T.winid
  if w and vim.api.nvim_win_is_valid(w) then
    pcall(vim.api.nvim_win_close, w, true)
  end
  if b and vim.api.nvim_buf_is_valid(b) then
    pcall(vim.api.nvim_buf_delete, b, { force = true })
  end
  T.bufnr, T.winid, T.win_config = nil, nil, nil
end

local function clear()
  close_terminal()
  T.jobid, T.token, T.type, T.current_session_idx = nil, nil, nil, nil
end

local function new_token()
  T.next_token = T.next_token + 1
  T.token = T.next_token
  return T.token
end

local stop_codex
local start_job

start_job = function(executable, args, token, fallback)
  local id = vim.fn.jobstart(vim.list_extend({ executable }, args), {
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
        start_job(executable, fallback, token)
        return
      end
      clear()
    end,
  })
  if id <= 0 then
    if T.token == token then
      clear()
      vim.notify("Failed to start Codex (job id " .. id .. ")", vim.log.levels.ERROR)
    end
    return nil
  end
  if T.token ~= token then
    vim.fn.jobstop(id)
    return nil
  end
  T.jobid = id
  if T.bufnr and vim.api.nvim_buf_is_valid(T.bufnr) then
    vim.b[T.bufnr].terminal_job_id = id
  end
  return id
end

local function start_codex(mode)
  local list, step, session_idx
  if mode == "prev" or mode == "next" then
    list, step = session_list(vim.fn.getcwd()), ({ prev = 1, next = -1 })[mode]
    if #list == 0 then
      vim.notify("No sessions available", vim.log.levels.WARN)
      return
    end
    session_idx = T.current_session_idx and T.current_session_idx + step or 1
    if not list[session_idx] then
      vim.notify(mode == "prev" and "No previous session" or "No next session", vim.log.levels.INFO)
      return
    end
  end
  if T.bufnr and vim.api.nvim_buf_is_valid(T.bufnr) then
    if mode == "" then
      if T.winid and vim.api.nvim_win_is_valid(T.winid) then
        T.win_config = vim.api.nvim_win_get_config(T.winid)
        vim.api.nvim_win_hide(T.winid)
        T.winid = nil
      else
        open_terminal(T.win_config)
      end
      return
    elseif T.type ~= mode then
      stop_codex()
    elseif T.winid and vim.api.nvim_win_is_valid(T.winid) then
      T.win_config = vim.api.nvim_win_get_config(T.winid)
      vim.api.nvim_win_hide(T.winid)
      T.winid = nil
      return
    else
      open_terminal(T.win_config)
      return
    end
  elseif T.winid then
    close_terminal()
  end
  local executable = codex_executable()
  if not executable then
    return
  end
  local args, fallback = {}, nil
  if mode == "last" then
    T.current_session_idx, args, fallback = 1, { "resume", "--last" }, {}
  elseif step then
    T.current_session_idx, args = session_idx, { "resume", list[session_idx].id }
  else
    T.current_session_idx = nil
  end
  open_terminal()
  T.type = mode
  start_job(executable, args, new_token(), fallback)
end

local function pick_session()
  local list = session_list(vim.fn.getcwd())
  if #list == 0 then
    vim.notify("No sessions found", vim.log.levels.INFO)
    return
  end
  local selection_token, items = T.next_token, {}
  for i, s in ipairs(list) do
    items[i] = string.format("%d: %s", i, s.title)
  end
  vim.ui.select(items, { prompt = "Select Codex Session:" }, function(choice, idx)
    if not choice or T.next_token ~= selection_token then
      return
    end
    local executable = codex_executable()
    if not executable then
      return
    end
    stop_codex()
    open_terminal()
    T.type, T.current_session_idx = "pick", idx
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

function M.setup(opts)
  if opts then
    win_config = opts.win
  end
  if setup_done then
    return
  end
  setup_done = true
  vim.api.nvim_create_user_command("Codex", function(o)
    if o.args == "stop" then
      stop_codex()
    elseif o.args == "pick" then
      pick_session()
    else
      start_codex(o.args)
    end
  end, {
    nargs = "?",
    complete = function()
      return { "new", "last", "pick", "prev", "next", "stop" }
    end,
  })
end

return M
