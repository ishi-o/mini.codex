local M = {}

---@class mini.codex.OutputKeymap
---@field toggle string
---@field refresh string
---@field prev string
---@field next string
---@field detail string

---@class mini.codex.OutputConfig
---@field enabled? boolean
---@field win? vim.api.keyset.win_config
---@field keymap? mini.codex.OutputKeymap

local default_width_ratio = 0.5

---@type mini.codex.OutputConfig
local defaults = {
  enabled = true,
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
}
local config = vim.deepcopy(defaults)
local storage = require("mini.codex.storage")
local bufnr, winid, main_winid, main_bufnr
local session_id
local session_token
local main_bound_keys = {}
local output_bound_keys = {}
local adaptive_window = false
local syncing_window = false
local output_title = "Codex output"
local output_chats = {}
local selected_chat
local turn_ranges = {}
local detail_turn

local function is_valid_window(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function set_window_options(win)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].winbar = output_title
end

local function clear_keymaps(buf, bound_keys, modes)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  for _, key in pairs(bound_keys) do
    if type(key) == "string" and key ~= "" then
      for _, mode in ipairs(modes) do
        pcall(vim.keymap.del, mode, key, { buffer = buf })
      end
    end
  end
  for name in pairs(bound_keys) do
    bound_keys[name] = nil
  end
end

local function map_key(buf, mode, key, callback)
  if type(key) == "string" and key ~= "" then
    vim.keymap.set(mode, key, callback, { buffer = buf, silent = true, nowait = true })
  end
end

local function set_main_keymaps()
  if not main_winid or not vim.api.nvim_win_is_valid(main_winid) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(main_winid)
  clear_keymaps(buf, main_bound_keys, { "n", "t" })
  local keymap = config.keymap
  map_key(buf, { "n", "t" }, keymap.toggle, M.toggle)
  map_key(buf, { "n", "t" }, keymap.refresh, M.refresh)
  map_key(buf, { "n", "t" }, keymap.prev, M.prev)
  map_key(buf, { "n", "t" }, keymap.next, M.next)
  main_bound_keys.toggle, main_bound_keys.refresh = keymap.toggle, keymap.refresh
  main_bound_keys.prev, main_bound_keys.next = keymap.prev, keymap.next
end

local function set_output_keymaps()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  clear_keymaps(bufnr, output_bound_keys, { "n" })
  local keymap = config.keymap
  map_key(bufnr, "n", keymap.toggle, M.toggle)
  map_key(bufnr, "n", keymap.refresh, M.refresh)
  map_key(bufnr, "n", keymap.prev, M.prev)
  map_key(bufnr, "n", keymap.next, M.next)
  map_key(bufnr, "n", keymap.detail, M.detail)
  output_bound_keys.toggle, output_bound_keys.refresh = keymap.toggle, keymap.refresh
  output_bound_keys.prev, output_bound_keys.next = keymap.prev, keymap.next
  output_bound_keys.detail = keymap.detail
end

local function set_buffer_name()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local name = session_id and "mini-codex://output/" .. session_id or "mini-codex://output"
    pcall(vim.api.nvim_buf_set_name, bufnr, name)
  end
end

local function compact_text(text, max_chars)
  local compact = vim.trim(text:gsub("%s+", " "))
  if vim.fn.strchars(compact) > max_chars then
    return vim.fn.strcharpart(compact, 0, max_chars - 1) .. "…"
  end
  return compact
end

local function set_output_title(chat)
  if not chat then
    output_title = "Codex output"
  else
    local question = compact_text(chat.question, 60)
    question = question:gsub("%%", "%%%%")
    output_title = question == "" and string.format("Codex output · chat %d/%d", chat.chat, #output_chats)
      or string.format("Codex output · chat %d/%d · for %s", chat.chat, #output_chats, question)
  end
  if is_valid_window(winid) then
    vim.wo[winid].winbar = output_title
  end
end

local function render_chat(chat)
  if not chat then
    return { "No Codex output available yet." }
  end
  local question = compact_text(chat.question, 80)
  local heading = string.format("## Chat %d", chat.chat)
  if question ~= "" then
    heading = heading .. " · for " .. question
  end
  local lines = { heading, "" }
  for index in pairs(turn_ranges) do
    turn_ranges[index] = nil
  end
  for index, turn in ipairs(chat.turns) do
    if index > 1 then
      lines[#lines + 1] = ""
    end
    local start_line = #lines + 1
    local heading = string.format("# Turn %d · %s", index, turn.label)
    if turn.status then
      heading = heading .. " · " .. turn.status
    end
    vim.list_extend(lines, { heading, "" })
    lines[#lines + 1] = turn.kind == "command" and "````sh" or "````markdown"
    vim.list_extend(lines, vim.split(turn.text, "\n", { plain = true }))
    lines[#lines + 1] = "````"
    turn_ranges[index] = { start_line = start_line, end_line = #lines }
  end
  if #lines == 0 then
    return { "No Codex output available yet." }
  end
  return lines
end

local function ensure_buffer()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    return bufnr
  end
  bufnr = vim.api.nvim_create_buf(false, false)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "markdown"
  vim.bo[bufnr].modifiable = false
  set_buffer_name()
  set_output_keymaps()
  return bufnr
end

local function set_buffer_lines(lines)
  ensure_buffer()
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].modifiable = false
end

---@param chats mini.codex.OutputChat[]
local function set_text(chats)
  ensure_buffer()
  set_buffer_name()
  local chat = chats[selected_chat]
  local lines = render_chat(chat)
  detail_turn = nil
  set_output_title(chat)
  set_buffer_lines(lines)
end

local function move_cursor_to_start()
  if is_valid_window(winid) then
    pcall(vim.api.nvim_win_set_cursor, winid, { 1, 0 })
  end
end

local function border_width(win_config)
  return win_config.border and win_config.border ~= "none" and 2 or 0
end

local function adaptive_window_config(opts, main_config)
  local col_offset = opts.col or 0
  opts.relative = "win"
  if not opts.win or opts.win == 0 then
    opts.win = main_winid
  end
  opts.row = opts.row or 0
  opts.col = main_config.width + border_width(main_config) + col_offset
  opts.width = opts.width or math.max(1, math.floor(main_config.width * default_width_ratio))
  opts.height = opts.height or main_config.height
  opts.style = opts.style or main_config.style
  opts.border = opts.border or main_config.border
  opts.split, opts.vertical = nil, nil
  return opts
end

local function is_vertical_split(opts)
  return opts.vertical or opts.split == "left" or opts.split == "right"
end

local function normal_split_config(opts, main_config)
  if not opts.win or opts.win == 0 then
    opts.win = main_winid
  end
  if is_vertical_split(opts) then
    opts.width = opts.width or math.max(1, math.floor(main_config.width * default_width_ratio))
  else
    opts.height = opts.height or main_config.height
  end
  return opts
end

local function should_adapt(opts, main_config)
  if opts.relative == "win" then
    return not opts.win or opts.win == 0 or opts.win == main_winid
  end
  return main_config.relative ~= "" and (opts.relative == nil or opts.relative == "")
end

local function sync_window()
  if
    not adaptive_window
    or syncing_window
    or not main_winid
    or not winid
    or not vim.api.nvim_win_is_valid(main_winid)
    or not vim.api.nvim_win_is_valid(winid)
  then
    return
  end
  syncing_window = true
  local main_config = vim.api.nvim_win_get_config(main_winid)
  local opts = adaptive_window_config(vim.deepcopy(config.win or {}), main_config)
  vim.api.nvim_win_set_config(winid, {
    relative = opts.relative,
    win = opts.win,
    row = opts.row,
    col = opts.col,
    width = opts.width,
    height = opts.height,
    style = opts.style,
    border = opts.border,
  })
  syncing_window = false
end

local function open_window()
  if not is_valid_window(main_winid) then
    return
  end
  ensure_buffer()
  local opts = vim.deepcopy(config.win or {})
  local main_config = vim.api.nvim_win_get_config(main_winid)
  local normal_split = opts.relative == nil or opts.relative == ""
  adaptive_window = should_adapt(opts, main_config)
  if adaptive_window then
    opts = adaptive_window_config(opts, main_config)
  elseif normal_split then
    opts = normal_split_config(opts, main_config)
  end
  winid = vim.api.nvim_open_win(bufnr, true, opts)
  if not adaptive_window and normal_split and is_vertical_split(opts) then
    pcall(vim.api.nvim_win_set_width, winid, opts.width)
  end
  set_window_options(winid)
  set_output_keymaps()
end

function M.hide()
  if is_valid_window(winid) then
    vim.api.nvim_win_hide(winid)
  end
  winid = nil
  adaptive_window = false
end

---@param token integer?
---@return mini.codex.OutputChat[]?
function M.refresh(token)
  if not config.enabled then
    return
  end
  if token and session_token and token ~= session_token then
    return
  end
  local previous = output_chats[selected_chat]
  local chats = storage.output_history(session_id)
  selected_chat = #chats
  if previous then
    for index, chat in ipairs(chats) do
      local same_chat_id = chat.turn_id ~= nil and chat.turn_id == previous.turn_id
      if same_chat_id or chat.chat == previous.chat then
        selected_chat = index
        break
      end
    end
  end
  output_chats = chats
  set_text(chats)
  return chats
end

function M.prev()
  if not config.enabled or selected_chat == nil or selected_chat <= 1 then
    return
  end
  selected_chat = selected_chat - 1
  set_text(output_chats)
  move_cursor_to_start()
end

function M.next()
  if not config.enabled or selected_chat == nil or selected_chat >= #output_chats then
    return
  end
  selected_chat = selected_chat + 1
  set_text(output_chats)
  move_cursor_to_start()
end

function M.detail()
  if not config.enabled or not is_valid_window(winid) then
    return
  end
  if detail_turn then
    set_text(output_chats)
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(winid)[1]
  local chat = output_chats[selected_chat]
  local turn_index
  for index, range in pairs(turn_ranges) do
    if cursor_line >= range.start_line and cursor_line <= range.end_line then
      turn_index = index
      break
    end
  end
  local turn = chat and chat.turns[turn_index]
  if not turn then
    return
  end

  local text = storage.output_turn_detail(session_id, turn, chat.turn_id)
  if not text or text == "" then
    return
  end
  detail_turn = turn
  local lines = {
    string.format("# Detail · Turn %d · %s", turn_index, turn.label),
    "",
  }
  vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
  set_buffer_lines(lines)
  vim.wo[winid].winbar = string.format("Codex detail · %s · press %s to return", turn.label, config.keymap.detail)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })
end

function M.show()
  if not config.enabled or not is_valid_window(main_winid) then
    return
  end
  if is_valid_window(winid) then
    M.refresh()
    vim.api.nvim_set_current_win(winid)
    return winid
  end
  M.refresh()
  open_window()
  return winid
end

function M.toggle()
  if is_valid_window(winid) then
    return M.hide()
  end
  return M.show()
end

---@param main_win integer
---@param id string?
---@param token integer?
function M.attach(main_win, id, token)
  if not config.enabled or not is_valid_window(main_win) then
    return
  end
  main_winid, main_bufnr, session_id, session_token = main_win, vim.api.nvim_win_get_buf(main_win), id, token
  output_chats, selected_chat = {}, nil
  set_buffer_name()
  set_main_keymaps()
  if is_valid_window(winid) then
    sync_window()
    M.refresh()
  end
end

---@param id string?
---@param token integer?
function M.set_session(id, token)
  if token and session_token and token ~= session_token then
    return
  end
  local session_changed = id ~= session_id
  session_id, session_token = id, token or session_token
  if session_changed then
    output_chats, selected_chat = {}, nil
  end
  set_buffer_name()
  if is_valid_window(winid) then
    M.refresh(token)
  end
end

---@param opts? mini.codex.OutputConfig
function M.setup(opts)
  opts = opts or {}
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts) --[[@as mini.codex.OutputConfig]]
  if opts.win then
    config.win = vim.deepcopy(opts.win)
  end
  if not config.enabled then
    M.close()
    return
  end
  set_main_keymaps()
  set_output_keymaps()
end

function M.close()
  clear_keymaps(main_bufnr, main_bound_keys, { "n", "t" })
  M.hide()
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
  bufnr, main_winid, main_bufnr, session_id, session_token = nil, nil, nil, nil, nil
  main_bound_keys, output_bound_keys = {}, {}
  adaptive_window, syncing_window = false, false
  output_title = "Codex output"
  output_chats, selected_chat = {}, nil
  turn_ranges, detail_turn = {}, nil
end

vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, { callback = sync_window })
vim.api.nvim_create_autocmd("WinClosed", {
  callback = function(args)
    if tonumber(args.match) == main_winid then
      M.close()
    end
  end,
})

return M
