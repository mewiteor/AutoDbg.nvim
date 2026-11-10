-- =============================================================================
-- nvim/lua/autodbg/http.lua —— AutoDbg server 的 HTTP 传输（S3）
--
-- 来源：新写（plan_server.md S3 / §6.1）。
-- 为什么走 `curl` 而不是纯 uv：v1 只要「POST 一段文本、拿回响应」，`curl` 在
--   Windows 10+（系统自带）与各 Linux 发行版上都在；纯 `vim.loop` 实现留给 S5，
--   两者共用本文件导出的接口（`M.request`），换实现不动上层。
-- 约定：
--   · 脚本正文走 **stdin**（`--data-binary @-`）—— 不落临时文件（与 D26 一致）；
--   · `-D -` 把响应头也打到 stdout：我们从中取状态码与 `X-AutoDbg-Exit`，
--     正文取分隔符 `\r\n\r\n` 之后的部分（不发临时文件）；
--   · 同步/异步两种模式：`sync = true` 时用 `SystemObj:wait()`（测试与脚本化用）。
-- =============================================================================

local M = {}

local function join_headers(headers)
  local out = {}
  for k, v in pairs(headers or {}) do
    out[#out + 1] = "-H"
    out[#out + 1] = k .. ": " .. tostring(v)
  end
  return out
end

--- 解析 curl `-D -` 的输出：返回 status, headers(table, 小写键), body
local function parse_response(raw)
  local sep = raw:find("\r\n\r\n", 1, true)
  if not sep then
    -- 有些平台/版本用单个 \n
    sep = raw:find("\n\n", 1, true)
    if not sep then
      return 0, {}, raw
    end
    local head = raw:sub(1, sep - 1)
    local body = raw:sub(sep + 2)
    local status = tonumber(head:match("^HTTP/%d%.%d%s+(%d+)")) or 0
    return status, {}, body
  end

  local head = raw:sub(1, sep - 1)
  local body = raw:sub(sep + 4)

  local status = tonumber(head:match("^HTTP/%d%.%d%s+(%d+)")) or 0
  local headers = {}
  for line in (head .. "\r\n"):gmatch("(.-)\r\n") do
    local name, value = line:match("^([%w%-_]+):%s*(.-)%s*$")
    if name then
      headers[name:lower()] = value
    end
  end
  return status, headers, body
end

M.parse_response = parse_response

--- 发一个请求。
-- @param cfg   table：{ url, token, token_header, curl, timeout_ms, extra_headers }
-- @param opts  table：{ method, path, body, headers, sync }
-- @return 同步：{ ok, status, headers, body, err }；异步：SystemObj（回调收到同样的 table）
function M.request(cfg, opts, on_done)
  opts = opts or {}
  local method = opts.method or "POST"
  local url = cfg.url .. (opts.path or "/run")

  local args = { cfg.curl or "curl", "-sS", "-D", "-", "-X", method }
  if cfg.timeout_ms and cfg.timeout_ms > 0 then
    args[#args + 1] = "--max-time"
    args[#args + 1] = tostring(math.max(1, math.floor(cfg.timeout_ms / 1000)))
  end

  local headers = {}
  for k, v in pairs(cfg.extra_headers or {}) do
    headers[k] = v
  end
  for k, v in pairs(opts.headers or {}) do
    headers[k] = v
  end
  if cfg.token and cfg.token ~= "" then
    headers[cfg.token_header or "Authorization"] = "Bearer " .. cfg.token
  end

  local extra = join_headers(headers)
  for _, a in ipairs(extra) do
    args[#args + 1] = a
  end

  if opts.body ~= nil then
    args[#args + 1] = "--data-binary"
    args[#args + 1] = "@-"
  end
  args[#args + 1] = url

  local sys_opts = { text = false }
  if opts.body ~= nil then
    sys_opts.stdin = opts.body
  end

  local function finish(obj)
    local out = obj.stdout or ""
    if type(out) == "table" then
      out = table.concat(out, "")
    end
    local status, headers_out, body = parse_response(out)
    local err = nil
    if obj.code ~= 0 then
      err = "curl exited with " .. tostring(obj.code) .. (obj.stderr and (": " .. tostring(obj.stderr)) or "")
    end
    return {
      ok = (obj.code == 0) and status >= 200 and status < 300,
      status = status,
      headers = headers_out,
      body = body,
      err = err,
    }
  end

  if opts.sync then
    local obj = vim.system(args, sys_opts):wait(cfg.sync_timeout_ms or 60000)
    return finish(obj)
  end

  return vim.system(args, sys_opts, function(obj)
    local res = finish(obj)
    if on_done then
      vim.schedule(function()
        on_done(res)
      end)
    end
  end)
end

return M
