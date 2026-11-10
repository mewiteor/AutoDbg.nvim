-- =============================================================================
-- nvim/lua/autodbg/lsp.lua —— 把 LuaLS 注解库挂到 lua_ls（取代 generate_templete）
--
-- 来源：新写。取代 AutoDbg 模块里 `generate_templete()` 往脚本目录旁写
--   `cdebugger.d.lua` + `.luarc.json` 的老做法（思路参考 xmake.nvim 的 addons 方案）。
--
-- 做法：本插件自带一个 LLS-Addons 结构的注解目录
--   `addons/autodbg/{config.json, library/*.lua}`，
--   在「当前 buffer 被判定为 AutoDbg 脚本」时把它加进 lua_ls 的
--   `Lua.workspace.library`，再 notify `workspace/didChangeConfiguration` 让 server 重建索引。
--
-- 判定依据：脚本头部（前 5 行）/尾部的 `--!autodbg ...` 标记（见 `modeline.lua`），
--   **按内容判定**，所以无名 buffer（`[No Name]`）也能正确挂上注解。
--
-- ❗已知边界：lua_ls 的 `workspace.library` 是**客户端级全局**的，一旦启用，
--   本会话里其它 Lua 文件也会看到这些注解（lua_ls 不支持按文件/按 buffer 挂库）。
--   因此这里是**懒启用**（只有真的打开过 AutoDbg 脚本才挂）；
--   `setup{ lsp = { enable = false } }` 或 `:AutoDbgLsp off` 可完全关掉。
-- =============================================================================

local M = {}

--- 已成功挂上注解库的 client id
---@type table<integer, boolean>
local state = {}

--- 本插件的根目录（`nvim/`）
---@return string
local function plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(src)))
end

--- 注解库目录（内含 config.json + library/*.lua）
---@return string
function M.addon_dir()
  return vim.fs.joinpath(plugin_root(), "addons", "autodbg")
end

--- 取配置（惰性 require，避免与 init.lua 循环依赖）
---@return table
local function config()
  return require("autodbg").config or {}
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

--- 挂上注解库（幂等）。返回真正改动的 client 数量。
---@param client_id integer? 指定 client；缺省 = 所有 lua_ls
---@return integer changed
function M.enable(client_id)
  local dir = M.addon_dir()
  if vim.fn.isdirectory(dir) == 0 then
    return 0
  end

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

      if not has_path(lib, dir) then
        add_path(lib, dir)
        dirty = true
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
      if dirty then
        changed = changed + 1
        state[client.id] = true
        client.notify("workspace/didChangeConfiguration", { settings = { Lua = lua } })
      else
        state[client.id] = true
      end
    end
  end
  return changed
end

--- 摘掉注解库（幂等）
---@param client_id integer?
---@return integer changed
function M.disable(client_id)
  local dir = M.addon_dir()
  local changed = 0
  for _, client in ipairs(lua_clients()) do
    if client_id == nil or client.id == client_id then
      local lua = (client.settings or {}).Lua
      local lib = lua and lua.workspace and lua.workspace.library
      if type(lib) == "table" then
        local removed = false
        lib[dir] = nil
        for i = #lib, 1, -1 do
          if lib[i] == dir then
            table.remove(lib, i)
            removed = true
          end
        end
        if removed then
          changed = changed + 1
          client.notify("workspace/didChangeConfiguration", { settings = { Lua = lua } })
        end
      end
      state[client.id] = nil
    end
  end
  return changed
end

--- 该 buffer 是 AutoDbg 脚本才挂注解库（懒启用）
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
  M.enable()
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
      hooked = state[c.id] == true,
    }
  end
  return { addon_dir = M.addon_dir(), clients = attached }
end

return M
