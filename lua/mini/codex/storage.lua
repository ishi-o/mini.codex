local M = {}

---@class mini.codex.Session
---@field id string
---@field title string

---@alias mini.codex.OutputChatTurnKind
---| "user"
---| "assistant"
---| "reasoning"
---| "command"
---| "mcp"
---| "file"
---| "subagent"
---| "unknown"

---@alias mini.codex.OutputChatTurnLabel
---| "User"
---| "Assistant"
---| "Reasoning"
---| "Command"
---| "MCP tool"
---| "File changes"
---| "Subagent"
---| "Unknown"

---@class mini.codex.OutputChatTurn
---@field kind mini.codex.OutputChatTurnKind
---@field label mini.codex.OutputChatTurnLabel
---@field text string
---@field status string?
---@field item_id string?
---@field detail_thread_id string?

---@class mini.codex.OutputChat
---@field chat integer
---@field question string
---@field turns mini.codex.OutputChatTurn[]
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

local function history_database_path()
  return joinpath(codex_home(), "thread_history_1.sqlite")
end

local function quote(value)
  return "'" .. value:gsub("'", "''") .. "'"
end

local function string_value(value, fallback)
  if type(value) == "string" then
    return value
  end
  return fallback
end

---@type table<string, mini.codex.OutputChatTurnKind>
local item_kinds = {
  userMessage = "user",
  agentMessage = "assistant",
  reasoning = "reasoning",
  commandExecution = "command",
  mcpToolCall = "mcp",
  fileChange = "file",
}

---@type table<mini.codex.OutputChatTurnKind, mini.codex.OutputChatTurnLabel>
local turn_labels = {
  user = "User",
  assistant = "Assistant",
  reasoning = "Reasoning",
  command = "Command",
  mcp = "MCP tool",
  file = "File changes",
  subagent = "Subagent",
  unknown = "Unknown",
}

local function query(sql, db)
  db = db or database_path()
  if vim.fn.filereadable(db) ~= 1 then
    return {}
  end
  local output = vim.fn.system({ "sqlite3", "-json", db, sql })
  local ok, rows = pcall(vim.json.decode, output)
  if vim.v.shell_error ~= 0 or output == "" or not ok or type(rows) ~= "table" then
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
  for _, field in ipairs({ "text", "output_text", "value" }) do
    if type(content[field]) == "string" then
      return content[field]
    end
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

local function make_chats(messages)
  local chats = {}
  local current

  local function finish()
    if current and #current.turns > 0 then
      chats[#chats + 1] = {
        chat = #chats + 1,
        question = current.question,
        turns = current.turns,
        turn_id = current.turn_id,
      }
    end
    current = nil
  end

  for _, message in ipairs(messages) do
    if message.role == "user" then
      finish()
      current = {
        question = message.text,
        turns = { { kind = "user", label = "User", text = message.text } },
        turn_id = message.turn_id,
      }
    elseif message.role == "assistant" then
      if not current then
        current = { question = "", turns = {}, turn_id = message.turn_id }
      end
      if message.turn_id and not current.turn_id then
        current.turn_id = message.turn_id
      end
      current.turns[#current.turns + 1] = {
        kind = "assistant",
        label = "Assistant",
        text = message.text,
      }
    end
  end
  finish()
  return chats
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
  return make_chats(messages)
end

local function decode_json(value)
  local ok, decoded = pcall(vim.json.decode, value)
  if ok and type(decoded) == "table" then
    return decoded
  end
end

local function encode_json(value)
  local ok, encoded = pcall(vim.json.encode, value)
  return ok and encoded or ""
end

local function command_turn(item)
  local lines = { "```sh", "$ " .. string_value(item.command, ""), "```" }
  local output = string_value(item.aggregatedOutput)
    or string_value(item.output)
    or string_value(item.stderr)
    or string_value(item.stdout)
  if output ~= "" then
    vim.list_extend(lines, { "", "```text", output, "```" })
  end
  local status = string_value(item.status)
  if item.exitCode ~= nil and item.exitCode ~= vim.NIL then
    status = status and status .. " · exit " .. tostring(item.exitCode) or "exit " .. tostring(item.exitCode)
  end
  return {
    kind = "command",
    label = turn_labels.command,
    text = table.concat(lines, "\n"),
    status = status,
  }
end

local function mcp_turn(item)
  local lines = {
    "MCP: " .. string_value(item.server, "unknown") .. " / " .. string_value(item.tool, "unknown"),
  }
  local arguments = type(item.arguments) == "table" and encode_json(item.arguments) or ""
  if arguments ~= "" and arguments ~= "{}" then
    vim.list_extend(lines, { "", "```json", arguments, "```" })
  end
  local result = item.result
  local text = type(result) == "table" and content_text(type(result.content) == "table" and result.content or result)
    or nil
  if type(text) == "string" and text ~= "" then
    vim.list_extend(lines, { "", "```text", text, "```" })
  elseif item.error ~= nil and item.error ~= vim.NIL then
    local error_text = type(item.error) == "table" and content_text(item.error) or nil
    vim.list_extend(lines, { "", "```text", error_text or encode_json(item.error), "```" })
  end
  return {
    kind = "mcp",
    label = turn_labels.mcp,
    text = table.concat(lines, "\n"),
    status = string_value(item.status),
  }
end

local function file_change_turn(item)
  local lines = {}
  for _, change in ipairs(type(item.changes) == "table" and item.changes or {}) do
    if change.path then
      vim.list_extend(lines, { "### " .. change.path, "", "```diff", string_value(change.diff, ""), "```" })
    end
  end
  return {
    kind = "file",
    label = turn_labels.file,
    text = table.concat(lines, "\n"),
    status = string_value(item.status),
  }
end

local function item_turn(item)
  local kind = item_kinds[item.type] or "unknown"
  if kind == "user" then
    return {
      kind = "user",
      label = turn_labels.user,
      text = content_text(type(item.content) == "table" and item.content or item) or "",
    }
  elseif kind == "assistant" then
    return {
      kind = "assistant",
      label = turn_labels.assistant,
      text = string_value(item.text) or content_text(item.content) or "",
    }
  elseif kind == "reasoning" then
    local reasoning = type(item.summary) == "table" and #item.summary > 0 and item.summary or item.content
    return {
      kind = "reasoning",
      label = turn_labels.reasoning,
      text = content_text(reasoning) or "",
    }
  elseif kind == "command" then
    return command_turn(item)
  elseif kind == "mcp" then
    return mcp_turn(item)
  elseif kind == "file" then
    return file_change_turn(item)
  end

  local text = content_text(type(item.content) == "table" and item.content or item)
  return {
    kind = kind,
    label = turn_labels[kind],
    text = text or string_value(item.text) or string_value(item.output) or encode_json(item),
    status = string_value(item.status),
  }
end

local function preview_turn(row)
  local kind = item_kinds[string_value(row.item_type)] or "unknown"
  local summary = string_value(row.summary)
  local status = string_value(row.status)
  local exit_code = tonumber(row.exit_code)
  if exit_code then
    status = status ~= "" and status .. " · exit " .. exit_code or "exit " .. exit_code
  end

  if kind == "user" or kind == "assistant" then
    local item = decode_json(row.item_json)
    if item then
      return item_turn(item)
    end
  end

  return {
    kind = kind,
    label = turn_labels[kind],
    text = summary ~= "" and summary or kind,
    status = status ~= "" and status or nil,
    item_id = string_value(row.item_id),
  }
end

local function subagent_turns(thread_id, chats)
  local rows = query(
    string.format(
      "SELECT e.child_thread_id AS id, e.status, t.title, t.created_at "
        .. "FROM thread_spawn_edges e LEFT JOIN threads t ON t.id = e.child_thread_id "
        .. "WHERE e.parent_thread_id = %s ORDER BY t.created_at",
      quote(thread_id)
    )
  )
  for _, row in ipairs(rows) do
    if type(row.id) == "string" and row.id ~= "" then
      local created_at = tonumber(row.created_at)
      local target = chats[#chats]
      for index = #chats, 1, -1 do
        local chat = chats[index]
        local started_at = tonumber(chat.started_at)
        local completed_at = tonumber(chat.completed_at)
        if created_at and started_at and created_at >= started_at then
          if not completed_at or created_at <= completed_at then
            target = chat
          end
          break
        end
      end
      if target then
        target.turns[#target.turns + 1] = {
          kind = "subagent",
          label = "Subagent",
          text = string_value(row.title, row.id),
          status = string_value(row.status),
          detail_thread_id = row.id,
        }
      end
    end
  end
end

local function thread_history(thread_id)
  local turn_rows = query(
    string.format(
      "SELECT turn_id, status, started_at, completed_at FROM thread_turns "
        .. "WHERE thread_id = %s ORDER BY rollout_ordinal",
      quote(thread_id)
    ),
    history_database_path()
  )
  if #turn_rows == 0 then
    return
  end

  local chats = {}
  local chats_by_id = {}
  for _, row in ipairs(turn_rows) do
    if type(row.turn_id) == "string" and row.turn_id ~= "" then
      local chat = {
        chat = #chats + 1,
        question = "",
        turns = {},
        turn_id = row.turn_id,
        status = string_value(row.status),
        started_at = row.started_at,
        completed_at = row.completed_at,
      }
      chats[#chats + 1] = chat
      chats_by_id[chat.turn_id] = chat
    end
  end
  if #chats == 0 then
    return
  end

  local item_rows = query(
    string.format(
      "SELECT turn_id, item_id, item_type, "
        .. "json_extract(item_json, '$.status') AS status, "
        .. "json_extract(item_json, '$.exitCode') AS exit_code, "
        .. "CASE "
        .. "WHEN item_type = 'commandExecution' THEN substr(json_extract(item_json, '$.command'), 1, 160) "
        .. "WHEN item_type = 'mcpToolCall' THEN substr(json_extract(item_json, '$.server') || ' / ' "
        .. "|| json_extract(item_json, '$.tool'), 1, 160) "
        .. "WHEN item_type = 'fileChange' THEN coalesce(json_extract(item_json, '$.changes[0].path'), '') "
        .. "WHEN item_type = 'reasoning' THEN substr(coalesce(json_extract(item_json, '$.summary[0].text'), "
        .. "json_extract(item_json, '$.content[0]'), ''), 1, 160) "
        .. "ELSE substr(item_json, 1, 160) END AS summary, "
        .. "CASE WHEN item_type IN ('userMessage', 'agentMessage') THEN item_json END AS item_json "
        .. "FROM thread_items WHERE thread_id = %s ORDER BY rollout_ordinal",
      quote(thread_id)
    ),
    history_database_path()
  )
  for _, row in ipairs(item_rows) do
    local chat = type(row.turn_id) == "string" and chats_by_id[row.turn_id]
    if chat then
      local turn = preview_turn(row)
      if turn.text ~= "" then
        chat.turns[#chat.turns + 1] = turn
        if turn.kind == "user" and chat.question == "" then
          chat.question = turn.text
        end
      end
    end
  end

  subagent_turns(thread_id, chats)
  for index, chat in ipairs(chats) do
    chat.chat = index
    chat.started_at, chat.completed_at = nil, nil
  end
  return chats
end

---@param thread_id string?
---@param turn mini.codex.OutputChatTurn?
---@param chat_turn_id string?
---@return string?
function M.output_turn_detail(thread_id, turn, chat_turn_id)
  if type(thread_id) ~= "string" or type(turn) ~= "table" then
    return
  end
  if turn.kind == "user" or turn.kind == "assistant" then
    return turn.text
  end

  local item_json
  if turn.detail_thread_id then
    local row = query(
      string.format(
        "SELECT item_json FROM thread_items WHERE thread_id = %s AND item_type = 'agentMessage' "
          .. "ORDER BY rollout_ordinal DESC LIMIT 1",
        quote(turn.detail_thread_id)
      ),
      history_database_path()
    )[1]
    item_json = row and row.item_json
  elseif turn.item_id and type(chat_turn_id) == "string" then
    local row = query(
      string.format(
        "SELECT item_json FROM thread_items WHERE thread_id = %s AND turn_id = %s AND item_id = %s LIMIT 1",
        quote(thread_id),
        quote(chat_turn_id),
        quote(turn.item_id)
      ),
      history_database_path()
    )[1]
    item_json = row and row.item_json
  end

  local item = decode_json(item_json)
  if not item then
    return turn.text
  end
  if turn.detail_thread_id then
    return string.format("### %s\n\n%s", turn.text, string_value(item.text, "No result available yet."))
  end
  return item_turn(item).text
end

---@param thread_id string?
---@return mini.codex.OutputChat[]
function M.output_history(thread_id)
  if type(thread_id) ~= "string" or thread_id == "" then
    return {}
  end
  local history = thread_history(thread_id)
  if history then
    return history
  end
  local path = rollout_path(thread_id)
  return path and read_rollout(path) or {}
end

---@param thread_id string?
---@return string?
function M.latest_output(thread_id)
  local history = M.output_history(thread_id)
  local chat = history[#history]
  for index = chat and #chat.turns or 0, 1, -1 do
    local turn = chat.turns[index]
    if turn.kind ~= "user" then
      return turn.text
    end
  end
end

return M
