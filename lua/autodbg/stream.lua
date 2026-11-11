-- =============================================================================
-- nvim/lua/autodbg/stream.lua —— 流式 `/run`（帧 + chunked）的客户端
--
-- 来源：新写。为什么需要它：
--   · 老的 `/run` 是「跑完一次性回 JSON」，大块数据只能靠 `write_file` 的 `/effects`
--     往返（每块一次 HTTP），而**调试回调里不能 yield** → 只能攒在内存里；
--   · 流式模式下服务端把 `open_file()` 的 `f:write()` 直接写进 `/run` 的响应连接
--     （帧 + chunked），脚本线程不需要挂起、不落盘、内存恒定。
--
-- 帧布局（服务端 `src/scripting/lua/stream.hpp`）：
--   u8 type (1=open 2=data 3=close 4=out 5=result 6=error)
--   u8 flags（out 帧：0=stdout 1=stderr）
--   u16 id, u32 data_len, [json], [data]
--
-- 用法：`M.request(cfg, req, handlers, on_done)`；handlers 里把 data 帧写进本地文件，
--   result 帧给结果表（与旧的 JSON 响应同构），所以上层 `ui.build` 不用改。
-- =============================================================================

local M = {}

local uv = vim.uv or vim.loop

-- nvim 跑的是 LuaJIT：没有 `string.unpack`（5.3+）→ 自己读小端
local function le16(s, i)
  local a, b = s:byte(i, i + 1)
  return (a or 0) + (b or 0) * 256
end

local function le32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return (a or 0) + (b or 0) * 256 + (c or 0) * 65536 + (d or 0) * 16777216
end

function M.frame_type()
  return { open = 1, data = 2, close = 3, out = 4, result = 5, error = 6 }
end

--- 从 url 里取 host/port（默认 127.0.0.1:8642）
---@param url string
---@return string host, integer port
function M.split_url(url)
  local _, host, port = tostring(url or ""):match("^(%a[%w+.-]*)://([^/:]+):?(%d*)")
  if not host or host == "" then
    return "127.0.0.1", 8642
  end
  return host, (tonumber(port) and tonumber(port) > 0) and tonumber(port) or 8642
end

--- 发一个流式 /run 请求。
-- @param cfg   { url, token, token_header, timeout_ms }
-- @param req   { body = Lua 源码, filename = chunkname, format = "json"|"text" }
-- @param handlers { on_out(stream, data), on_open(id, json), on_data(id, data), on_close(id) }
--   ❗handlers 也在 fast event context 里跑：里面只做纯 Lua / io.open 的事，
--     任何 nvim API（notify/buffer/qflist…）都要自己 `vim.schedule`。
-- @param on_done(resp)  resp = { ok, status, frames, result(json), err }
--   已被 schedule 到主循环（可以直接调 nvim API）。
-- @return nil（异步）；`opts.sync` 时返回 resp（同步路径由调用方在主循环里自己处理）
function M.request(cfg, req, handlers, on_done, opts)
  opts = opts or {}
  handlers = handlers or {}

  local host, port = M.split_url(cfg.url)
  local body = req.body or ""
  local hdrs = {
    "POST /run HTTP/1.1",
    "Host: " .. host .. ":" .. port,
    "Content-Type: text/x-lua; charset=utf-8",
    "X-AutoDbg-Filename: " .. (req.filename or "buffer.lua"),
    "X-AutoDbg-Stream: 1",
    "Content-Length: " .. #body,
    "Connection: close",
  }
  if req.format == "text" then
    hdrs[#hdrs + 1] = "X-AutoDbg-Format: text"
  end
  if cfg.token and cfg.token ~= "" then
    hdrs[#hdrs + 1] = (cfg.token_header or "Authorization") .. ": Bearer " .. cfg.token
  end
  -- ❗不能把 nil 塞进表再 concat（中旬的空洞会让 concat 报错）→ 逐条 push
  local head = table.concat(hdrs, "\r\n") .. "\r\n\r\n"

  local state = {
    buf = "",
    phase = "headers", -- headers | size | data | done
    remain = 0,
    status = 0,
    frames = 0,
    result = nil,
    err = nil,
    finished = false,
  }
  local tcp = uv.new_tcp()
  local timer = nil

  local function finish(err)
    if state.finished then
      return
    end
    state.finished = true
    if timer then
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
    end
    pcall(function()
      tcp:read_stop()
    end)
    if not tcp:is_closing() then
      tcp:close()
    end
    state.err = state.err or err
    local resp = {
      ok = (state.err == nil) and state.status == 200 and (state.result ~= nil) and (state.result.ok == true),
      status = state.status,
      frames = state.frames,
      result = state.result,
      err = state.err,
    }
    if on_done then
      -- ❗这里在 uv 读回调（fast event context）：不能直接碰 nvim API（会报 E5560），
      --   统一 schedule 到主循环再交给调用方（顺序仍保证：schedule 是 FIFO）。
      vim.schedule(function()
        on_done(resp)
      end)
    end
  end

  -- 解析一个完整的 chunk（payload）
  local function on_chunk(payload)
    if #payload < 8 then
      return
    end
    local ty, flags = payload:byte(1), payload:byte(2)
    local id = le16(payload, 3)
    local dlen = le32(payload, 5)
    local jlen = #payload - 8 - dlen
    if jlen < 0 then
      return
    end
    local json = (jlen > 0) and payload:sub(9, 8 + jlen) or ""
    local data = (dlen > 0) and payload:sub(9 + jlen) or ""
    state.frames = state.frames + 1

    if ty == 1 and handlers.on_open then
      handlers.on_open(id, json)
    elseif ty == 2 and handlers.on_data then
      handlers.on_data(id, data)
    elseif ty == 3 and handlers.on_close then
      handlers.on_close(id)
    elseif ty == 4 and handlers.on_out then
      handlers.on_out((flags == 1) and 2 or 1, data)
    elseif ty == 5 then
      local okj, doc = pcall(vim.json.decode, json)
      state.result = (okj and type(doc) == "table") and doc or { ok = false, error = "bad result json" }
    elseif ty == 6 then
      local okj, doc = pcall(vim.json.decode, json)
      state.err = (okj and doc and doc.error) or "stream error"
    end
  end

  -- 喂缓冲区，按 chunked 状态机推进
  local function feed()
    while not state.finished do
      if state.phase == "headers" then
        local p = state.buf:find("\r\n\r\n", 1, true)
        if not p then
          return
        end
        local head_text = state.buf:sub(1, p - 1)
        state.buf = state.buf:sub(p + 4)
        state.status = tonumber(head_text:match("^HTTP/%d%.%d%s+(%d+)")) or 0
        if state.status ~= 200 then
          state.err = head_text:match("^HTTP/%d%.%d%s+%d+%s*(.*)") or ("status " .. state.status)
          return finish(state.err)
        end
        state.phase = "size"
      elseif state.phase == "size" then
        local p = state.buf:find("\r\n", 1, true)
        if not p then
          return
        end
        local hex = state.buf:sub(1, p - 1)
        state.buf = state.buf:sub(p + 2)
        state.remain = tonumber(hex, 16) or 0
        if state.remain == 0 then
          state.phase = "done"
          return finish(nil)
        end
        state.phase = "data"
      elseif state.phase == "data" then
        if #state.buf < state.remain + 2 then
          return
        end
        local payload = state.buf:sub(1, state.remain)
        state.buf = state.buf:sub(state.remain + 3) -- 丢掉尾部 CRLF
        state.phase = "size"
        on_chunk(payload)
      else
        return
      end
    end
  end

  tcp:connect(host, port, function(err)
    if err then
      return finish(err)
    end
    tcp:write(head .. body)
    tcp:read_start(function(rerr, data)
      if rerr then
        return finish(rerr)
      end
      if data then
        state.buf = state.buf .. data
        feed()
      else
        -- EOF：正常情况下 result 帧之后服务端会发终止块，这里兜一层
        finish(nil)
      end
    end)
  end)

  if cfg.timeout_ms and cfg.timeout_ms > 0 then
    timer = uv.new_timer()
    timer:start(cfg.timeout_ms, 0, function()
      state.err = state.err or ("timeout after " .. cfg.timeout_ms .. "ms")
      finish(state.err)
    end)
  end

  if opts.sync then
    vim.wait(opts.sync_timeout_ms or 120000, function()
      return state.finished
    end, 20)
    return {
      ok = (state.err == nil) and state.status == 200 and (state.result ~= nil) and (state.result.ok == true),
      status = state.status,
      frames = state.frames,
      result = state.result,
      err = state.err,
    }
  end
end

return M
