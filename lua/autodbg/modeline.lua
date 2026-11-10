-- =============================================================================
-- nvim/lua/autodbg/modeline.lua —— 脚本头部的 AutoDbg 标记（modeline）
--
-- 来源：新写（与 AutoDbg 的 `--!lua` / `--!luajit` 首行标记同族）。
-- 目的：让**每个脚本自己**声明要连哪台 server，改地址不用动 setup 的默认值。
--
-- 语法（只看前 5 行与后 5 行，行必须是 `--` 注释；口径与 vim 的 modeline 一致）：
--
--   --!autodbg url=http://192.168.1.10:8642 token=deadbeef
--   --!autodbg host=192.168.1.10 port=8642
--   -- autodbg: url=http://127.0.0.1:8642      （modeline 风格也认）
--   -- adbg: port=9000                        （短别名）
--   --!autodbg                               （裸标记：只表示「这是 AutoDbg 脚本」）
--
-- 键：`url` / `host` / `port` / `token`，覆盖 setup 的默认值。
--   · `url` 同时给出时优先；只给 host/port 时，未给的字段从 setup 的 url 里取。
--   · 多行/多键时**后出现的覆盖先出现的**。
-- 这个标记同时也是 LuaLS 注解的开关依据（见 `lua/autodbg/lsp.lua`）：
--   没有标记的 buffer 不会被当成 AutoDbg 脚本。无名 buffer 一样能用。
-- =============================================================================

local M = {}

local DEFAULT_HEAD = 5
local DEFAULT_TAIL = 5

--- `-- ...` 注释体；不是注释返回 nil
---@param line string
---@return string?
local function comment_body(line)
  return line:match("^%s*%-%-(.*)$")
end

--- 若该行是 AutoDbg 标记行，返回标记后面的剩余文本（可能为空串）；否则 nil
---@param line string
---@return string?
local function marker_rest(line)
  local body = comment_body(line)
  if not body then
    return nil
  end
  local b = vim.trim(body)
  if b:sub(1, 1) == "!" then
    b = vim.trim(b:sub(2))
  end
  local word, rest = b:match("^([%a_]+)%s*:?%s*(.*)$")
  if not word then
    return nil
  end
  word = word:lower()
  if word ~= "autodbg" and word ~= "adbg" then
    return nil
  end
  return rest or ""
end

--- 从标记行剩余文本里抽 key=value（值可用单/双引号包起来）
---@param rest string
---@param out table
local function parse_kv(rest, out)
  for k, v in rest:gmatch("([%w_]+)%s*=%s*([^%s]+)") do
    v = v:gsub('^"', ""):gsub('"$', ""):gsub("^'", ""):gsub("'$", "")
    out[k:lower()] = v
  end
end

--- 取 lines[a..b]（1-based、闭区间）
---@param t string[]
---@param a integer
---@param b integer
---@return string[]
local function slice(t, a, b)
  local out = {}
  for i = a, b do
    out[#out + 1] = t[i]
  end
  return out
end

--- 解析一段行（`offset` 用于把行号还原成绝对行号）
---@param lines string[]
---@param offset integer 0 表示 lines[1] 是文件第 1 行
---@return table { found, line, url?, host?, port?, token? }
function M.parse(lines, offset)
  local res = { found = false }
  for i, line in ipairs(lines or {}) do
    local rest = marker_rest(line)
    if rest then
      res.found = true
      res.line = (offset or 0) + i
      parse_kv(rest, res)
    end
  end
  return res
end

--- 解析纯文本（测试与“还没进 buffer”的场景用）
---@param text string
---@param opts? { head: integer?, tail: integer? }
---@return table
function M.from_text(text, opts)
  opts = opts or {}
  local head = opts.head or DEFAULT_HEAD
  local tail = opts.tail or DEFAULT_TAIL
  local lines = vim.split(text or "", "\n", { plain = true })

  local res = M.parse(slice(lines, 1, math.min(head, #lines)), 0)
  local start = math.max(1, #lines - tail + 1)
  if start > head then
    local tail_res = M.parse(slice(lines, start, #lines), start - 1)
    if tail_res.found then
      for k, v in pairs(tail_res) do
        res[k] = v
      end
      res.found = true
    end
  end
  return res
end

--- 从 buffer 解析（无名 buffer 也能用；只看前/后 N 行）
---@param bufnr integer?
---@param opts? { head: integer?, tail: integer? }
---@return table
function M.from_buf(bufnr, opts)
  opts = opts or {}
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return { found = false }
  end

  local head = opts.head or DEFAULT_HEAD
  local tail = opts.tail or DEFAULT_TAIL
  local total = vim.api.nvim_buf_line_count(bufnr)
  local res = { found = false }

  local head_lines = vim.api.nvim_buf_get_lines(bufnr, 0, math.min(head, total), false)
  local h = M.parse(head_lines, 0)
  res = h

  local start = math.max(0, total - tail)
  if start >= head then
    local tail_lines = vim.api.nvim_buf_get_lines(bufnr, start, total, false)
    local t = M.parse(tail_lines, start)
    if t.found then
      for k, v in pairs(t) do
        res[k] = v
      end
      res.found = true
    end
  end
  return res
end

--- 该 buffer 是否是 AutoDbg 脚本（头部/尾部有标记）
---@param bufnr integer?
---@return boolean
function M.is_autodbg_buf(bufnr)
  return M.from_buf(bufnr).found == true
end

--- 把 modeline 里的 url/host/port 合到 setup 的默认 url 上
---@param base_url string setup 里的默认地址
---@param ml table M.parse/from_buf 的结果
---@return string
function M.merge_url(base_url, ml)
  if type(ml) ~= "table" or not ml.found then
    return base_url
  end
  if ml.url and ml.url ~= "" then
    local url = ml.url
    if not url:match("^%a[%w+.-]*://") then
      url = "http://" .. url
    end
    return (url:gsub("/+$", ""))
  end
  if ml.host or ml.port then
    local _, host, port = tostring(base_url or ""):match("^(%a[%w+.-]*)://([^/:]+):?(%d*)")
    host = ml.host or host or "127.0.0.1"
    port = ml.port or (port ~= "" and port) or "8642"
    return string.format("http://%s:%s", host, port)
  end
  return base_url
end

return M
