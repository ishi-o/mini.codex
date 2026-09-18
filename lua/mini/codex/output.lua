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
local detail_cursor
local input_winid
local saved_output_width
local saved_output_height
local saved_split_minimums = {}
local hiding_window = false
local split_state
local buffer_option = vim.api.nvim_win_resize and "buf" or "buffer"

local function is_valid_window(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function buffer_opts(buf, opts)
  opts[buffer_option] = buf
  return opts
end

local function resize_window(win, width, height)
  if vim.api.nvim_win_resize then
    return vim.api.nvim_win_resize(win, width or -1, height or -1, {})
  end
  return vim.api.nvim_win_call(win, function()
    if width then
      vim.cmd("vertical resize " .. width)
    end
    if height then
      vim.cmd("resize " .. height)
    end
  end)
end

local function relax_split_minimum(vertical)
  local option = vertical and "winwidth" or "winheight"
  if saved_split_minimums[option] == nil and vim.o[option] > 1 then
    saved_split_minimums[option] = vim.o[option]
    vim.o[option] = 1
  end
end

local function restore_split_minimum()
  for option, value in pairs(saved_split_minimums) do
    vim.o[option] = value
  end
  saved_split_minimums = {}
end

local function save_view(win)
  if not is_valid_window(win) then
    return
  end
  local ok, view = pcall(vim.api.nvim_win_call, win, vim.fn.winsaveview)
  return ok and view or nil
end

local function restore_view(win, view)
  if view and is_valid_window(win) then
    pcall(vim.api.nvim_win_call, win, function()
      vim.fn.winrestview(view)
    end)
  end
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
        pcall(vim.keymap.del, mode, key, buffer_opts(buf, {}))
      end
    end
  end
  for name in pairs(bound_keys) do
    bound_keys[name] = nil
  end
end

local function map_key(buf, mode, key, callback)
  if type(key) == "string" and key ~= "" then
    vim.keymap.set(mode, key, callback, buffer_opts(buf, { silent = true, nowait = true }))
  end
end

local function bind_keymaps(buf, modes, bound_keys, names)
  local keymap = config.keymap
  clear_keymaps(buf, bound_keys, type(modes) == "table" and modes or { modes })
  for _, name in ipairs(names) do
    map_key(buf, modes, keymap[name], M[name])
    bound_keys[name] = keymap[name]
  end
end

local function set_main_keymaps()
  if is_valid_window(main_winid) then
    bind_keymaps(vim.api.nvim_win_get_buf(main_winid), { "n", "t" }, main_bound_keys, {
      "toggle",
      "refresh",
      "prev",
      "next",
    })
  end
end

local function set_output_keymaps()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  bind_keymaps(bufnr, "n", output_bound_keys, { "toggle", "refresh", "prev", "next", "detail" })
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
  detail_cursor = nil
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
  local input_target = is_valid_window(input_winid) and input_winid or nil
  if saved_output_width then
    opts.width = saved_output_width
  end
  if saved_output_height then
    opts.height = saved_output_height
  end
  local normal_split = opts.relative == nil or opts.relative == ""
  adaptive_window = should_adapt(opts, main_config)
  if adaptive_window then
    opts = adaptive_window_config(opts, main_config)
  elseif normal_split then
    opts = normal_split_config(opts, main_config)
  end
  local vertical = normal_split and is_vertical_split(opts)
  local target = normal_split and opts.win or nil
  local stacked = input_target
    and vim.api.nvim_win_get_config(input_target).relative == ""
    and main_config.relative == ""
    and target == main_winid
    and vertical
    and (opts.split == "left" or opts.split == "right")
  local stack_requested = stacked
  local extent = target and (vertical and vim.api.nvim_win_get_width(target) or vim.api.nvim_win_get_height(target))
  local input_height = stacked and vim.api.nvim_win_get_height(input_target) or nil
  local main_view = normal_split and save_view(main_winid) or nil
  local main_width = normal_split and vim.api.nvim_win_get_width(main_winid) or nil
  local main_height = normal_split and vim.api.nvim_win_get_height(main_winid) or nil
  if stacked then
    opts.win = input_target
  end
  if normal_split then
    relax_split_minimum(vertical)
  end
  winid = vim.api.nvim_open_win(bufnr, not stacked, opts)
  if stacked then
    local moved, result = pcall(vim.fn.win_splitmove, main_winid, input_target, {
      vertical = false,
      rightbelow = false,
    })
    stacked = moved and result == 0
  end
  if stacked then
    pcall(resize_window, input_target, nil, input_height)
    target = main_winid
  elseif stack_requested then
    target = input_target
  end
  if normal_split then
    if vertical then
      pcall(resize_window, winid, opts.width)
      pcall(resize_window, target, math.max(1, extent - vim.api.nvim_win_get_width(winid) - 1))
    else
      pcall(resize_window, winid, nil, opts.height)
      pcall(resize_window, target, nil, math.max(1, extent - vim.api.nvim_win_get_height(winid) - 1))
    end
    local restore_width = target ~= main_winid or not vertical
    local restore_height = target ~= main_winid or vertical
    pcall(resize_window, main_winid, restore_width and main_width or nil, restore_height and main_height or nil)
    split_state = { target = target, vertical = vertical, stacked = stacked }
    restore_view(main_winid, main_view)
  elseif not adaptive_window then
    restore_split_minimum()
  end
  set_window_options(winid)
  set_output_keymaps()
  if stacked and is_valid_window(winid) then
    vim.api.nvim_set_current_win(winid)
  end
end

function M.hide()
  if is_valid_window(winid) then
    local state = split_state
    local split_target = state and is_valid_window(state.target) and state.target or nil
    local vertical = state and state.vertical or false
    local main_view = save_view(main_winid)
    local target_view = split_target ~= main_winid and save_view(split_target) or nil
    local main_width = is_valid_window(main_winid) and vim.api.nvim_win_get_width(main_winid) or nil
    local main_height = is_valid_window(main_winid) and vim.api.nvim_win_get_height(main_winid) or nil
    local input_height = state
        and state.stacked
        and is_valid_window(input_winid)
        and vim.api.nvim_win_get_height(input_winid)
      or nil
    local split_extent = split_target
        and (vertical and vim.api.nvim_win_get_width(split_target) + vim.api.nvim_win_get_width(winid) + 1 or vim.api.nvim_win_get_height(
          split_target
        ) + vim.api.nvim_win_get_height(winid) + 1)
      or nil
    saved_output_width = vim.api.nvim_win_get_width(winid)
    saved_output_height = vim.api.nvim_win_get_height(winid)
    local equalalways = vim.o.equalalways
    vim.o.equalalways = false
    hiding_window = true
    vim.api.nvim_win_hide(winid)
    hiding_window = false
    vim.o.equalalways = equalalways
    if split_extent then
      pcall(resize_window, split_target, vertical and split_extent or nil, vertical and nil or split_extent)
    end
    if is_valid_window(main_winid) then
      local restore_width = split_target ~= main_winid or not vertical
      local restore_height = split_target ~= main_winid or vertical
      pcall(resize_window, main_winid, restore_width and main_width or nil, restore_height and main_height or nil)
    end
    if input_height and is_valid_window(input_winid) then
      pcall(resize_window, input_winid, nil, input_height)
    end
    restore_view(main_winid, main_view)
    restore_view(split_target, target_view)
  end
  winid = nil
  adaptive_window, split_state = false, nil
  restore_split_minimum()
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
    local cursor = detail_cursor
    set_text(output_chats)
    if cursor then
      pcall(vim.api.nvim_win_set_cursor, winid, cursor)
    end
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
  detail_cursor = vim.api.nvim_win_get_cursor(winid)
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
---@param input_win integer?
function M.attach(main_win, id, token, input_win)
  if not config.enabled or not is_valid_window(main_win) then
    return
  end
  main_winid, main_bufnr, session_id, session_token = main_win, vim.api.nvim_win_get_buf(main_win), id, token
  input_winid = is_valid_window(input_win) and input_win or nil
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
  adaptive_window, syncing_window, split_state = false, false, nil
  output_title = "Codex output"
  output_chats, selected_chat = {}, nil
  turn_ranges, detail_turn, detail_cursor = {}, nil, nil
  input_winid, saved_output_width, saved_output_height = nil, nil, nil
  restore_split_minimum()
end

vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, { callback = sync_window })
vim.api.nvim_create_autocmd("WinClosed", {
  callback = function(args)
    local closed = tonumber(args.match)
    if closed == main_winid then
      M.close()
    elseif closed == winid then
      winid = nil
      adaptive_window, split_state = false, nil
      if not hiding_window then
        vim.schedule(restore_split_minimum)
      end
    end
  end,
})

return M
