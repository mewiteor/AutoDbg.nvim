-- =============================================================================
-- nvim/lua/autodbg/effects.lua —— 客户端文件 I/O 的效果循环（S7）
--
-- 来源：新写。
-- 背景：`read_file`/`write_file` 的文件在**本机（客户端）**，server 那侧执行到它们时
--   会挂起，并回 `{"pending":{"token":…,"effects":[{op,path,…}]}}`。
--   本文件负责：把 effects 在本地执行掉 → `POST /effects?token=…` 送回结果 → 直到
--   不再挂起为止（最多 `MAX_ROUNDS` 轮）。
-- 二进制安全：文件按 `io.open(path,"rb"/"wb")` 处理，跨网络用 base64。
-- =============================================================================

local http = require("autodbg.http")

local M = {}

local MAX_ROUNDS = 16

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function M.b64encode(data)
  local out = {}
  local n = #data
  local i = 1
  while i <= n do
    local a, b, c = data:byte(i, i + 2)
    out[#out + 1] = ALPHABET:sub(math.floor(a / 4) + 1, math.floor(a / 4) + 1)
    out[#out + 1] = ALPHABET:sub((a % 4) * 16 + (b and math.floor(b / 16) or 0) + 1,
                                (a % 4) * 16 + (b and math.floor(b / 16) or 0) + 1)
    if b then
      out[#out + 1] = ALPHABET:sub((b % 16) * 4 + (c and math.floor(c / 64) or 0) + 1,
                                  (b % 16) * 4 + (c and math.floor(c / 64) or 0) + 1)
    else
      out[#out + 1] = "="
    end
    out[#out + 1] = c and ALPHABET:sub(c % 64 + 1, c % 64 + 1) or "="
    i = i + 3
  end
  return table.concat(out)
end

function M.b64decode(data)
  if type(data) ~= "string" then
    return nil
  end
  data = data:gsub("[^%w%+/=]", "")
  local out = {}
  for i = 1, #data, 4 do
    local c1, c2, c3, c4 = data:byte(i, i + 3)
    local function val(c)
      if not c then
        return nil
      end
      local ch = string.char(c)
      local pos = ALPHABET:find(ch, 1, true)
      return pos and (pos - 1) or nil
    end
    local v1, v2 = val(c1), val(c2)
    local v3, v4 = val(c3), val(c4)
    if not v1 or not v2 then
      break
    end
    out[#out + 1] = string.char(v1 * 4 + math.floor(v2 / 16))
    if v3 then
      out[#out + 1] = string.char((v2 % 16) * 16 + math.floor(v3 / 4))
    end
    if v4 then
      out[#out + 1] = string.char((v3 % 4) * 64 + v4)
    end
  end
  return table.concat(out)
end

-- text 模式的行尾翻译（与 io.open("r"/"w") 的 Windows 语义一致）：
--   读：\r\n → \n；写：先归一化 \r\n → \n，再把 \n → \r\n（对 CRLF 输入幂等）
local function to_lf(s)
  return (s:gsub("\r\n", "\n"))
end

local function to_crlf(s)
  return (s:gsub("\r\n", "\n"):gsub("\n", "\r\n"))
end

local function is_text_mode(mode)
  return type(mode) == "string" and not mode:find("b", 1, true)
end

--- 在本地执行一个效果，返回要回给 server 的 result 表
function M.exec_effect(eff)
  local id = eff.id
  local text = is_text_mode(eff.mode)
  if eff.op == "read_file" then
    local f, err = io.open(eff.path, "rb")
    if not f then
      return { id = id, ok = false, error = tostring(err or ("cannot open " .. tostring(eff.path))) }
    end
    local data = f:read("*a") or ""
    f:close()
    local offset = tonumber(eff.offset) or 0
    local length = tonumber(eff.length) or 0
    if offset > 0 then
      data = data:sub(offset + 1)
    end
    if length > 0 then
      data = data:sub(1, length)
    end
    if text then
      data = to_lf(data)
    end
    return { id = id, ok = true, data = M.b64encode(data), size = #data }
  end

  -- write_file
  local mode = eff.append and "ab" or "wb"
  local f, err = io.open(eff.path, mode)
  if not f then
    return { id = id, ok = false, error = tostring(err or ("cannot open " .. tostring(eff.path))) }
  end
  local bytes = M.b64decode(eff.data or "") or ""
  if text then
    bytes = to_crlf(bytes)
  end
  f:write(bytes)
  f:close()
  return { id = id, ok = true, written = #bytes }
end

--- 把挂起前的输出（stdout_so_far）拼回最终响应的 stdout/stderr 里，
--- 这样用户看到的是**整段**输出，而不是「恢复之后」的那部分。
local function merge_partial(resp, acc_out, acc_err)
  if acc_out == "" and acc_err == "" then
    return resp
  end
  local ok, doc = pcall(vim.json.decode, resp.body or "")
  if not ok or type(doc) ~= "table" then
    return resp
  end
  doc.stdout = acc_out .. (doc.stdout or "")
  doc.stderr = acc_err .. (doc.stderr or "")
  resp.body = vim.json.encode(doc)
  return resp
end

--- 如果响应里带 pending，就把效果在本地做完并回送；循环到不再挂起为止。
-- @param req_cfg  http.request 用的配置（url/token/…）
-- @param resp     上一次的响应（{status, headers, body, err}）
-- @param on_done  最终回调（收到**不再挂起**的响应，已把各段的 stdout 拼好）
-- @param round    内部用
function M.resolve(req_cfg, resp, on_done, round, acc_out, acc_err)
  round = round or 1
  acc_out = acc_out or ""
  acc_err = acc_err or ""

  local ok, doc = pcall(vim.json.decode, resp.body or "")
  if not ok or type(doc) ~= "table" or doc.pending == nil then
    return on_done(merge_partial(resp, acc_out, acc_err))
  end

  if round > MAX_ROUNDS then
    vim.notify("AutoDbg: 效果循环超过 " .. MAX_ROUNDS .. " 轮，放弃", vim.log.levels.ERROR)
    return on_done(resp)
  end

  acc_out = acc_out .. tostring(doc.pending.stdout_so_far or "")
  acc_err = acc_err .. tostring(doc.pending.stderr_so_far or "")

  local effects = doc.pending.effects or {}
  local results = {}
  for _, eff in ipairs(effects) do
    results[#results + 1] = M.exec_effect(eff)
  end

  local token = tostring(doc.pending.token or "")
  local body = vim.json.encode({ results = results })

  http.request(req_cfg, {
    method = "POST",
    path = "/effects?token=" .. token,
    body = body,
    headers = { ["Content-Type"] = "application/json" },
  }, function(next_resp)
    M.resolve(req_cfg, next_resp, on_done, round + 1, acc_out, acc_err)
  end)
end

--- 同步版（给脚本化/测试用）
function M.resolve_sync(req_cfg, resp)
  local round = 0
  local acc_out, acc_err = "", ""
  while true do
    local ok, doc = pcall(vim.json.decode, resp.body or "")
    if not ok or type(doc) ~= "table" or doc.pending == nil then
      return merge_partial(resp, acc_out, acc_err)
    end
    round = round + 1
    if round > MAX_ROUNDS then
      return resp
    end
    acc_out = acc_out .. tostring(doc.pending.stdout_so_far or "")
    acc_err = acc_err .. tostring(doc.pending.stderr_so_far or "")
    local results = {}
    for _, eff in ipairs(doc.pending.effects or {}) do
      results[#results + 1] = M.exec_effect(eff)
    end
    resp = http.request(req_cfg, {
      method = "POST",
      path = "/effects?token=" .. tostring(doc.pending.token or ""),
      body = vim.json.encode({ results = results }),
      headers = { ["Content-Type"] = "application/json" },
      sync = true,
    })
  end
end

return M
