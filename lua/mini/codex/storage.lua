local M = {}

---@class mini.codex.Session
---@field id string
---@field title string

---@class mini.codex.OutputTurn
---@field turn integer
---@field question string
---@field response string
---@field turn_id string?

local joinpath = vim.fs and vim.fs.joinpath or function(base, name)
  return base:gsub("[/\\]+$", "") .. "/" .. name
end

local function codex_home()
  local home = vim.env.CODEX_HOME
  return vim.fn.expand(home and home ~= "" and home or "~/.codex")
end

local function database_path()
  return joinpath(codex_home(), "state_5.sqlite")
end

local function quote(value)
  return "'" .. value:gsub("'", "''") .. "'"
end

local function query(sql)
  local db = database_path()
  if vim.fn.filereadable(db) ~= 1 then
    return {}
  end
  local output = vim.fn.system({ "sqlite3", "-json", db, sql })
  if vim.v.shell_error ~= 0 or output == "" then
    return {}
  end
  local ok, rows = pcall(vim.json.decode, output)
  if not ok or type(rows) ~= "table" then
    return {}
  end
  return rows
end

---@param cwd string
---@return mini.codex.Session[]
function M.session_list(cwd)
  local sql = string.format(
    "SELECT id, title FROM threads WHERE cwd = %s AND archived = 0 ORDER BY created_at DESC LIMIT 20",
    quote(cwd)
  )
  local sessions = {}
  for _, row in ipairs(query(sql)) do
    if type(row.id) == "string" and row.id ~= "" then
      sessions[#sessions + 1] = {
        id = row.id,
        title = type(row.title) == "string" and row.title or "",
      }
    end
  end
  return sessions
end

local function rollout_path(thread_id)
  local sql = string.format("SELECT rollout_path FROM threads WHERE id = %s LIMIT 1", quote(thread_id))
  local row = query(sql)[1]
  if not row or type(row.rollout_path) ~= "string" or row.rollout_path == "" then
    return
  end
  if row.rollout_path:sub(1, 1) == "/" then
    return row.rollout_path
  end
  if row.rollout_path:sub(1, 2) == "~/" then
    return vim.fn.expand(row.rollout_path)
  end
  return joinpath(codex_home(), row.rollout_path)
end

local function content_text(content)
  if type(content) == "string" then
    return content
  end
  if type(content) ~= "table" then
    return
  end
  local direct = content.text or content.output_text or content.value
  if type(direct) == "string" then
    return direct
  end
  if content.content ~= nil then
    local nested = content_text(content.content)
    if nested then
      return nested
    end
  end
  local parts = {}
  for _, item in ipairs(content) do
    if type(item) == "string" then
      parts[#parts + 1] = item
    elseif type(item) == "table" then
      local text = item.text or item.output_text or item.value
      if type(text) == "string" then
        parts[#parts + 1] = text
      elseif item.content ~= nil then
        local nested = content_text(item.content)
        if nested then
          parts[#parts + 1] = nested
        end
      end
    end
  end
  return #parts > 0 and table.concat(parts, "\n") or nil
end

local function message_from_table(value, turn_id)
  if type(value) ~= "table" then
    return
  end
  local role = value.role
  local kind = value.type
  local text
  if role == "user" or role == "assistant" then
    text = content_text(value.content or value.text or value.message)
  elseif kind == "user_message" or kind == "userMessage" then
    role = "user"
    text = content_text(value.message or value.text or value.content)
  elseif
    kind == "agent_message"
    or kind == "agentMessage"
    or kind == "assistant_message"
    or kind == "assistantMessage"
  then
    role = "assistant"
    text = content_text(value.message or value.text or value.content)
  end
  if not role or not text or text == "" then
    return
  end
  return role, text, turn_id or value.turn_id
end

local function record_message(record)
  local payload = type(record.payload) == "table" and record.payload or record
  if type(payload) ~= "table" then
    return
  end
  local turn_id = payload.turn_id or record.turn_id
  if payload.item then
    local role, text, item_turn_id = message_from_table(payload.item, turn_id)
    if role then
      return role, text, item_turn_id
    end
  end
  return message_from_table(payload, turn_id)
end

local function add_message(messages, role, text, turn_id)
  local previous = messages[#messages]
  if previous and previous.role == role and previous.text == text then
    return
  end
  messages[#messages + 1] = { role = role, text = text, turn_id = turn_id }
end

local function make_turns(messages)
  local turns = {}
  local current

  local function finish()
    if current and current.response ~= "" then
      turns[#turns + 1] = {
        turn = #turns + 1,
        question = current.question,
        response = current.response,
        turn_id = current.turn_id,
      }
    end
    current = nil
  end

  for _, message in ipairs(messages) do
    if message.role == "user" then
      finish()
      current = { question = message.text, response = "", turn_id = message.turn_id }
    elseif message.role == "assistant" then
      if not current then
        current = { question = "", response = "", turn_id = message.turn_id }
      elseif message.turn_id and current.turn_id and message.turn_id ~= current.turn_id then
        finish()
        current = { question = "", response = "", turn_id = message.turn_id }
      elseif message.turn_id and not current.turn_id then
        current.turn_id = message.turn_id
      end
      if current.response ~= "" then
        current.response = current.response .. "\n\n"
      end
      current.response = current.response .. message.text
    end
  end
  finish()
  return turns
end

local function read_rollout(path)
  local ok, lines = pcall(vim.fn.readfile, path, "b")
  if not ok or type(lines) ~= "table" then
    return
  end
  local messages = {}
  for _, line in ipairs(lines) do
    local decoded, record = pcall(vim.json.decode, line)
    if decoded and type(record) == "table" then
      local role, text, turn_id = record_message(record)
      if role then
        add_message(messages, role, text, turn_id)
      end
    end
  end
  return make_turns(messages)
end

---@param thread_id string?
---@return mini.codex.OutputTurn[]
function M.output_history(thread_id)
  if type(thread_id) ~= "string" or thread_id == "" then
    return {}
  end
  local path = rollout_path(thread_id)
  return path and read_rollout(path) or {}
end

---@param thread_id string?
---@return string?
function M.latest_output(thread_id)
  local history = M.output_history(thread_id)
  local latest = history[#history]
  return latest and latest.response or nil
end

return M
