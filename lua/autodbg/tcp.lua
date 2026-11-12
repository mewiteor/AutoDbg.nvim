-- =============================================================================
-- nvim/lua/autodbg/tcp.lua —— raw TCP 帧客户端（取代已删除的 http.lua / stream.lua）
--
-- 契约见 AutoDbg 仓库的 `tools/agent/autodbg-skill/references/cli.md`（帧表）与
-- `src/common/frame.hpp`（帧头）。分帧：
--     u32 payload_len | u8 type | u8 flags | u16 id | u32 data_len | [json] | [data]
--   全部**小端**；`json_len = payload_len - 8 - data_len`。
--
-- 一次请求 = 一条连接：握手（id = 协议版本、data = token）→ `script` 帧 →
--   `out` / `open`+`data`+`close` / `read_req`（本文件必须回 `read_resp`）→ `result` + `end`。
-- 控制命令走另一条短连接：握手 → `control` 帧（命令在 flags）→ `ack` / `info` → 关。
--
-- ❗uv 回调是 **fast event context**：里面不能调 nvim API，面向用户的回调要 `vim.schedule`。
-- ❗neovim 的 Lua 是 LuaJIT：既没有 `string.pack`（5.3+），也没有 `& | << >>` 运算符。
-- =============================================================================

local M = {}

-- 帧类型（与 src/scripting/lua/stream.hpp 一致）
local T = {
  OPEN = 1,
  DATA = 2,
  CLOSE = 3,
  OUT = 4,
  RESULT = 5,
  ERROR = 6,
  READ_REQ = 7,
  ACK = 8,
  INFO = 9,
  HANDSHAKE = 10,
  SCRIPT = 11,
  CONTROL = 12,
  READ_RESP = 13,
  END = 14,
  CANCEL_NOTIFY = 15,
}

local PROTO = 1          -- k_stream_proto_version

-- ❗LuaJIT 没有 `string.pack` / 位运算符 → 帧编解码自己用 `bit` + `string.char`。
local band, rshift = bit.band, bit.rshift

local function u32le(v)
  return string.char(band(v, 0xFF), band(rshift(v, 8), 0xFF), band(rshift(v, 16), 0xFF),
    band(rshift(v, 24), 0xFF))
end

local function u16le(v)
  return string.char(band(v, 0xFF), band(rshift(v, 8), 0xFF))
end

local function read_u32le(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  if not d then
    return nil
  end
  return a + b * 256 + c * 65536 + d * 16777216
end

local function read_u16le(s, i)
  local a, b = s:byte(i, i + 1)
  if not b then
    return nil
  end
  return a + b * 256
end

local RESULT_OK = 0x01
local RESULT_CANCELED = 0x02
local RESULT_TIMED_OUT = 0x04
local RESULT_TRUNCATED = 0x08
local RESP_EOF = 0x01
local RESP_ERROR = 0x02

-- 控制命令（stream_control_cmd）
local CMD = { cancel = 0, kill = 1, detach = 2, health = 3, version = 4, shutdown = 5 }

M.PROTO = PROTO
M.CMD = CMD

--- 解析 `host` / `port` / `url` → host, port
---@param cfg table
---@return string host
---@return integer port
function M.endpoint(cfg)
  local host = cfg.host
  local port = cfg.port
  local url = cfg.url
  if (not host or host == "") and type(url) == "string" and url ~= "" then
    local h, p = url:match("^%a+://([%w%.%-_]+):(%d+)")
    if not h then
      h, p = url:match("^([%w%.%-_]+):(%d+)$")
    end
    if h then
      host, port = h, tonumber(p)
    elseif not url:match("://") then
      host = url
    end
  end
  return host or "127.0.0.1", tonumber(port) or 8642
end

local function pack_frame(ftype, flags, id, json, data)
  json = json or ""
  data = data or ""
  local payload = 8 + #json + #data
  return u32le(payload)
    .. string.char(band(ftype, 0xFF), band(flags or 0, 0xFF))
    .. u16le(band(id or 0, 0xFFFF))
    .. u32le(#data)
    .. json
    .. data
end

--- 把缓冲区里的完整帧切出来
---@param buf string
---@return table[] frames, string rest
local function take_frames(buf)
  local frames = {}
  while #buf >= 4 do
    local payload = read_u32le(buf, 1)
    if not payload or #buf < 4 + payload then
      break
    end
    local ftype, flags = buf:byte(5, 6)
    local id = read_u16le(buf, 7) or 0
    local dlen = read_u32le(buf, 9) or 0
    local json_len = payload - 8 - dlen
    local json = ""
    local data = ""
    if json_len > 0 then
      json = buf:sub(13, 12 + json_len)
    end
    if dlen > 0 then
      data = buf:sub(13 + json_len, 12 + json_len + dlen)
    end
    frames[#frames + 1] = { type = ftype, flags = flags, id = id, json = json, data = data }
    buf = buf:sub(5 + payload)
  end
  return frames, buf
end

local function decode_json(s)
  if not s or s == "" then
    return nil
  end
  local ok, v = pcall(vim.json.decode, s)
  if ok then
    return v
  end
  return nil
end

--- 等到 `cond()` 为真。
--- ❗`vim.wait(0, cond)` **不是**「一直等」，而是「不等待，立刻返回 false」——
---   默认配置就是 `sync_timeout_ms = 0`，直接用会把每条请求都变成「1 ms 后超时」。
---   `ms <= 0` 在这里表示「一直等」：分片循环，连接断开时 `finish` 会把 cond 置真。
local function wait_until(cond, ms)
  ms = tonumber(ms) or 0
  if ms > 0 then
    return vim.wait(ms, cond, 20)
  end
  while not cond() do
    vim.wait(200, cond, 20)
  end
  return true
end

local function close(tcp)  if tcp then
    pcall(function()
      tcp:close()
    end)
  end
end

--- 连上 + 握手。`on_ready(err, tcp, state)`：err 为 nil 表示成功（此时 `info` 已读过）。
local function handshake(cfg, on_ready)
  local host, port = M.endpoint(cfg)
  local tcp = vim.uv.new_tcp()
  local state = { buf = "", done = false, info = nil }

  local function fail(msg)
    if state.done then
      return
    end
    state.done = true
    close(tcp)
    on_ready(msg)
  end

  local function on_read(err, chunk)
    if state.done then
      return
    end
    if err then
      return fail("传输错误：" .. err)
    end
    if not chunk then
      return fail("server 断开了连接（握手阶段）")
    end
    state.buf = state.buf .. chunk
    local frames, rest = take_frames(state.buf)
    state.buf = rest
    for _, f in ipairs(frames) do
      if f.type == T.INFO then
        state.info = decode_json(f.json)
        state.done = true
        on_ready(nil, tcp, state)
        return
      elseif f.type == T.ERROR then
        local j = decode_json(f.json)
        return fail("server 拒绝：" .. ((j and (j.error or j.message)) or f.json or "unknown"))
      end
    end
  end

  -- ❗`read_start` 必须在 **connect 成功之后** 调：连接建立前 luv 会丢回调，
  -- 表现为「写出去有、读回来没有」→ 整条请求超时。
  tcp:connect(host, port, function(err)
    if err then
      return fail(string.format("连不上 %s:%d（%s）", host, port, err))
    end
    tcp:read_start(on_read)
    tcp:write(pack_frame(T.HANDSHAKE, 0, PROTO, nil, cfg.token or ""))
  end)
end

-- ---------------------------------------------------------------- 本地文件后端
-- 服务端在远程模式下把文件 I/O 交给**客户端**（也就是这边）：`open` / `data` /
-- `close` 是写向，`read_req` 是读向（必须回 `read_resp`）。路径从 `data` 段来
-- （`flags` = 0 读 / 1 写 / 2 追加），不解 JSON（与 C 客户端同口径）。
local function make_file_table()
  local files = {}   -- id -> { fh = file*, path = string }
  local api = { error_msg = nil }

  function api.open(id, flags, path)
    local mode = (flags == 1) and "wb" or (flags == 2) and "ab" or "rb"
    local fh, err = io.open(path, mode)
    if not fh then
      api.error_msg = api.error_msg or string.format("open_file 失败: %s (%s)", tostring(path), tostring(err))
      return false
    end
    files[id] = { fh = fh, path = path }
    return true
  end

  function api.write(id, data)
    local f = files[id]
    if f and f.fh then
      f.fh:write(data)
    end
  end

  function api.close(id)
    local f = files[id]
    if f and f.fh then
      pcall(function()
        f.fh:close()
      end)
    end
    files[id] = nil
  end

  --- 返回 data, resp_flags, pos?（seek/tell 用 pos）
  function api.read(id, op, whence, arg)
    local f = files[id]
    if not f or not f.fh then
      return nil, RESP_ERROR, nil
    end
    if op == 2 then   -- seek
      local w = (whence == 0) and "set" or (whence == 2) and "end" or "cur"
      local pos = f.fh:seek(w, arg or 0)
      return "", 0, pos
    elseif op == 3 then -- tell
      return "", 0, f.fh:seek()
    elseif op == 1 then -- line（服务端负责去掉行尾）
      local line = f.fh:read("*l")
      if not line then
        return "", RESP_EOF, nil
      end
      return line .. "\n", 0, nil
    end
    local n = (arg and arg > 0) and arg or 8192
    local data = f.fh:read(n)
    if not data then
      return "", RESP_EOF, nil
    end
    return data, 0, nil
  end

  function api.close_all()
    for id, f in pairs(files) do
      if f.fh then
        pcall(function()
          f.fh:close()
        end)
      end
      files[id] = nil
    end
  end

  return api
end

-- ---------------------------------------------------------------- 执行
--- 跑一段脚本。
---@param cfg table            含 host/port/token/sync_timeout_ms
---@param req table            { body = string, filename = string }
---@param handlers table|nil   { on_out = fun(which, data) }
---@param done fun(res)|nil    完成回调（异步，已 schedule 回主循环）
---@param opts table|nil       { sync = boolean, sync_timeout_ms = number }
---@return table|nil res
function M.run(cfg, req, handlers, done, opts)
  handlers = handlers or {}
  opts = opts or {}
  local outs, errs = {}, {}
  local files = make_file_table()
  local res = { ok = false, exit = -1, stdout = "", stderr = "", canceled = false, timed_out = false, truncated = false }
  local finished = false

  local function finish(errmsg, r)
    if finished then
      return
    end
    finished = true
    files.close_all()
    if errmsg then
      res.error = errmsg
      res.ok = false
      res.exit = res.exit or -1
    end
    if r then
      for k, v in pairs(r) do
        res[k] = v
      end
    end
    res.stdout = table.concat(outs)
    res.stderr = table.concat(errs)
    res.file_error = files.error_msg
    if done then
      -- ❗`done` 里会画结果 buffer / 塞 quickfix（nvim API）→ 必须跳出 fast event context
      vim.schedule(function()
        done(res)
      end)
    end
  end

  handshake(cfg, function(err, tcp, state)
    if err then
      return finish(err)
    end
    local function on_frames(frames)
      for _, f in ipairs(frames) do
        if f.type == T.OUT then
          local which = band(f.flags, 0x01)
          if handlers.on_out then
            handlers.on_out(which, f.data)
          end
          if which == 1 then
            errs[#errs + 1] = f.data
          else
            outs[#outs + 1] = f.data
          end
        elseif f.type == T.OPEN then
          local path = f.data:gsub("%z+$", "")
          local ok = files.open(f.id, f.flags, path)
          -- 服务端 `open_file` 会**等这个应答**：失败用 ERROR 位，成功回 0
          tcp:write(pack_frame(T.READ_RESP, ok and 0 or RESP_ERROR, f.id, nil, ""))
        elseif f.type == T.DATA then
          files.write(f.id, f.data)
        elseif f.type == T.CLOSE then
          files.close(f.id)
        elseif f.type == T.READ_REQ then
          local op = band(f.flags, 0x0F)
          local whence = band(rshift(f.flags, 4), 0x0F)
          local arg = 0
          if #f.data >= 4 then
            arg = read_u32le(f.data, 1) or 0
          end
          local data, rf, pos = files.read(f.id, op, whence, arg)
          if pos ~= nil then
            tcp:write(pack_frame(T.READ_RESP, 0, f.id, nil, u32le(pos) .. "\0\0\0\0"))
          else
            tcp:write(pack_frame(T.READ_RESP, rf or 0, f.id, nil, data or ""))
          end
        elseif f.type == T.RESULT then
          res.exit = (f.id >= 32768) and (f.id - 65536) or f.id
          res.ok = band(f.flags, RESULT_OK) ~= 0
          res.canceled = band(f.flags, RESULT_CANCELED) ~= 0
          res.timed_out = band(f.flags, RESULT_TIMED_OUT) ~= 0
          res.truncated = band(f.flags, RESULT_TRUNCATED) ~= 0
          res.result_json = f.json
          local j = decode_json(f.json)
          if type(j) == "table" then
            local e = j.error
            if e ~= nil and e ~= vim.NIL and e ~= "" then
              res.error = e
            end
            if type(j.elapsed_ms) == "number" then
              res.elapsed_ms = j.elapsed_ms
            end
          end
        elseif f.type == T.ERROR then
          local j = decode_json(f.json)
          res.error = (j and (j.error or j.message)) or f.json
        elseif f.type == T.END then
          close(tcp)
          return finish(nil)
        end
      end
    end

    tcp:read_start(function(rerr, chunk)
      if finished then
        return
      end
      if rerr then
        close(tcp)
        return finish("传输错误：" .. rerr)
      end
      if not chunk then
        close(tcp)
        return finish(res.error)
      end
      state.buf = state.buf .. chunk
      local frames, rest = take_frames(state.buf)
      state.buf = rest
      on_frames(frames)
    end)

    -- script 帧：`data` = 源码，`json` 段 = chunkname 原文（服务端加 `@` 前缀）
    tcp:write(pack_frame(T.SCRIPT, 0, 0, req.filename or "buffer.lua", req.body or ""))
  end)

  if opts.sync then
    wait_until(function()
      return finished
    end, opts.sync_timeout_ms or cfg.sync_timeout_ms)
    if not finished then
      finish("等待 server 响应超时")
    end
    return res
  end
  return nil
end

-- ---------------------------------------------------------------- 控制命令
--- 发一条控制命令（`cancel` / `kill` / `detach` / `health` / `version`）
---@param cfg table
---@param name string
---@param opts table|nil { sync_timeout_ms = number }
---@return table|nil reply  { type = "ack"|"info"|"error", applied = boolean, json = table }
function M.control(cfg, name, opts)
  opts = opts or {}
  local cmd = CMD[name]
  local reply = nil
  local finished = false

  -- ❗必须先声明再用（`handshake` 的回调是晚绑定的，但**词法**作用域在这里就定了）
  local function finish_wait()
    finished = true
  end

  handshake(cfg, function(err, tcp, state)
    if err then
      reply = { type = "error", applied = false, error = err }
      return finish_wait()
    end
    tcp:write(pack_frame(T.CONTROL, cmd or CMD.health, 0, nil, ""))
    tcp:read_start(function(rerr, chunk)
      if finished then
        return
      end
      if rerr or not chunk then
        close(tcp)
        return finish_wait()
      end
      state.buf = state.buf .. chunk
      local frames, rest = take_frames(state.buf)
      state.buf = rest
      for _, f in ipairs(frames) do
        if f.type == T.ACK then
          reply = { type = "ack", applied = band(f.flags, 0x01) ~= 0, json = decode_json(f.json) }
        elseif f.type == T.INFO then
          reply = { type = "info", applied = true, json = decode_json(f.json) }
        elseif f.type == T.ERROR then
          local j = decode_json(f.json)
          reply = { type = "error", applied = false, error = (j and j.error) or f.json }
        end
        if f.type == T.ACK or f.type == T.INFO or f.type == T.ERROR then
          close(tcp)
          return finish_wait()
        end
      end
    end)
  end)

  local wait_ms = tonumber(opts.sync_timeout_ms) or 0
  if wait_ms <= 0 then
    wait_ms = 5000   -- 控制命令很短；这里 0 当「用默认」，不是「永远等」
  end
  wait_until(function()
    return finished
  end, wait_ms)
  return reply or { type = "error", applied = false, error = "timeout" }
end

return M
