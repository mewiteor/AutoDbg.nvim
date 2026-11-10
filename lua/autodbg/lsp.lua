-- =============================================================================
-- nvim/lua/autodbg/lsp.lua —— 把 LuaLS 注解库挂到 lua_ls（取代 generate_templete）
--
-- 来源：新写。取代 AutoDbg 模块里 `generate_templete()` 往脚本目录旁写
--   `cdebugger.d.lua` + `.luarc.json` 的老做法（思路参考 xmake.nvim 的 addons 方案）。
--
-- 做法：本插件自带一个注解库目录：
--   · `addons/autodbg/library/*.lua` —— 与架构无关的部分；
--   · `addons/autodbg/arch/{x86,x64}/context.lua` —— **按架构**的 `Context` 字段
--     （x86 = 23 项；x64 = 60 项，多 Xmm0-15 / R8-R15 / P1Home… 等）。
--   在「当前 buffer 被判定为 AutoDbg 脚本」时把它们加进 lua_ls 的
--   `Lua.workspace.library`，再 notify `workspace/didChangeConfiguration` 让 server 重建索引。
--
-- 判定依据：脚本头部（前 5 行）/尾部的 `--!autodbg ...` 标记（见 `modeline.lua`），
--   **按内容判定**，所以无名 buffer（`[No Name]`）也能正确挂上注解。
--
-- 架构选择（决定挂 x86 还是 x64 的 `Context`）：
--   ① 标记里的 `arch=x86|x64`；② 标记里 `exe=` 的文件名（`_86`/`_64`）；
--   ③ `setup{ lsp = { arch = … } }`；④ 都没有 → **x64**（主开发目标）。
--   切换架构时会先把另一个架构的目录摘掉（lua_ls 会把 library 目录递归扫完，
--   两个都挂着等于两份 `Context` 定义混在一起）。
--
-- ❗已知边界：lua_ls 的 `workspace.library` 是**客户端级全局**的，一旦启用，
--   本会话里其它 Lua 文件也会看到这些注解（lua_ls 不支持按文件/按 buffer 挂库）。
--   因此这里是**懒启用**（只有真的打开过 AutoDbg 脚本才挂）；
--   `setup{ lsp = { enable = false } }` 或 `:AutoDbgLsp off` 可完全关掉。
-- =============================================================================

local M = {}

--- 已挂上的注解目录（client id → 目录列表）
---@type table<integer, string[]>
local state = {}

--- 每个 client 当前用的架构
---@type table<integer, string>
local state_arch = {}

--- 本插件的根目录（`nvim/`）
---@return string
local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(src)))
end

--- 取配置（惰性 require，避免与 init.lua 循环依赖）
-- 注：必须定义在 resolve_arch / enable 之前（之前把本地函数声明在后面，
--     前面的函数会把 `config` 当全局，调用时炸）。
---@return table
local function config()
  return require("autodbg").config or {}
end

--- 注解库根目录（内含 config.json / library/ / arch/）
---@return string
function M.addon_dir()
  return vim.fs.joinpath(plugin_root(), "addons", "autodbg")
end

--- 给定架构时应挂的目录：公共 library/ + arch/<arch>/
---@param arch string? "x86" | "x64" | nil
---@return string[] dirs
function M.library_dirs(arch)
  local root = M.addon_dir()
  local dirs = { vim.fs.joinpath(root, "library") }
  if arch == "x86" or arch == "x64" then
    dirs[#dirs + 1] = vim.fs.joinpath(root, "arch", arch)
  end
  return dirs
end

--- 解析某个 buffer 应该用哪个架构
--   标记 arch= > 标记 exe 的文件名 > setup.lsp.arch > "x64"
---@param bufnr integer?
---@param cfg table?
---@return string arch
function M.resolve_arch(bufnr, cfg)
  cfg = cfg or config()
  local modeline = require("autodbg.modeline")
  local ml = modeline.from_buf(bufnr, cfg.modeline)
  if ml.found then
    local a = modeline.normalize_arch(ml.arch)
    if a then
      return a
    end
    local from_exe = modeline.arch_from_exe(ml.exe)
    if from_exe then
      return from_exe
    end
  end
  return modeline.normalize_arch((cfg.lsp or {}).arch) or "x64"
end

--- 当前所有 lua_ls 客户端
---@return table[]
local function lua_clients()
  local out = {}
  local get = vim.lsp.get_clients or vim.lsp.get_active_clients
  local ok, clients = pcall(get, { name = "lua_ls" })
  if not ok or type(clients) ~= "table" then
    return out
  end
  for _, c in ipairs(clients) do
    if c.name == "lua_ls" then
      out[#out + 1] = c
    end
  end
  return out
end

--- library 里是否已经有这个路径（lua_ls 接受数组或 `{ [path]=true }` 两种形态）
---@param lib table
---@param path string
---@return boolean
local function has_path(lib, path)
  if lib[path] then
    return true
  end
  for _, v in ipairs(lib) do
    if v == path then
      return true
    end
  end
  return false
end

--- @param lib table
---@param path string
local function add_path(lib, path)
  if #lib == 0 and next(lib) ~= nil then
    -- 已经是 map 形态
    lib[path] = true
  else
    lib[#lib + 1] = path
  end
end

--- 从 library 里去掉一个路径（数组与 map 两种形态都处理）
---@param lib table
---@param path string
local function remove_path(lib, path)
  lib[path] = nil
  for i = #lib, 1, -1 do
    if lib[i] == path then
      table.remove(lib, i)
    end
  end
end

--- 挂上注解库（幂等）。返回真正改动的 client 数量。
-- 如果该 client 之前挂的是另一个架构，会先摘掉再换。
---@param arch string? "x86" | "x64"；nil = 只挂公共部分
---@param client_id integer? 指定 client；缺省 = 所有 lua_ls
---@return integer changed
function M.enable(arch, client_id)
  local dirs = M.library_dirs(arch)
  for _, d in ipairs(dirs) do
    if vim.fn.isdirectory(d) == 0 then
      return 0
    end
  end

  local all_arch_dirs = { M.library_dirs("x86")[2], M.library_dirs("x64")[2] }

  local changed = 0
  for _, client in ipairs(lua_clients()) do
    if client_id == nil or client.id == client_id then
      client.settings = client.settings or {}
      local lua = client.settings.Lua or {}
      lua.workspace = lua.workspace or {}
      if type(lua.workspace.library) ~= "table" then
        lua.workspace.library = {}
      end
      local lib = lua.workspace.library
      local dirty = false

      for _, other in ipairs(all_arch_dirs) do
        local keep = false
        for _, d in ipairs(dirs) do
          if other == d then
            keep = true
          end
        end
        if not keep and has_path(lib, other) then
          remove_path(lib, other)
          dirty = true
        end
      end

      for _, dir in ipairs(dirs) do
        if not has_path(lib, dir) then
          add_path(lib, dir)
          dirty = true
        end
      end

      local rv = (config().lsp or {}).runtime_version
      if rv and rv ~= "" then
        lua.runtime = lua.runtime or {}
        if lua.runtime.version ~= rv then
          lua.runtime.version = rv
          dirty = true
        end
      end

      client.settings.Lua = lua
      state[client.id] = dirs
      state_arch[client.id] = arch
      if dirty then
        changed = changed + 1
        client.notify("workspace/didChangeConfiguration", { settings = { Lua = lua } })
      end
    end
  end
  return changed
end

--- 摘掉注解库（幂等）
---@param client_id integer?
---@return integer changed
function M.disable(client_id)
  local all = { M.library_dirs(nil)[1], M.library_dirs("x86")[2], M.library_dirs("x64")[2] }
  local changed = 0
  for _, client in ipairs(lua_clients()) do
    if client_id == nil or client.id == client_id then
      local lua = (client.settings or {}).Lua
      local lib = lua and lua.workspace and lua.workspace.library
      if type(lib) == "table" then
        local removed = false
        for _, d in ipairs(all) do
          if has_path(lib, d) then
            remove_path(lib, d)
            removed = true
          end
        end
        if removed then
          changed = changed + 1
          client.notify("workspace/didChangeConfiguration", { settings = { Lua = lua } })
        end
      end
      state[client.id] = nil
      state_arch[client.id] = nil
    end
  end
  return changed
end

--- 该 buffer 是 AutoDbg 脚本才挂注解库（懒启用；架构按标记决定）
---@param bufnr integer?
---@return boolean enabled
function M.maybe_enable(bufnr)
  local cfg = config()
  if not (cfg.lsp and cfg.lsp.enable) then
    return false
  end
  if not require("autodbg.modeline").is_autodbg_buf(bufnr) then
    return false
  end
  M.enable(M.resolve_arch(bufnr, cfg))
  return true
end

--- `LspAttach` 回调：server 起来时，如果当前 buffer 是 AutoDbg 脚本就补挂一次
---@param args table
function M.attach(args)
  if args and args.buf then
    M.maybe_enable(args.buf)
  end
end

--- 诊断用状态
---@return table
function M.status()
  local attached = {}
  for _, c in ipairs(lua_clients()) do
    attached[#attached + 1] = {
      id = c.id,
      root = c.root_dir,
      arch = state_arch[c.id],
      hooked = state[c.id] ~= nil,
    }
  end
  return { addon_dir = M.addon_dir(), clients = attached }
end

return M
