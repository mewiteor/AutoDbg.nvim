-- =============================================================================
-- nvim/lua/autodbg/init.lua —— neovim 客户端主入口
--
-- 用法（依赖为零，把本目录加到 runtimepath 即可）：
--   require("autodbg").setup({ url = "http://127.0.0.1:8642" })
--   :AutoDbgRun            " 当前 buffer 整段执行
--   :'<,'>AutoDbgRun       " 只执行选区
--   :AutoDbgCancel         " 取消正在跑的脚本
--   :AutoDbgHealth         " 看一眼 server 状态
--   :AutoDbgHeader         " 在 buffer 头部插入 `--!autodbg` 标记（含远程地址）
--   :AutoDbgLsp [on|off]   " 手动挂/摘 LuaLS 注解库
-- 结果：写到 scratch buffer（`exit/elapsed` + stdout + stderr），并把 `<file>:<line>:`
--   形式的错误行塞进 quickfix（`:copen` / `]q` 可直达脚本出错行）。
--
-- 远程地址有两层（后者覆盖前者）：
--   ① `setup{ url = ... }` / `token` / token_file / $AUTODBG_TOKEN —— 默认值；
--   ② 脚本头部的标记行（`--!autodbg url=http://host:port token=…`，见 modeline.lua）。
-- 与 server 的契约见 AGENTS.md §12：body = Lua 源码，`X-AutoDbg-Filename`
--   作为 chunkname（所以错误信息里带的是你的缓冲区文件名）。
-- =============================================================================

local effects = require("autodbg.effects")
local http = require("autodbg.http")
local modeline = require("autodbg.modeline")
local run_local = require("autodbg.local")
local stream = require("autodbg.stream")
local ui = require("autodbg.ui")

--- 已经提示过「标记的 exe 不存在」的 buffer（避免反复刷屏）
---@type table<string, boolean>
local warned_local = {}

local M = {}

M.config = {
  url = "http://127.0.0.1:8642",
  token = nil,          -- 显式 token；nil 时看 $AUTODBG_TOKEN / token_file
  token_header = "Authorization",
  token_file = nil,     -- 第一行作为 token
  curl = "curl",
  format = "json",      -- "json"（信息全）| "text"（只 stdout）
  timeout_ms = 0,       -- curl --max-time（毫秒，0 = 不设）
  sync_timeout_ms = 60000,
  open = "split",       -- "split" | "vsplit" | "float" | "none"
  focus = true,
  keymaps = {
    run = nil,          -- 例如 "<leader>dr"
    cancel = nil,       -- 例如 "<leader>dc"
  },
  -- 脚本头部的 `--!autodbg ...` 标记（远程地址 / LSP 开关的依据）
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
  -- 远程模式用**流式**响应（帧 + chunked）：`open_file`/`f:write` 才能边跑边写
  stream = true,
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
  cfg.url = modeline.merge_url(cfg.url, ml)
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

--- 把 server 的响应整理成统一结果表
local function nn(v)
  -- ❗`vim.json.decode` 把 JSON `null` 解成 `vim.NIL`（userdata，且为真值）——
  -- 不归一化的话 `"error": null` 会被当成「有错误」并在拼接时炸（S3 踩过）。
  if v == vim.NIL then
    return nil
  end
  return v
end

local function to_result(cfg, resp, extra)
  local res = {
    status = resp.status,
    elapsed_ms = nil,
    stdout = "",
    stderr = "",
    error = nil,
    -- 实际用的地址与**地址来源**（setup 默认值 / 脚本头部标记），失败分支也要带着它
    url = cfg.url,
    url_mode = (cfg.modeline_hit and "modeline" or "setup"),
  }

  if resp.err then
    res.ok = false
    res.exit = -1
    res.error = resp.err
    res.stderr = resp.body or ""
    return res
  end

  if cfg.format == "text" then
    res.ok = (resp.status == 200)
    res.exit = tonumber(resp.headers["x-autodbg-exit"] or "-1")
    res.stdout = resp.body or ""
    res.truncated = (resp.headers["x-autodbg-truncated"] == "1")
    res.canceled = (resp.headers["x-autodbg-canceled"] == "1")
    res.timed_out = (resp.headers["x-autodbg-timed-out"] == "1")
    return res
  end

  local decoded_ok, decoded = pcall(vim.json.decode, resp.body or "")
  if not decoded_ok or type(decoded) ~= "table" then
    -- server 返回的不是 JSON（多半是 4xx/5xx 的纯文本）
    res.ok = false
    res.exit = -1
    res.error = (resp.body or ""):sub(1, 2000)
    return res
  end

  res.ok = (resp.status == 200) and (decoded.ok == true) and ((decoded.exit or 0) == 0)
  res.exit = decoded.exit or -1
  res.elapsed_ms = nn(decoded.elapsed_ms)
  res.stdout = nn(decoded.stdout) or ""
  res.stderr = nn(decoded.stderr) or ""
  res.error = nn(decoded.error)
  res.truncated = decoded.truncated == true
  res.canceled = decoded.canceled == true
  res.timed_out = decoded.timed_out == true
  res.flavor = nn(decoded.flavor)
  res.variant = nn(decoded.variant)
  res.request_id = (decoded.server and nn(decoded.server.request_id)) or extra.request_id
  return res
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

  -- ---------------- 远程模式：流式（帧 + chunked） ----------------
  -- `open_file`/`f:write` 只有在流式请求里才能用（脚本线程直接写这条连接），
  -- 所以默认走流式；`setup{ stream = false }` 回退到老的一次性 JSON + /effects。
  if cfg.stream then
    local outs, errs = {}, {}
    local files = {}          -- id → { fh, path }
    local file_err = nil

    local handlers = {
      on_out = function(which, data)
        local t = (which == 2) and errs or outs
        t[#t + 1] = data
      end,
      on_open = function(id, json)
        local okj, doc = pcall(vim.json.decode, json or "")
        local path = okj and type(doc) == "table" and doc.path or nil
        local mode = (okj and type(doc) == "table" and doc.mode) or "wb"
        if type(mode) ~= "string" or mode == "" then
          mode = "wb"
        end
        if not mode:find("b", 1, true) then
          mode = mode .. "b"
        end
        local fh, e = path and io.open(path, mode) or nil, nil
        if not fh then
          file_err = file_err or ("open_file 失败: " .. tostring(path) .. " (" .. tostring(e) .. ")")
          -- ❗on_open 跑在 uv 回调（fast event context）里，`vim.notify` 也要 schedule
          local msg = "AutoDbg: " .. tostring(file_err)
          vim.schedule(function()
            vim.notify(msg, vim.log.levels.ERROR)
          end)
          files[id] = { failed = true }
        else
          files[id] = { fh = fh, path = path }
        end
      end,
      on_data = function(id, data)
        local f = files[id]
        if f and f.fh then
          f.fh:write(data)
        end
      end,
      on_close = function(id)
        local f = files[id]
        if f and f.fh then
          pcall(function()
            f.fh:close()
          end)
          f.fh = nil
        end
      end,
    }

    local function done(resp)
      -- 服务端没发 close 的句柄也收尾（否则客户端文件句柄泄漏）
      for _, f in pairs(files) do
        if f.fh then
          pcall(function()
            f.fh:close()
          end)
          f.fh = nil
        end
      end

      local r = (resp and resp.result) or {}
      local res = {
        status = resp and resp.status or 0,
        ok = resp ~= nil and resp.ok == true,
        exit = nn(r.exit) or -1,
        elapsed_ms = nn(r.elapsed_ms),
        stdout = table.concat(outs),
        stderr = table.concat(errs),
        -- ❗结果帧里的 JSON `null` 会被解成 vim.NIL（真值 userdata）→ 必须过 nn()
        error = (resp and resp.err) or nn(r.error),
        truncated = r.truncated == true,
        canceled = r.canceled == true,
        timed_out = r.timed_out == true,
        flavor = nn(r.flavor),
        variant = nn(r.variant),
        request_id = (type(r.server) == "table") and nn(r.server.request_id) or nil,
        url = cfg.url,
        url_mode = (cfg.modeline_hit and "modeline" or "setup"),
        mode = "remote",
        stream = true,
        frames = resp and resp.frames or 0,
        file_error = file_err,
      }
      return handle(res)
    end

    local req = { body = body, filename = file, format = cfg.format }
    local stream_cfg = { url = cfg.url, token = resolve_token(cfg), token_header = cfg.token_header, timeout_ms = cfg.timeout_ms }
    if opts.sync then
      local resp = stream.request(stream_cfg, req, handlers, nil, { sync = true, sync_timeout_ms = cfg.sync_timeout_ms })
      return done(resp)
    end
    stream.request(stream_cfg, req, handlers, done, {})
    return
  end

  -- ---------------- 远程模式：一次性 JSON + /effects（非流式） ----------------
  local headers = {
    ["Content-Type"] = "text/x-lua; charset=utf-8",
    ["X-AutoDbg-Filename"] = file,
  }
  if cfg.format == "text" then
    headers["X-AutoDbg-Format"] = "text"
  end

  local req_cfg = {
    url = cfg.url,
    token = resolve_token(cfg),
    token_header = cfg.token_header,
    curl = cfg.curl,
    timeout_ms = cfg.timeout_ms,
    sync_timeout_ms = cfg.sync_timeout_ms,
  }

  local function handle_remote(resp)
    local res = to_result(cfg, resp, {})
    res.mode = "remote"
    return handle(res)
  end
  local resp = http.request(req_cfg, {
    method = "POST",
    path = "/run",
    body = body,
    headers = headers,
    sync = opts.sync,
  }, opts.sync and nil or function(r)
    -- S7：脚本可能要求改/读**本机**文件 → server 会挂起，这里把效果做完再送回
    effects.resolve(req_cfg, r, function(final_resp)
      handle_remote(final_resp)
    end)
  end)

  if opts.sync then
    resp = effects.resolve_sync(req_cfg, resp)
    return handle_remote(resp)
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

--- 取消正在跑的那一次执行（本地模式 kill 进程；远程模式发 `/cancel`）
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
  local req_cfg = { url = cfg.url, token = resolve_token(cfg), token_header = cfg.token_header, curl = cfg.curl }
  local resp = http.request(req_cfg, { method = "POST", path = "/cancel", sync = opts.sync or true })
  local ok, decoded = pcall(vim.json.decode, resp.body or "")
  local accepted = ok and type(decoded) == "table" and decoded.accepted == true
  if opts.sync then
    return accepted
  end
  vim.notify(accepted and "AutoDbg: 已请求取消" or "AutoDbg: 当前没有正在执行的脚本", vim.log.levels.INFO)
end

--- 查看状态（本地模式报 exe/arch，远程模式打 `/health`；同样尊重当前 buffer 的标记）
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

  local req_cfg = { url = cfg.url, token = resolve_token(cfg), token_header = cfg.token_header, curl = cfg.curl }
  local resp = http.request(req_cfg, { method = "GET", path = "/health", sync = true })
  resp.url = cfg.url
  resp.mode = "remote"
  resp.url_mode = (cfg.modeline_hit and "modeline" or "setup")
  resp.fallback = why and why:match("^missing:") and why or nil
  if opts.sync then
    return resp
  end
  if resp.status == 200 then
    vim.notify(string.format("AutoDbg /health (%s): %s", cfg.url, resp.body or ""), vim.log.levels.INFO)
  else
    notify_err("health 失败（" .. tostring(cfg.url) .. "，status=" .. tostring(resp.status) .. "）")
  end
end

--- 当前 buffer 的标记（没标记返回 { found = false }）
---@param bufnr integer?
---@return table
function M.marker(bufnr)
  return modeline.from_buf(bufnr)
end

--- 在 buffer 头部插入 `--!autodbg` 标记（没 LuaSnip 也能用；已有标记就只提示）
-- opts.kind："remote"（默认，url=…）| "local"（exe=… arch=…）
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
    line = "--!autodbg url=" .. tostring(cfg.url)
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { line })
  vim.notify("AutoDbg: 已插入标记 " .. line, vim.log.levels.INFO)
  return true
end

return M
