-- Optional Vim-style editor for Codex's terminal input.
local M = {}

---@alias mini.codex.EditorMode "edit"|"apply"
---@alias mini.codex.HistoryDirection "prev"|"next"

---@class mini.codex.InputKeymap
---@field jump string
---@field prev string
---@field next string

---@class mini.codex.InputConfig
---@field enabled? boolean
---@field pin? boolean
---@field prompt? string
---@field win? vim.api.keyset.win_config
---@field keymap? mini.codex.InputKeymap
---@field lsp? boolean
---@field lsp_cmd? string

---@class mini.codex.InputState
---@field pin boolean
---@field prompt string
---@field win vim.api.keyset.win_config
---@field keymap mini.codex.InputKeymap
---@field lsp boolean
---@field lsp_cmd string

---@type mini.codex.InputState
local defaults = {
  pin = true,
  prompt = "",
  win = {
    win = 0,
    split = "below",
  },
  keymap = {
    jump = "<C-g>",
    prev = "<M-p>",
    next = "<M-n>",
  },
  lsp = true,
  lsp_cmd = "codex-prompt-lsp",
}
local config = vim.deepcopy(defaults)
local namespace = vim.api.nvim_create_namespace("mini.codex.input")
local bufnr, winid, main_winid, get_jobid
---@type mini.codex.EditorMode?
local pending
---@type string?
local replacement
---@type string?
local editor_path
---@type mini.codex.HistoryDirection[]
local history_queue = {}
local history_active = false
local history_dispatch_scheduled = false
local closing_editor_path
local lsp_client_id
local adaptive_float = false
local syncing_float = false
local available = true
local default_height_ratio = 0.3
local saved_split_height
local buffer_option = vim.api.nvim_win_resize and "buf" or "buffer"

local function buffer_opts(buf, opts)
  opts[buffer_option] = buf
  return opts
end

local function default_height(main_config)
  return math.max(1, math.floor(main_config.height * default_height_ratio))
end

local function buffer_text()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return ""
  end
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

local function set_text(text)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(text, "\n", { plain = true }))
end

local function write_text(path, text)
  return vim.fn.writefile(vim.split(text, "\n", { plain = true }), path, "b") == 0
end

local function focus(win)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    vim.cmd("startinsert")
  end
end

local function show_prompt()
  vim.api.nvim_buf_set_extmark(bufnr, namespace, 0, 0, {
    id = 1,
    virt_text = { { config.prompt, "Comment" } },
    virt_text_pos = "inline",
    right_gravity = false,
  })
end

local function border_height(win_config)
  return win_config.border and win_config.border ~= "none" and 2 or 0
end

local function adaptive_float_config(opts, main_config)
  local row_offset = opts.relative == "win" and opts.row or 0
  opts.relative = "win"
  if not opts.win or opts.win == 0 then
    opts.win = main_winid
  end
  opts.row = main_config.height + border_height(main_config) + (row_offset or 0)
  opts.col = opts.col or 0
  opts.width = opts.width or main_config.width
  opts.height = opts.height or default_height(main_config)
  opts.split, opts.vertical = nil, nil
  return opts
end

local function sync_float()
  if
    not adaptive_float
    or syncing_float
    or not main_winid
    or not winid
    or not vim.api.nvim_win_is_valid(main_winid)
    or not vim.api.nvim_win_is_valid(winid)
  then
    return
  end
  syncing_float = true
  local main_config = vim.api.nvim_win_get_config(main_winid)
  local opts = adaptive_float_config(vim.deepcopy(config.win or {}), main_config)
  vim.api.nvim_win_set_config(winid, {
    relative = opts.relative,
    win = opts.win,
    row = opts.row,
    col = opts.col,
    width = opts.width,
    height = opts.height,
  })
  syncing_float = false
end

local function show_input()
  if winid and vim.api.nvim_win_is_valid(winid) then
    return winid
  end
  local opts = vim.deepcopy(config.win or {})
  local main_config = vim.api.nvim_win_get_config(main_winid)
  local normal_split = main_config.relative == "" and (opts.relative == nil or opts.relative == "")
  opts.height = (normal_split and saved_split_height) or opts.height or default_height(main_config)
  adaptive_float = false
  if opts.relative == "win" or (main_config.relative ~= "" and (opts.relative == nil or opts.relative == "")) then
    opts = adaptive_float_config(opts, main_config)
    adaptive_float = true
  elseif opts.relative == nil or opts.relative == "" then
    if not opts.win or opts.win == 0 then
      opts.win = main_winid
    end
  end
  winid = vim.api.nvim_open_win(bufnr, true, opts)
  return winid
end

function M.hide()
  if winid and vim.api.nvim_win_is_valid(winid) then
    if vim.api.nvim_win_get_config(winid).relative == "" then
      saved_split_height = vim.api.nvim_win_get_height(winid)
    end
    vim.api.nvim_win_hide(winid)
  end
  winid = nil
  adaptive_float = false
end

function M.window()
  return winid and vim.api.nvim_win_is_valid(winid) and winid or nil
end

---@param mode mini.codex.EditorMode
local function request_editor(mode, key)
  if mode == "edit" and editor_path then
    show_input()
    focus(winid)
    return
  end
  local jobid = get_jobid and get_jobid()
  if not jobid or not main_winid then
    return
  end
  pending, replacement = mode, mode == "apply" and buffer_text() or nil
  vim.api.nvim_set_current_win(main_winid)
  if key then
    vim.api.nvim_chan_send(jobid, key)
  end
  vim.api.nvim_chan_send(jobid, "\7")
end

local function apply()
  if not editor_path then
    return request_editor("apply")
  end
  closing_editor_path = editor_path
  write_text(editor_path, buffer_text())
  editor_path = nil
  if not config.pin then
    M.hide()
  end
  focus(main_winid)
end

local history_terminal_keys = {
  prev = "\27[A",
  next = "\27[B",
}

local function dispatch_history()
  if history_active or editor_path or #history_queue == 0 then
    return
  end
  local direction = table.remove(history_queue, 1)
  history_active = true
  request_editor("edit", history_terminal_keys[direction])
end

local function schedule_history()
  if history_dispatch_scheduled then
    return
  end
  history_dispatch_scheduled = true
  vim.defer_fn(function()
    history_dispatch_scheduled = false
    dispatch_history()
  end, 50)
end

local function cancel_completion()
  local completion = vim.fn.complete_info()
  return (vim.fn.pumvisible() == 1 or completion.mode ~= "") and "<C-e>" or ""
end

---@param direction mini.codex.HistoryDirection
local function request_history(direction)
  history_queue[#history_queue + 1] = direction
  if editor_path then
    history_active = true
    apply()
    return
  end
  dispatch_history()
end

local function apply_mapping()
  return cancel_completion() .. "<Esc><Cmd>lua require('mini.codex.input')._apply()<CR>"
end

M._apply = apply
M._history = request_history

---@param opts? mini.codex.InputConfig
function M.setup(opts)
  opts = opts or {}
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts) --[[@as mini.codex.InputState]]
  if opts.win then
    config.win = vim.deepcopy(opts.win)
  end
  available = true
end

local function start_lsp(buf)
  if not config.lsp or not vim.lsp or not vim.lsp.start then
    return
  end
  if pcall(require, "nvim-codex-lsp") then
    return
  end
  local executable = vim.fn.exepath(config.lsp_cmd)
  if executable == "" then
    return
  end
  if vim.lsp.get_configs and vim.lsp.get_configs()["codex-prompt"] then
    return
  end
  if #vim.lsp.get_clients({ bufnr = buf, name = "codex-prompt" }) > 0 then
    return
  end
  lsp_client_id = vim.lsp.start({
    name = "codex-prompt",
    cmd = { executable, "--stdio" },
    root_dir = vim.fn.getcwd(),
    bufnr = buf,
  })
end

---@param main_win integer
function M.env(main_win)
  local server = vim.v.servername
  if server == "" then
    local ok
    ok, server = pcall(vim.fn.serverstart, vim.fn.tempname())
    if not ok then
      available = false
      vim.notify("mini.codex input requires a Neovim RPC server", vim.log.levels.ERROR)
      return
    end
  end

  local helper = table.concat({
    "local c=vim.fn.sockconnect('pipe',vim.env.MINI_CODEX_SERVER,{rpc=true})",
    "local p=vim.v.argv[#vim.v.argv]",
    "if c<=0 then vim.cmd('cquit 2') end",
    "local ok,done=pcall(vim.rpcrequest,c,'nvim_exec_lua',\"return require('mini.codex.input')._editor_start(...)\",{p})",
    "while ok and not done do vim.wait(50); ok,done=pcall(vim.rpcrequest,c,'nvim_exec_lua',\"return require('mini.codex.input')._editor_done(...)\",{p}) end",
    "vim.cmd(ok and 'qa' or 'cquit 2')",
  }, ";")
  local command = string.format(
    "%s --headless -u NONE --cmd %s",
    vim.fn.shellescape(vim.v.progpath),
    vim.fn.shellescape("lua " .. helper)
  )
  return { VISUAL = command, MINI_CODEX_SERVER = server }
end

function M._editor_start(path)
  if not pending then
    return true
  end
  ---@type mini.codex.EditorMode
  local mode = pending
  local text = replacement
  pending, replacement = nil, nil
  if mode == "apply" then
    write_text(path, text or "")
    vim.schedule(function()
      if not config.pin then
        M.hide()
      end
      focus(main_winid)
    end)
    return true
  end
  editor_path = path
  set_text(table.concat(vim.fn.readfile(path, "b"), "\n"))
  show_prompt()
  show_input()
  vim.schedule_wrap(focus)(winid)
  return false
end

function M._editor_done(path)
  local done = editor_path ~= path
  if done and closing_editor_path == path then
    closing_editor_path = nil
    if history_active then
      history_active = false
      schedule_history()
    end
  end
  return done
end

---@param main_win integer
---@param jobid_fn? fun(): integer?
---@return integer?
function M.open(main_win, jobid_fn)
  if not available or not main_win or not vim.api.nvim_win_is_valid(main_win) then
    return
  end
  main_winid, get_jobid = main_win, jobid_fn or get_jobid
  if winid and vim.api.nvim_win_is_valid(winid) then
    return winid
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    bufnr = vim.api.nvim_create_buf(false, false)
    vim.bo[bufnr].bufhidden, vim.bo[bufnr].swapfile = "hide", false
    vim.api.nvim_buf_set_name(bufnr, "mini-codex://input")
    vim.api.nvim_buf_attach(bufnr, false, {
      on_lines = function(_, buf)
        vim.bo[buf].modified = false
      end,
    })
    vim.bo[bufnr].filetype = "markdown.codex"
    start_lsp(bufnr)
    vim.api.nvim_create_autocmd("WinLeave", {
      [buffer_option] = bufnr,
      callback = function()
        local leaving = vim.api.nvim_get_current_win()
        vim.schedule(function()
          if not config.pin and winid == leaving and vim.api.nvim_get_current_win() ~= leaving then
            M.hide()
          end
        end)
      end,
    })
  end
  show_prompt()

  local key = config.keymap.jump
  if type(key) == "string" and key ~= "" then
    local opts = buffer_opts(bufnr, { silent = true })
    vim.keymap.set({ "n", "t" }, key, function()
      request_editor("edit")
    end, buffer_opts(vim.api.nvim_win_get_buf(main_win), { silent = true }))
    vim.keymap.set("n", key, apply, opts)
    vim.keymap.set("i", key, apply_mapping, vim.tbl_extend("force", opts, { expr = true }))
  end

  local history_keys = { prev = config.keymap.prev, next = config.keymap.next }
  for direction, history_key in pairs(history_keys) do
    if type(history_key) == "string" and history_key ~= "" then
      local history_opts = buffer_opts(bufnr, { silent = true })
      vim.keymap.set("n", history_key, function()
        request_history(direction)
      end, history_opts)
      vim.keymap.set("i", history_key, function()
        return cancel_completion() .. "<Esc><Cmd>lua require('mini.codex.input')._history('" .. direction .. "')<CR>"
      end, vim.tbl_extend("force", history_opts, { expr = true }))
    end
  end

  return config.pin and show_input() or nil
end

function M.close()
  M.hide()
  if lsp_client_id then
    local client = vim.lsp.get_client_by_id(lsp_client_id)
    if client then
      client:stop()
    end
    lsp_client_id = nil
  end
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  bufnr, main_winid, get_jobid, pending, replacement, editor_path, closing_editor_path =
    nil, nil, nil, nil, nil, nil, nil
  history_queue, history_active, history_dispatch_scheduled = {}, false, false
  adaptive_float, syncing_float = false, false
  saved_split_height = nil
end

vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, { callback = sync_float })

return M
