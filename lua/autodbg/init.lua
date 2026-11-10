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
local ui = require("autodbg.ui")

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
  -- 把 LuaLS 注解库挂到 lua_ls（取代 AutoDbg 模块的 generate_templete）
  lsp = {
    enable = true,
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
    -- 实际用的地址与来源（setup 默认值 / 脚本头部标记），失败分支也要带着它
    url = cfg.url,
    mode = (cfg.modeline_hit and "modeline" or "setup"),
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
  local cfg = effective(opts.cfg, vim.api.nvim_get_current_buf())
  local body, file = buf_script(opts.range)

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

  local function handle(resp)
    local res = to_result(cfg, resp, {})
    if opts.open ~= "none" and cfg.open ~= "none" then
      show(cfg, res, file)
    end
    if opts.on_done then
      opts.on_done(res)
    end
    if opts.sync then
      return res
    end
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
      handle(final_resp)
    end)
  end)

  if opts.sync then
    resp = effects.resolve_sync(req_cfg, resp)
    return handle(resp)
  end
end

--- 取消正在跑的那一次执行（默认发到当前 buffer 头部标记里的 server）
function M.cancel(opts)
  opts = opts or {}
  local cfg = effective(opts.cfg, vim.api.nvim_get_current_buf())
  local req_cfg = { url = cfg.url, token = resolve_token(cfg), token_header = cfg.token_header, curl = cfg.curl }
  local resp = http.request(req_cfg, { method = "POST", path = "/cancel", sync = opts.sync or true })
  local ok, decoded = pcall(vim.json.decode, resp.body or "")
  local accepted = ok and type(decoded) == "table" and decoded.accepted == true
  if opts.sync then
    return accepted
  end
  vim.notify(accepted and "AutoDbg: 已请求取消" or "AutoDbg: 当前没有正在执行的脚本", vim.log.levels.INFO)
end

--- 查看 server 状态（同样尊重当前 buffer 的标记）
function M.health(opts)
  opts = opts or {}
  local cfg = effective(opts.cfg, vim.api.nvim_get_current_buf())
  local req_cfg = { url = cfg.url, token = resolve_token(cfg), token_header = cfg.token_header, curl = cfg.curl }
  local resp = http.request(req_cfg, { method = "GET", path = "/health", sync = true })
  resp.url = cfg.url
  resp.mode = (cfg.modeline_hit and "modeline" or "setup")
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
---@param opts? { bufnr: integer?, force: boolean? }
---@return boolean ok
function M.insert_header(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  if not opts.force and modeline.is_autodbg_buf(bufnr) then
    vim.notify("AutoDbg: 这个 buffer 已经有标记了", vim.log.levels.INFO)
    return false
  end
  local cfg = merged(opts.cfg)
  local line = "--!autodbg url=" .. tostring(cfg.url)
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { line })
  vim.notify("AutoDbg: 已插入标记 " .. line, vim.log.levels.INFO)
  return true
end

return M
