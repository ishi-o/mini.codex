-- Optional Vim-style editor for Codex's terminal input.
local M = {}

---@class MiniCodexInputConfig
---@field enabled? boolean
---@field prompt? string
---@field height? number
---@field jump_key? string

---@class MiniCodexInputState
---@field prompt string
---@field height number
---@field jump_key string

---@type MiniCodexInputState
local defaults = { prompt = "Codex: ", height = 0.5, jump_key = "<C-g>" }
local config = vim.deepcopy(defaults)
local namespace = vim.api.nvim_create_namespace("mini.codex.input")
local bufnr, winid, main_winid, get_jobid, pending, replacement, editor_path
local available = true

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

local function request_editor(mode)
  local jobid = get_jobid and get_jobid()
  if not jobid or not main_winid then
    return
  end
  pending, replacement = mode, mode == "apply" and buffer_text() or nil
  vim.api.nvim_set_current_win(main_winid)
  vim.fn.chansend(jobid, "\7")
end

local function apply()
  if not editor_path then
    return request_editor("apply")
  end
  write_text(editor_path, buffer_text())
  editor_path = nil
  focus(main_winid)
end

local function apply_mapping()
  local completion = vim.fn.complete_info()
  local cancel = (vim.fn.pumvisible() == 1 or completion.mode ~= "") and "<C-e>" or ""
  return cancel .. "<Esc><Cmd>lua require('mini.codex.input')._apply()<CR>"
end

M._apply = apply

---@param opts? MiniCodexInputConfig
function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {}) --[[@as MiniCodexInputState]]
  available = true
end

function M.env()
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
  local mode, text = pending, replacement
  pending, replacement = nil, nil
  if mode == "apply" then
    write_text(path, text or "")
    vim.schedule_wrap(focus)(main_winid)
    return true
  end
  editor_path = path
  set_text(table.concat(vim.fn.readfile(path, "b"), "\n"))
  show_prompt()
  vim.schedule_wrap(focus)(winid)
  return false
end

function M._editor_done(path)
  return editor_path ~= path
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
  end
  show_prompt()

  local key = config.jump_key
  if type(key) == "string" and key ~= "" then
    local opts = { buffer = bufnr, silent = true }
    vim.keymap.set({ "n", "t" }, key, function()
      request_editor("edit")
    end, { buffer = vim.api.nvim_win_get_buf(main_win), silent = true })
    vim.keymap.set("n", key, apply, opts)
    vim.keymap.set("i", key, apply_mapping, vim.tbl_extend("force", opts, { expr = true }))
  end

  local max, height = vim.api.nvim_win_get_height(main_win), config.height
  height = height <= 1 and math.floor(max * height) or height
  height = math.max(1, math.min(height, max))
  winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "win",
    win = main_win,
    width = vim.api.nvim_win_get_width(main_win),
    height = height,
    row = max - height,
    col = 0,
    style = "minimal",
  })
  return winid
end

function M.hide()
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_hide(winid)
  end
  winid = nil
end

function M.close()
  M.hide()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  bufnr, main_winid, get_jobid, pending, replacement, editor_path = nil, nil, nil, nil, nil, nil
end

return M
