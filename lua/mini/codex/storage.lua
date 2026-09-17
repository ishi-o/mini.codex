local M = {}

---@class mini.codex.Session
---@field id string
---@field title string

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

local function record_text(record)
  local payload = type(record.payload) == "table" and record.payload or record
  if type(payload) ~= "table" then
    return
  end

  if payload.role == "assistant" then
    return content_text(payload.content or payload.text or payload.message)
  end

  if
    payload.type == "agent_message"
    or payload.type == "agentMessage"
    or payload.type == "assistant_message"
    or payload.type == "assistantMessage"
  then
    return content_text(payload.message or payload.text or payload.content)
  end
end

local function read_rollout(path)
  local ok, lines = pcall(vim.fn.readfile, path, "b")
  if not ok or type(lines) ~= "table" then
    return
  end
  local latest
  for _, line in ipairs(lines) do
    local decoded, record = pcall(vim.json.decode, line)
    if decoded and type(record) == "table" then
      local text = record_text(record)
      if type(text) == "string" and text ~= "" then
        latest = text
      end
    end
  end
  return latest
end

---@param thread_id string?
---@return string?
function M.latest_output(thread_id)
  if type(thread_id) ~= "string" or thread_id == "" then
    return
  end
  local path = rollout_path(thread_id)
  return path and read_rollout(path) or nil
end

return M
