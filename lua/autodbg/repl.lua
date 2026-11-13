-- =============================================================================
-- nvim/lua/autodbg/repl.lua —— `:AutoDbgRepl` 的会话层（plan_t7.md §12.3 ②）
--
-- 来源：新写（run 路径是「一次调用 = 一条连接 = 一次执行」，D43；REPL 是「一条连接活多久
--   算多久」——server 侧的 `lua_State` 与引擎会话跨命令存活，T7 D2b）。
--
-- 三条口径（照已拍板的形态）：
--   ① **只走远程**：连一条**已经在跑的** `--repl --server`（协议 2）。不 spawn 进程，也不
--     静默回落到本地 exe —— D39 的「本地优先」不适用于 REPL（README 里写清）。地址只有两个
--     来源：脚本头标记（`--!autodbg host=… port=…`）或 `setup{}`。
--   ② 归因（D2a）：每条命令一个 `script` 帧，`id` = 插件侧递增的命令号；`out` 帧的 `id` 就是
--     发起它的命令号 ⇒ 渲染按 `id` 归因；`result` 帧的 `id` 仍是**该行的 Lua 错误码**（0/2/3），
--     不是命令号。`event` 帧（16）在 run 路径是「认并忽略」，这里要渲染。
--   ③ 每轮渲染顺序：`> <输入行>` 回显 → `out`（带 `cmd=<id>`）→ `event` 一行摘要 → `result`。
--
-- 已知限制（不是 bug，写在这里免得下次再踩）：
--   · `open_file` 在 REPL 里不可用：`open` / `read_req` 需要客户端应答，本层不接（D45 的阻塞读
--     只属于 run 路径的 `tcp.lua`）——REPL 里调它会等到 `read_timeout_ms` 超时。
--   · server 的执行连接 **2 s 空闲就关**（`tcp_server.cpp` 的 `k_conn_idle_ms`）⇒ 交互式 REPL
--     两行之间不能超过 2 s；没有客户端保活，也没有 `--server-idle` 可调。
--   · 握手 `info` 里没有「是不是 REPL」的字段 ⇒ 连到非 `--repl` 的 server 时跨命令 state 不成立。
-- ❗uv 回调是 fast event context：本层的回调只填普通 Lua 表，一切 nvim API 都在 `vim.schedule`
--   里（PITFALLS N12）。只用 LuaJIT 语法（没有 `string.pack` / 位运算符；位运算走 `bit`）。
-- =============================================================================

local tcp = require("autodbg.tcp")
local ui = require("autodbg.ui")

local M = {}

local T = tcp.T
local band = bit.band

local DEFAULT_BUFFER = "autodbg:repl"

local state = {
  conn = nil, -- { cfg, tcp, raw, buf, cmd, closed, on_frame, on_close }
  lines = {}, -- 追加式的渲染历史（REPL 是「一轮一轮往上加」，不是每次重写）
  marks = {},
}

local function repl_cfg(cfg)
  return (cfg and cfg.repl) or {}
end

local function split_lines(s)
  local out = {}
  if type(s) ~= "string" or s == "" then
    return out
  end
  for line in (s .. "\n"):gmatch("(.-)\n") do
    out[#out + 1] = line
  end
  return out
end

local function push(line, hl)
  state.lines[#state.lines + 1] = line
  if hl then
    state.marks[#state.marks + 1] = { line = #state.lines - 1, hl = hl }
  end
end

local function draw(conn, how)
  ui.render(state.lines, state.marks, how, repl_cfg(conn.cfg).buffer or DEFAULT_BUFFER)
end

--- 一轮的渲染顺序（③）：回显 → out（带 cmd）→ event 摘要 → result
local function render_round(conn, res)
  push("> " .. res.line, "Title")

  for _, o in ipairs(res.outs) do
    local tag = (o.which == 1) and "err" or "out"
    for _, line in ipairs(split_lines(o.data)) do
      push(string.format("[%s cmd=%d] %s", tag, o.id, line), o.which == 1 and "DiagnosticWarn" or nil)
    end
  end

  if res.error then
    push("[error] " .. tostring(res.error), "DiagnosticError")
  end

  if repl_cfg(conn.cfg).event_summary then
    for _, e in ipairs(res.events) do
      push(string.format("[event] cmd=%d type=%s pid=%s tid=%s rva=%s",
        e.id, tostring(e.type), tostring(e.pid), tostring(e.tid), tostring(e.rva)), "DiagnosticInfo")
    end
  end

  push(string.format("[result] cmd=%d exit=%s", res.cmd, tostring(res.code)), "Comment")
  draw(conn)
end

--- 读 handler 装在连接上（整条连接一次），帧交给「当前那条命令」的 res
local function install_read(conn)
  conn.tcp:read_start(function(err, chunk)
    if conn.closed then
      return
    end
    if err then
      conn.closed = true
      if conn.on_close then
        conn.on_close("传输错误：" .. err)
      end
      return
    end
    if not chunk then
      conn.closed = true
      if conn.on_close then
        conn.on_close("server 关掉了这条连接")
      end
      return
    end
    conn.raw = conn.raw .. chunk
    local frames, rest = tcp.take_frames(conn.raw)
    conn.raw = rest
    for _, f in ipairs(frames) do
      if conn.on_frame then
        conn.on_frame(f)
      end
    end
  end)
end

--- 连一条已经在跑的 `--repl --server`（只走远程：调用方负责「没有地址就报错」）
---@param cfg table            host/port/url/token + sync_timeout_ms + repl = { ... }
---@param opts table|nil       { sync = boolean, sync_timeout_ms = number, on_open = fun(res) }
---@return table|nil res       { ok, mode, host, port, buf, cmd, info, error }
function M.open(cfg, opts)
  opts = opts or {}
  local rcfg = repl_cfg(cfg)
  local host, port = tcp.endpoint(cfg)
  local res = { ok = false, mode = "remote", host = host, port = port, buf = nil, cmd = 0 }
  local conn = { cfg = cfg, cmd = 0, closed = false, raw = "" }
  local done = false

  local function deliver(errmsg)
    if done then
      return
    end
    if errmsg then
      res.error = errmsg
    end
    done = true
    if opts.on_open then
      opts.on_open(res)
    end
  end

  tcp.handshake(cfg, function(err, t, hst)
    -- ❗fast event context：建 buffer / 开窗口都要跳到主上下文
    vim.schedule(function()
      if err then
        return deliver(err)
      end
      conn.tcp, conn.raw = t, (hst.buf or "")   -- 握手读可能多读到半截帧，接着用
      conn.buf = ui.ensure_buf(rcfg.buffer or DEFAULT_BUFFER)
      res.buf, res.cmd, res.info = conn.buf, 0, hst.info
      res.ok = true
      state.conn = conn
      install_read(conn)
      draw(conn, (cfg.open ~= "none") and cfg.open or nil)
      deliver(nil)
    end)
  end)

  if opts.sync then
    tcp.wait_until(function()
      return done
    end, tonumber(opts.sync_timeout_ms) or tonumber(rcfg.read_timeout_ms) or 0)
    if not done then
      res.error = res.error or "等握手超时（REPL 的 `read_timeout_ms`）"
    end
    return res
  end
  return nil
end

--- 跑一行（或一个完整块）：一条 `script` 帧，`id` = 插件侧递增的命令号。
--- `opts.sync` 默认 true（REPL 天然是请求/应答；headless 里 `input()` 不可用，门禁靠这条）。
---@param line string
---@param opts table|nil       { sync = boolean, sync_timeout_ms = number, on_line = fun(res) }
---@return table|nil res        { cmd, line, ok, code, out, err, outs, events, error }
---@return string? err           只有「没有打开的连接 / 连接已断」时才走第二个返回值
function M.eval(line, opts)
  opts = opts or {}
  local conn = state.conn
  if not conn then
    return nil, "REPL 没有打开的连接（先 repl_open）"
  end
  if conn.closed then
    return nil, "REPL 的连接已经断了（server 空闲 2 s 就会关）"
  end

  local rcfg = repl_cfg(conn.cfg)
  local text = vim.trim(tostring(line or ""))

  conn.cmd = conn.cmd + 1
  local cmd = conn.cmd
  local res = {
    cmd = cmd,
    line = text,
    ok = false,
    code = nil,
    out = "",
    err = "",
    outs = {},
    events = {},
    error = nil,
  }
  local delivered = false
  local done = false

  local function finish(errmsg)
    if delivered then
      return
    end
    delivered = true
    if errmsg and (res.error == nil or res.error == "") then
      res.error = errmsg
    end
    -- ❗fast event context：渲染与回调都跳到下一个轮次
    vim.schedule(function()
      render_round(conn, res)
      done = true
      if opts.on_line then
        opts.on_line(res)
      end
    end)
  end

  conn.on_frame = function(f)
    if f.type == T.OUT then
      if f.id ~= cmd then
        return -- 归因不到本命令（迟到的帧）：丢弃，与 C 客户端丢 stale read_resp 同口径
      end
      local which = band(f.flags, 0x01)
      res.outs[#res.outs + 1] = { id = f.id, which = which, data = f.data or "" }
      if which == 1 then
        res.err = res.err .. (f.data or "")
      else
        res.out = res.out .. (f.data or "")
      end
    elseif f.type == T.EVENT then
      if f.id ~= cmd then
        return
      end
      local j = tcp.decode_json(f.json)
      if type(j) == "table" then
        res.events[#res.events + 1] = { id = f.id, type = j.type, pid = j.pid, tid = j.tid, rva = j.rva }
      end
    elseif f.type == T.RESULT then
      -- `result` 的 `id` 是这一行的 Lua 错误码（不是命令号）：与 `tcp.run` 同口径，u16 二补数
      res.code = (f.id >= 32768) and (f.id - 65536) or f.id
      local j = tcp.decode_json(f.json)
      if type(j) == "table" then
        res.ok = j.ok == true
        if j.error ~= nil and j.error ~= vim.NIL and j.error ~= "" then
          res.error = j.error
        end
      end
    elseif f.type == T.ERROR then
      local j = tcp.decode_json(f.json)
      res.error = (j and (j.error or j.message)) or f.json
    elseif f.type == T.END then
      finish(nil)
    end
  end
  conn.on_close = function(msg)
    finish(msg)
  end

  conn.tcp:write(tcp.pack_frame(T.SCRIPT, 0, cmd, nil, text))

  if opts.sync == false then
    return nil
  end

  tcp.wait_until(function()
    return done
  end, tonumber(opts.sync_timeout_ms) or tonumber(rcfg.read_timeout_ms) or 0)
  if not done and not delivered then
    res.error = "等 server 回包超时（REPL 的 `read_timeout_ms`）"
    delivered = true
    render_round(conn, res) -- 这里是主上下文，不必再走 vim.schedule
  end
  return res
end

--- 关掉这条 REPL 连接（server 侧随之 `repl_server_end`：未关的会话按归属收尾）。
--- buffer 与渲染历史留着（REPL 的历史比连接值钱）。
---@return table|nil res
---@return string? err
function M.close()
  local conn = state.conn
  if not conn then
    return nil, "REPL 没有打开的连接"
  end
  conn.closed = true
  conn.on_frame, conn.on_close = nil, nil
  pcall(function()
    conn.tcp:close()
  end)
  state.conn = nil
  return { ok = true, cmd = conn.cmd, buf = conn.buf }
end

--- `:AutoDbgRepl` 的交互外壳：`vim.fn.input()` 循环。headless 明确报错（不 hang）。
---@param cfg table
---@param opts table|nil
---@return table|nil res
---@return string? err
function M.shell(cfg, opts)
  opts = opts or {}
  if #vim.api.nvim_list_uis() == 0 then
    return nil, "REPL 的交互外壳需要真 TUI（headless 请用 repl_open / repl_eval / repl_close）"
  end

  local res = M.open(cfg, { sync = true })
  if not res.ok then
    return nil, res.error
  end

  while state.conn and not state.conn.closed do
    local line = vim.fn.input("> ")
    if line == nil then
      break -- Ctrl-C / Esc：结束会话（不发明退出命令）
    end
    M.eval(line, { sync = true })
  end

  M.close()
  return res
end

return M
