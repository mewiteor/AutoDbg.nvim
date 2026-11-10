-- =============================================================================
-- nvim/lua/autodbg/local.lua —— 本地模式：直接跑 AutoDbg 的 exe
--
-- 来源：新写。插件原来只有远程模式（HTTP `/run`），这里补上「本机直接执行」。
--
-- 何时用本地模式（由 `init.lua` 的 resolve 决定）：
--   · 脚本头标了 `exe=<路径>`，或 `setup{ exe = … }` 给了路径 → 用那个 exe；
--   · 都没标 → 在 **PATH** 里找 `AutoDbg_64.exe` / `AutoDbg_86.exe` / `AutoDbg.exe`；
--   · 找到了就本地跑；找不到（或标记的 exe 不存在）→ **回退远程模式**（带一条提示）。
--
-- 与远程模式的差别：
--   · 脚本必须落成临时文件（AutoDbg 的命令行只接受脚本路径）→ 写到系统临时目录，
--     跑完即删；stdout/stderr 用管道抓（`Print*`/`Error*` 在非控制台下走 `WriteFile`，
--     所以重定向能抓到）。
--   · flavor 由 exe 自己的首行标记（`--!lua` / `--!luajit`）决定，插件不插手；
--     `--!autodbg …`（本插件的标记）会被 launcher 当**非 flavor 标记**跳过。
--   · 默认带 `--quiet`（关掉错误弹窗）：headless 下弹个 MessageBox 会把进程挂住。
-- =============================================================================

local M = {}

--- PATH 里的候选名（按顺序尝试；找到第一个就用）
M.exe_names = { "AutoDbg_64.exe", "AutoDbg_86.exe", "AutoDbg.exe", "autodbg.exe" }

local state = {
  job = nil,      -- 正在跑的 SystemObj（异步模式，供 cancel 用）
  temp_file = nil,
}

--- 展开 `~`、去掉引号与首尾空白
---@param p string?
---@return string?
function M.expand(p)
  if type(p) ~= "string" then
    return nil
  end
  p = vim.trim(p):gsub('^"', ""):gsub('"$', ""):gsub("^'", ""):gsub("'$", "")
  if p == "" then
    return nil
  end
  return (vim.fn.expand(p))
end

--- 该路径是否像一个可用的可执行文件
---@param p string?
---@return boolean
function M.is_exe(p)
  p = M.expand(p)
  return p ~= nil and vim.fn.filereadable(p) == 1
end

--- 在 PATH 里找一个 AutoDbg exe（也可以给一带目录的路径）
---@param names string[]?
---@return string? path
function M.find_in_path(names)
  for _, name in ipairs(names or M.exe_names) do
    local p = vim.fn.exepath(name)
    if p ~= nil and p ~= "" and vim.fn.filereadable(p) == 1 then
      return p
    end
  end
  return nil
end

--- 解析最终要用的 exe。
---@param cfg table 合并后的配置（含 modeline 的 exe / setup 的 exe）
---@return string? path, string? source "modeline" | "config" | "PATH"
---@return string? tried 失败时：标记里给的、但不存在的那条路径
function M.resolve(cfg)
  local marked = M.expand(cfg.exe)
  if marked then
    if vim.fn.filereadable(marked) == 1 then
      return marked, (cfg.modeline_hit and cfg.modeline_hit.exe and "modeline" or "config")
    end
    return nil, nil, marked
  end
  local found = M.find_in_path(cfg.exe_names or M.exe_names)
  if found then
    return found, "PATH"
  end
  return nil
end

--- 从 exe 文件名猜架构（`AutoDbg_86.exe` → x86，`AutoDbg_64.exe` → x64）
---@param path string?
---@return string? arch "x86" | "x64" | nil
function M.arch_of_exe(path)
  local name = tostring(path or ""):lower()
  if name:find("_64", 1, true) or name:find("64%.exe$") then
    return "x64"
  end
  if name:find("_86", 1, true) or name:find("_98", 1, true) or name:find("86%.exe$") then
    return "x86"
  end
  return nil
end

--- 抛掉脚本头里对 launcher 有意义的标记？不需要：`--!autodbg` 已被 launcher 当非 flavor 跳过。
--- 但临时文件里保留原文更利于**行号一致**，所以这里原样写。
---@param body string
---@return string
function M.script_text(body)
  return body
end

--- 本地跑一段脚本（异步回调 / 同步返回共用一份结果映射）
---@param opts table {
---   exe: string, body: string, filename: string?, real_path: string?,
---   args: string[]?, cwd: string?, flags: string[]?, timeout_ms: integer?,
---   sync: boolean?, on_done: fun(res:table)? }
---@return table? res 同步模式返回结果表
function M.run(opts)
  opts = opts or {}
  local exe = M.expand(opts.exe)
  if not exe or vim.fn.filereadable(exe) ~= 1 then
    local res = {
      ok = false,
      exit = -1,
      stdout = "",
      stderr = "",
      error = "找不到 AutoDbg 的 exe：" .. tostring(opts.exe),
      mode = "local",
      exe = exe,
    }
    if opts.on_done then
      opts.on_done(res)
    end
    return opts.sync and res or nil
  end

  -- 临时文件：用 buffer 名（带唯一前缀）而不是随机名，错误信息里能一眼看出是哪个脚本
  local base = tostring(opts.filename or "buffer.lua"):gsub("[/\\:]", "_")
  local tmp = vim.fn.tempname() .. "-" .. base
  local f = io.open(tmp, "wb")
  if not f then
    local res = {
      ok = false,
      exit = -1,
      stdout = "",
      stderr = "",
      error = "无法写临时文件：" .. tmp,
      mode = "local",
      exe = exe,
    }
    if opts.on_done then
      opts.on_done(res)
    end
    return opts.sync and res or nil
  end
  f:write(M.script_text(opts.body or ""))
  f:close()
  state.temp_file = tmp

  local argv = { exe }
  for _, flag in ipairs(opts.flags or {}) do
    argv[#argv + 1] = flag
  end
  argv[#argv + 1] = tmp
  for _, a in ipairs(opts.args or {}) do
    argv[#argv + 1] = tostring(a)
  end

  local started = vim.uv.hrtime()
  local cwd = opts.cwd
  if not cwd or vim.fn.isdirectory(cwd) == 0 then
    cwd = vim.fn.getcwd()
  end

  local sys_opts = { text = false, cwd = cwd }

  local function finish(obj, timed_out)
    pcall(os.remove, tmp)
    if state.temp_file == tmp then
      state.temp_file = nil
    end
    state.job = nil

    local out = obj.stdout or ""
    local err = obj.stderr or ""
    if type(out) == "table" then
      out = table.concat(out, "")
    end
    if type(err) == "table" then
      err = table.concat(err, "")
    end
    -- 临时文件路径 → 真实 buffer 路径（quickfix / 错误行才对得上）
    if opts.real_path and opts.real_path ~= "" then
      out = out:gsub(vim.pesc(tmp), opts.real_path)
      err = err:gsub(vim.pesc(tmp), opts.real_path)
    end

    local code = obj.code or 0
    local elapsed = math.floor((vim.uv.hrtime() - started) / 1e6)
    local res = {
      ok = (not timed_out) and code == 0,
      exit = timed_out and 124 or code,
      stdout = out,
      stderr = err,
      error = nil,
      elapsed_ms = elapsed,
      truncated = false,
      canceled = false,
      timed_out = timed_out == true,
      mode = "local",
      exe = exe,
      arch = M.arch_of_exe(exe),
      script = tmp,
    }
    if opts.sync then
      return res
    end
    if opts.on_done then
      opts.on_done(res)
    end
    return res
  end

  if opts.sync then
    -- ❗`:wait(0)` 是「立即返回」（没跑完就是 nil），不要拿 0 当「不限时」
    local sys = vim.system(argv, sys_opts)
    local timeout = opts.timeout_ms
    local obj
    if type(timeout) == "number" and timeout > 0 then
      obj = sys:wait(timeout)
    else
      obj = sys:wait()
    end
    if obj == nil then
      pcall(function()
        sys:kill(15)
      end)
      return finish({ code = 124, stdout = "", stderr = "" }, true)
    end
    return finish(obj, false)
  end

  state.job = vim.system(argv, sys_opts, function(obj)
    local res = finish(obj, false)
    if opts.on_done then
      vim.schedule(function()
        opts.on_done(res)
      end)
    end
  end)
  return nil
end

--- 杀掉本地正在跑的那一次（`:AutoDbgCancel` 在本地模式下走这里）
---@return boolean killed
function M.cancel()
  if state.job then
    pcall(function()
      state.job:kill(15)
    end)
    state.job = nil
    return true
  end
  if state.temp_file then
    pcall(os.remove, state.temp_file)
    state.temp_file = nil
  end
  return false
end

return M
