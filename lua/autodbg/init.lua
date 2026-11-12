-- =============================================================================
-- nvim/lua/autodbg/init.lua —— neovim 客户端主入口
--
-- 用法（依赖为零，把本目录加到 runtimepath 即可）：
--   require("autodbg").setup({ host = "127.0.0.1", port = 8642 })
--   :AutoDbgRun            " 当前 buffer 整段执行
--   :'<,'>AutoDbgRun       " 只执行选区
--   :AutoDbgCancel         " 取消正在跑的脚本（硬）
--   :AutoDbgKill           " 只结束当前 Attach/Run（软），脚本继续
--   :AutoDbgDetach         " 真 detach：目标继续活着（NT+）
--   :AutoDbgHealth         " 看一眼 server 状态
--   :AutoDbgVersion        " 查 server 版本 / ABI
--   :AutoDbgHeader         " 在 buffer 头部插入 `--!autodbg` 标记
--   :AutoDbgLsp [on|off]   " 手动挂/摘 LuaLS 注解库
-- 结果：写到 scratch buffer，并把 `<file>:<line>:` 形式的错误行塞进 quickfix。
--
-- 传输：**raw TCP 帧**（`lua/autodbg/tcp.lua`）；HTTP / effects / chunked 已删除。
-- 地址有两层（后者覆盖前者）：
--   ① `setup{ host/port/url/token }` / `token_file` / `$AUTODBG_TOKEN` —— 默认值；
--   ② 脚本头部的标记行（`--!autodbg host=… port=… token=… pid=…`，见 modeline.lua）。
-- =============================================================================

local modeline = require("autodbg.modeline")
local run_local = require("autodbg.local")
local tcp = require("autodbg.tcp")
local ui = require("autodbg.ui")

--- 已经提示过「标记的 exe 不存在」的 buffer（避免反复刷屏）
---@type table<string, boolean>
local warned_local = {}

local M = {}

M.config = {
  -- ❗默认地址**不写在这里**：留在 nil，让 `modeline` / `url` 有机会生效；
  -- 真正的缺省值由 `tcp.endpoint()` 补（127.0.0.1:8642）。
  host = nil,
  port = nil,
  url = nil,            -- 兼容旧配置：`url = "http://h:p"` / `"tcp://h:p"` / `"h:p"` 都会拆成 host/port
  token = nil,          -- 显式 token；nil 时看 $AUTODBG_TOKEN / token_file
  token_file = nil,     -- 第一行作为 token
  timeout_ms = 0,       -- 本地模式：子进程上限（远程模式忽略）
  sync_timeout_ms = 0,  -- 远程模式「等结果」上限（0 = 一直等）
  read_timeout_ms = 5000,  -- 一次文件操作（服务端等客户端回包）的上限
  open = "split",       -- "split" | "vsplit" | "float" | "none"
  focus = true,
  keymaps = {
    run = nil,          -- 例如 "<leader>dr"
    cancel = nil,       -- 例如 "<leader>dc"
  },
  -- 脚本头部的 `--!autodbg ...` 标记（地址 / token / pid / LSP 开关的依据）
  modeline = {
    enable = true,
    head = 5,           -- 看前 N 行
    tail = 5,           -- 看后 N 行（与 vim 的 modeline 同口径）
  },
  -- 运行模式："auto"（有 exe 就本地，否则远程）| "local"（必须本地）| "remote"（强制远程）
  mode = "auto",
  -- AutoDbg 的 exe（本地模式）；nil = 去 PATH 里找 exe_names
  exe = nil,
  exe_names = nil,      -- 默认 { "AutoDbg_64.exe", "AutoDbg_86.exe", "AutoDbg.exe", "autodbg.exe" }
  local_flags = { "--quiet" },  -- 本地模式的固定参数（--quiet 关错误弹窗，免 headless 被 MessageBox 挂住）
  -- 把 LuaLS 注解库挂到 lua_ls（取代 AutoDbg 模块的 generate_templete）
  lsp = {
    enable = true,
    arch = nil,            -- "x86" | "x64"；nil = 跟着脚本标记，再缺省 x64
    runtime_version = nil, -- 例如 "Lua 5.5" / "LuaJIT"；nil = 不改 LuaLS 的既有设置
  },
  -- LuaSnip 片段（检测不到 LuaSnip 时安静跳过）
  snippets = {
    enable = true,
  },
}

local function merged(over)
  local cfg = vim.deepcopy(M.config)
  for k, v in pairs(over or {}) do
    if type(v) == "table" and type(cfg[k]) == "table" then
      cfg[k] = vim.tbl_deep_extend("force", cfg[k], v)
    else
      cfg[k] = v
    end
  end
  return cfg
end

local function resolve_token(cfg)
  if cfg.token and cfg.token ~= "" then
    return cfg.token
  end
  local env = os.getenv("AUTODBG_TOKEN")
  if env and env ~= "" then
    return env
  end
  if cfg.token_file then
    local f = io.open(cfg.token_file, "r")
    if f then
      local line = f:read("*l")
      f:close()
      if line and line ~= "" then
        return line
      end
    end
  end
  return nil
end

function M.setup(opts)
  M.config = merged(opts)

  local km = M.config.keymaps or {}
  if km.run then
    vim.keymap.set("n", km.run, "<cmd>AutoDbgRun<cr>", { desc = "AutoDbg: run buffer" })
    vim.keymap.set("v", km.run, ":AutoDbgRun<cr>", { desc = "AutoDbg: run selection" })
  end
  if km.cancel then
    vim.keymap.set("n", km.cancel, "<cmd>AutoDbgCancel<cr>", { desc = "AutoDbg: cancel" })
  end

  local sn = M.config.snippets or {}
  if sn.enable then
    -- LuaSnip 不在就安静跳过（不报错、不提醒）
    require("autodbg.snippets").add("lua")
  end

  return M.config
end

--- 把脚本头部的 modeline 叠到 setup 的默认配置上（url/token）
---@param over table? 调用点传入的覆盖
---@param bufnr integer?
---@return table cfg, table? ml
local function effective(over, bufnr)
  local cfg = merged(over)
  local mlcfg = cfg.modeline or {}
  if mlcfg.enable == false then
    return cfg, nil
  end
  local ml = modeline.from_buf(bufnr, { head = mlcfg.head, tail = mlcfg.tail })
  if not ml.found then
    return cfg, nil
  end
  -- 标记里的地址 **优先于** setup 的默认值：`url=` / `host=` / `port=` 任一出现就算「指定过地址」，
  -- 先把 setup 那层的 host/port 清掉（否则 setup 里的 127.0.0.1 会把 modeline 的 url 盖住）。
  if (ml.url and ml.url ~= "") or ml.host or ml.port then
    cfg.host, cfg.port = nil, nil
  end
  cfg.url = modeline.merge_url(cfg.url, ml)
  if ml.host and ml.host ~= "" then
    cfg.host = ml.host
  end
  if ml.port and tonumber(ml.port) then
    cfg.port = tonumber(ml.port)
  end
  if ml.pid and tonumber(ml.pid) then
    cfg.pid = tonumber(ml.pid)
  end
  if ml.token and ml.token ~= "" then
    cfg.token = ml.token
  end
  if ml.exe and ml.exe ~= "" then
    cfg.exe = ml.exe
  end
  if ml.arch then
    cfg.arch = modeline.normalize_arch(ml.arch) or ml.arch
  end
  cfg.modeline_hit = ml
  return cfg, ml
end

local function buf_script(range)
  local bufnr = vim.api.nvim_get_current_buf()
  local first, last
  if range then
    first, last = range[1] - 1, range[2]
  else
    first, last = 0, -1
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, first, last, false)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    name = "buffer.lua"
  else
    name = vim.fn.fnamemodify(name, ":t")
  end
  if name:sub(-4) ~= ".lua" then
    name = name .. ".lua"
  end
  return table.concat(lines, "\n") .. "\n", name
end

local function notify_err(msg)
  vim.notify("AutoDbg: " .. msg, vim.log.levels.ERROR)
end

local function show(cfg, res, file)
  local lines, marks = ui.build(res)
  res.result_buf = ui.render(lines, marks, cfg.open ~= "none" and cfg.open or nil)
  res.qf_count = ui.set_quickfix((res.stderr or "") .. "\n" .. (res.error or ""), file)

  if res.status == 401 then
    notify_err("需要 token（--server-token 或 loopback 免 token）")
  elseif res.status == 503 then
    notify_err("server 忙（执行队列满），稍后重试")
  elseif res.status == 0 then
    notify_err("连接失败：" .. tostring(res.error))
  end
end

--- 执行当前 buffer（或选区）。
-- opts: { range = {first,last}, sync = false, open = "split"|"vsplit"|"float"|"none", on_done = fn(res) }
-- 远程地址 / token 的优先级：配置传入的 > 脚本头部的 `--!autodbg` 标记 > setup 默认值
function M.run(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local cfg = effective(opts.cfg, bufnr)
  local body, file = buf_script(opts.range)
  local mode, exe, why = M.resolve_mode(cfg)

  local function handle(res)
    if opts.open ~= "none" and cfg.open ~= "none" then
      show(cfg, res, file)
    end
    if opts.on_done then
      opts.on_done(res)
    end
    return opts.sync and res or nil
  end

  -- ---------------- 本地模式：直接跑 exe ----------------
  if mode == "local" then
    if not exe then
      local res = {
        ok = false,
        exit = -1,
        stdout = "",
        stderr = "",
        error = "找不到 AutoDbg 的 exe（" .. tostring(why) .. "）；用 `exe=` 标记或 setup{ exe = … } 指定",
        mode = "local",
      }
      notify_err(res.error)
      return handle(res)
    end
    if why and why:match("^missing:") then
      -- 标记里给了 exe 但那个文件不存在 → 已回退远程模式，提示一次即可
      local missing = why:sub(#"missing:" + 1)
      local key = bufnr .. ":" .. missing
      if not warned_local[key] then
        warned_local[key] = true
        vim.notify("AutoDbg: 找不到 exe " .. missing .. "，已回退远程模式 " .. cfg.url, vim.log.levels.WARN)
      end
    end
  end

  if mode == "local" and exe then
    local real = vim.api.nvim_buf_get_name(bufnr)
    local cwd = nil
    if real ~= "" then
      cwd = vim.fn.fnamemodify(real, ":p:h")
    end
    return run_local.run({
      exe = exe,
      body = body,
      filename = file,
      real_path = real ~= "" and vim.fn.fnamemodify(real, ":p") or nil,
      args = opts.args,
      cwd = cwd,
      flags = cfg.local_flags,
      timeout_ms = cfg.timeout_ms,
      sync = opts.sync,
      on_done = function(res)
        res.mode = "local"
        res.url_mode = cfg.modeline_hit and "modeline" or "setup"
        res.arch = res.arch or cfg.arch
        handle(res)
      end,
    })
  end

  -- ---------------- 远程模式：raw TCP 帧（T5：HTTP/effects/chunked 已删） ----------------
  -- 一次调用 = 一条连接：握手 → `script` 帧 → `out` / `open`+`data`+`close` /
  -- `read_req`（tcp.lua 回 `read_resp`）→ `result` + `end`。文件 I/O 在**本机**。
  local function done_remote(r)
    r = r or { ok = false, exit = -1, error = "no response" }
    r.mode = "remote"
    r.url = cfg.url
    r.url_mode = (cfg.modeline_hit and "modeline" or "setup")
    r.host, r.port = tcp.endpoint(cfg)
    return handle(r)
  end

  local rr = tcp.run(cfg, { body = body, filename = file }, {}, opts.sync and nil or done_remote,
    { sync = opts.sync, sync_timeout_ms = cfg.sync_timeout_ms })
  if opts.sync then
    return done_remote(rr)
  end
end

--- 定运行模式：能拿到 exe → 本地；否则 → 远程
-- 优先级：脚本标记 exe= > setup.exe > PATH 里的 AutoDbg_*.exe
-- `setup{ mode = "remote" }` 可强制远程（不找 exe）；`mode = "local"` 表示「必须本地」。
---@param cfg table
---@return string mode "local" | "remote"
---@return string? exe
---@return string? why "modeline"|"config"|"PATH"|"missing:<path>"|"no-exe"|"forced"
function M.resolve_mode(cfg)
  local want = cfg.mode or "auto"
  if want == "remote" then
    return "remote", nil, "forced"
  end
  local exe, source, missing = run_local.resolve(cfg)
  if exe then
    return "local", exe, source
  end
  if want == "local" then
    -- 强制本地：不静默回落，直接报缺 exe（缺哪条路径也说清楚）
    return "local", nil, missing and ("missing:" .. missing) or "no-exe"
  end
  if missing then
    return "remote", nil, "missing:" .. missing
  end
  return "remote", nil, "no-exe"
end

--- 取消正在跑的那一次执行（本地模式 kill 进程；远程模式发 `control` 的 cancel）
function M.cancel(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local cfg = effective(opts.cfg, bufnr)
  local mode = M.resolve_mode(cfg)
  if mode == "local" then
    local killed = run_local.cancel()
    if opts.sync then
      return killed
    end
    vim.notify(killed and "AutoDbg: 已终止本地进程" or "AutoDbg: 当前没有在跑的本地进程", vim.log.levels.INFO)
    return
  end
  local reply = tcp.control(cfg, "cancel", { sync_timeout_ms = cfg.sync_timeout_ms })
  local accepted = reply ~= nil and reply.applied == true
  if opts.sync then
    return accepted
  end
  local why = reply and reply.json and reply.json.reason or nil
  vim.notify(accepted and "AutoDbg: 已请求取消" or ("AutoDbg: 当前没有正在执行的脚本（" .. tostring(why) .. "）"), vim.log.levels.INFO)
end

--- 软动作：只结束**当前** `Attach`/`Run`，脚本继续跑
local function soft_action(kind, opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local cfg = effective(opts.cfg, bufnr)
  if M.resolve_mode(cfg) == "local" then
    local killed = run_local.cancel()
    if opts.sync then
      return killed
    end
    vim.notify(killed and "AutoDbg: 已终止本地进程" or "AutoDbg: 当前没有在跑的本地进程", vim.log.levels.INFO)
    return
  end
  local reply = tcp.control(cfg, kind, { sync_timeout_ms = cfg.sync_timeout_ms })
  local applied = reply ~= nil and reply.applied == true
  if opts.sync then
    return applied
  end
  local why = reply and reply.json and reply.json.reason or nil
  vim.notify(string.format("AutoDbg --%s: %s（%s）", kind, applied and "已生效" or "未生效", tostring(why)), vim.log.levels.INFO)
end

--- 只结束当前的 `Attach`/`Run`（我们启动的目标会被终止），脚本继续
function M.kill(opts)
  return soft_action("kill", opts)
end

--- 真 detach：目标存活、pid 不变（NT+；Win9x 降级成 kill）
function M.detach(opts)
  return soft_action("detach", opts)
end

--- 查看状态（本地模式报 exe/arch，远程模式问 server）
function M.health(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local cfg = effective(opts.cfg, bufnr)
  local mode, exe, why = M.resolve_mode(cfg)

  if mode == "local" then
    local arch = cfg.arch or require("autodbg.lsp").resolve_arch(bufnr, cfg)
    local info = string.format("mode=local  exe=%s  arch=%s  (%s)", tostring(exe), tostring(arch), tostring(why))
    local res = { ok = exe ~= nil, status = 200, body = info, mode = exe and "local" or "setup", url = nil, exe = exe, arch = arch }
    if opts.sync then
      return res
    end
    vim.notify("AutoDbg " .. info, vim.log.levels.INFO)
    return res
  end

  local reply = tcp.control(cfg, "health", { sync_timeout_ms = cfg.sync_timeout_ms })
  local host, port = tcp.endpoint(cfg)
  local res = {
    ok = reply ~= nil and reply.type == "info",
    status = (reply and reply.type == "error") and 0 or 200,
    body = reply and reply.json and vim.json.encode(reply.json) or (reply and reply.error) or "",
    info = reply and reply.json or nil,
    mode = "remote",
    host = host,
    port = port,
    url = cfg.url,
    url_mode = (cfg.modeline_hit and "modeline" or "setup"),
    fallback = why and why:match("^missing:") and why or nil,
  }
  if opts.sync then
    return res
  end
  if res.ok then
    local j = res.info or {}
    vim.notify(string.format("AutoDbg %s:%d（proto=%s busy=%s）", host, port, tostring(j.proto), tostring(j.busy)), vim.log.levels.INFO)
  else
    notify_err("health 失败（" .. host .. ":" .. port .. "）：" .. tostring(res.body))
  end
end

--- 查 server 版本 / ABI（远程模式）
function M.version(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local cfg = effective(opts.cfg, bufnr)
  local reply = tcp.control(cfg, "version", { sync_timeout_ms = cfg.sync_timeout_ms })
  local res = {
    ok = reply ~= nil and reply.type == "info",
    info = reply and reply.json or nil,
    error = reply and reply.error or nil,
    mode = "remote",
  }
  if opts.sync then
    return res
  end
  if res.ok then
    local j = res.info or {}
    vim.notify(string.format("AutoDbg server %s（abi %s, %s, %s/%s）", tostring(j.version), tostring(j.abi),
      tostring(j.arch), tostring(j.flavor), tostring(j.variant)), vim.log.levels.INFO)
  else
    notify_err("version 失败：" .. tostring(res.error))
  end
  return res
end

--- 当前 buffer 的标记（没标记返回 { found = false }）
---@param bufnr integer?
---@return table
function M.marker(bufnr)
  return modeline.from_buf(bufnr)
end

--- 在 buffer 头部插入 `--!autodbg` 标记（没 LuaSnip 也能用；已有标记就只提示）
-- opts.kind："remote"（默认，host=… port=…）| "local"（exe=… arch=…）
---@param opts? { bufnr: integer?, force: boolean?, kind: string? }
---@return boolean ok
function M.insert_header(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  if not opts.force and modeline.is_autodbg_buf(bufnr) then
    vim.notify("AutoDbg: 这个 buffer 已经有标记了", vim.log.levels.INFO)
    return false
  end
  local cfg = merged(opts.cfg)
  local line
  if (opts.kind or "remote") == "local" then
    local exe = run_local.expand(cfg.exe) or run_local.find_in_path(cfg.exe_names)
    local arch = cfg.arch or run_local.arch_of_exe(exe) or "x64"
    if exe then
      line = string.format("--!autodbg exe=%s arch=%s", exe, arch)
    else
      -- 找不到 exe 时不写半截路径（写了也会因 filereadable 失败而回落远程）
      line = string.format("--!autodbg arch=%s", arch)
      vim.notify("AutoDbg: PATH 里没找到 AutoDbg 的 exe；标记里只写了 arch（请自己补 exe=…）", vim.log.levels.WARN)
    end
  else
    local host, port = tcp.endpoint(cfg)
    line = string.format("--!autodbg host=%s port=%d", host, port)
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { line })
  vim.notify("AutoDbg: 已插入标记 " .. line, vim.log.levels.INFO)
  return true
end

return M
