-- =============================================================================
-- nvim/lua/autodbg/init.lua —— neovim 客户端主入口（S3）
--
-- 来源：新写（plan_server.md S3 / §6.1）。
-- 用法（依赖为零，把本目录加到 runtimepath 即可）：
--   require("autodbg").setup({ url = "http://127.0.0.1:8642" })
--   :AutoDbgRun            " 当前 buffer 整段执行
--   :'<,'>AutoDbgRun       " 只执行选区
--   :AutoDbgCancel         " 取消正在跑的脚本
--   :AutoDbgHealth         " 看一眼 server 状态
-- 结果：写到 scratch buffer（`exit/elapsed` + stdout + stderr），并把 `<file>:<line>:`
--   形式的错误行塞进 quickfix（`:copen` / `]q` 可直达脚本出错行）。
-- 与 server 的契约见 plan_server.md §4.4/§4.5：body = Lua 源码，`X-AutoDbg-Filename`
--   作为 chunkname（所以错误信息里带的是你的缓冲区文件名）。
-- =============================================================================

local effects = require("autodbg.effects")
local http = require("autodbg.http")
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
  return M.config
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
function M.run(opts)
  opts = opts or {}
  local cfg = merged(opts.cfg)
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

--- 取消正在跑的那一次执行
function M.cancel(opts)
  opts = opts or {}
  local cfg = merged(opts.cfg)
  local req_cfg = { url = cfg.url, token = resolve_token(cfg), token_header = cfg.token_header, curl = cfg.curl }
  local resp = http.request(req_cfg, { method = "POST", path = "/cancel", sync = opts.sync or true })
  local ok, decoded = pcall(vim.json.decode, resp.body or "")
  local accepted = ok and type(decoded) == "table" and decoded.accepted == true
  if opts.sync then
    return accepted
  end
  vim.notify(accepted and "AutoDbg: 已请求取消" or "AutoDbg: 当前没有正在执行的脚本", vim.log.levels.INFO)
end

--- 查看 server 状态
function M.health(opts)
  opts = opts or {}
  local cfg = merged(opts.cfg)
  local req_cfg = { url = cfg.url, token = resolve_token(cfg), token_header = cfg.token_header, curl = cfg.curl }
  local resp = http.request(req_cfg, { method = "GET", path = "/health", sync = true })
  if opts.sync then
    return resp
  end
  if resp.status == 200 then
    vim.notify("AutoDbg /health: " .. (resp.body or ""), vim.log.levels.INFO)
  else
    notify_err("health 失败（status=" .. tostring(resp.status) .. "）")
  end
end

return M
