-- =============================================================================
-- nvim/lua/autodbg/snippets.lua —— LuaSnip 片段（可选依赖，不硬绑定）
--
-- 来源：新写。LuaSnip 不存在时所有函数安静返回 nil（不报错、不影响插件其它功能）。
--
-- 用法（二选一）：
--   · 自动：`require("autodbg").setup{ snippets = { enable = true } }`
--     （插件在 `FileType lua` 时调 `ls.add_snippets("lua", ..., { key = "autodbg" })`）
--   · 手动：`require("luasnip").add_snippets("lua", require("autodbg.snippets").get())`
--
-- 片段（触发词 → 作用）：
--   adbg      脚本头标记（`--!autodbg url=… token=…`，LSP 注解与远程地址都靠它）
--   adrun     Run({ imagepath, callback })
--   adbp      SetBreakpoint({ modname, rva, callback })
--   adrunbp   Run + 入口回调里下断点（最常用的组合）
--   adhw      SetHardwareBreakpoint({...})
--   adctx     local ctx = GetContext(tid)
--   admem     ReadMemory / WriteMemory 一对
--   adstack   StackTrace(tid) 遍历栈帧
--   adexcept  Run + exception_callback
--   adgui     gui.find + gui.screenshot（把界面拍下来给 AI 看）
--   adclick   gui.activate + gui.click
--   adfile    read_file / write_file（读写**本机**文件）
-- =============================================================================

local M = {}

--- LuaSnip 模块；不可用时返回 nil（只探测一次）
---@type table|false|nil
local luasnip = nil

---@return table?
local function ls()
  if luasnip == nil then
    local ok, mod = pcall(require, "luasnip")
    luasnip = ok and mod or false
  end
  return luasnip or nil
end

--- 构造片段表（不注册）
---@return table? snippets nil = LuaSnip 不可用
function M.get()
  local L = ls()
  if not L then
    return nil
  end

  local s = L.snippet
  local t = L.text_node
  local i = L.insert_node
  local c = L.choice_node

  local list = {}

  -- 脚本头标记：LSP 注解与远程地址都由它决定（换机器只改这一行）
  list[#list + 1] = s({ trig = "adbg", dscr = "AutoDbg: 脚本头标记（远程地址 / LSP 开关）" }, {
    t("--!autodbg url=http://"),
    i(1, "127.0.0.1"),
    t(":"),
    i(2, "8642"),
    t(" token="),
    i(3, ""),
    t({ "", "-- AutoDbg 脚本：:AutoDbgRun 执行 / :AutoDbgHealth 看状态 / :AutoDbgCancel 取消" }),
  })

  list[#list + 1] = s({ trig = "adrun", dscr = "AutoDbg: Run({ imagepath, callback })" }, {
    t({ "Run({", '    imagepath = "' }),
    i(1, "C:\\\\target.exe"),
    t({ '",', "    callback = function(pid, tid)" }),
    t({ "        " }),
    i(0, "-- 入口断点：目标刚创建、还没开始跑"),
    t({ "", "    end,", "})" }),
  })

  list[#list + 1] = s({ trig = "adbp", dscr = "AutoDbg: SetBreakpoint({ modname, rva, callback })" }, {
    t({ "SetBreakpoint({", '    modname = "' }),
    i(1, "kernel32.dll"),
    t({ '",', '    rva = FindFuncRva("' }),
    i(2, "kernel32.dll"),
    t({ '", "' }),
    i(3, "CreateFileW"),
    t({ '"),', "    callback = function()" }),
    t({ "        " }),
    i(0, "local ctx = GetContext(tid)"),
    t({ "", "    end,", "})" }),
  })

  list[#list + 1] = s({ trig = "adrunbp", dscr = "AutoDbg: Run + 入口回调里下断点" }, {
    t({ "Run({", '    imagepath = "' }),
    i(1, "C:\\\\target.exe"),
    t({ '",', "    callback = function(pid, tid)" }),
    t({ "        SetBreakpoint({", '            modname = "' }),
    i(2, "kernel32.dll"),
    t({ '",', '            rva = FindFuncRva("' }),
    i(3, "kernel32.dll"),
    t({ '", "' }),
    i(4, "CreateFileW"),
    t({ '"),', "            callback = function()" }),
    t({ "                " }),
    i(0, "print('hit')"),
    t({ "", "            end,", "        })", "    end,", "})" }),
  })

  list[#list + 1] = s({ trig = "adhw", dscr = "AutoDbg: SetHardwareBreakpoint({...})" }, {
    t({ "SetHardwareBreakpoint({", "    modname = " }),
    c(1, { t('"kernel32.dll"'), t('nil') }),
    t({ ",", "    rva = " }),
    i(2, "0x1000"),
    t({ ",", "    size = " }),
    c(3, { t("1"), t("2"), t("4"), t("8") }),
    t({ ",", "    callback = function()" }),
    t({ "        " }),
    i(0, ""),
    t({ "", "    end,", "})" }),
  })

  list[#list + 1] = s({ trig = "adctx", dscr = "AutoDbg: 取线程上下文" }, {
    t("local ctx = GetContext("),
    i(1, "tid"),
    t(")"),
  })

  list[#list + 1] = s({ trig = "admem", dscr = "AutoDbg: 读/写目标内存" }, {
    t("local data = ReadMemory("),
    i(1, "addr"),
    t(", "),
    i(2, "64"),
    t(")"),
    i(0, ""),
  })

  list[#list + 1] = s({ trig = "adstack", dscr = "AutoDbg: 遍历栈帧" }, {
    t("for _, fr in ipairs({ StackTrace("),
    i(1, "tid"),
    t(") }) do"),
    t({ "", '    print(string.format("%s+0x%X", tostring(fr.modname), fr.rva))' }),
    i(0, ""),
    t({ "", "end" }),
  })

  list[#list + 1] = s({ trig = "adexcept", dscr = "AutoDbg: Run + 异常回调" }, {
    t({ "Run({", '    imagepath = "' }),
    i(1, "C:\\\\target.exe"),
    t({ '",', "    exception_callback = function(info)" }),
    t({ "        " }),
    i(0, "print(info.type, info.address)"),
    t({ "", "    end,", "})" }),
  })

  list[#list + 1] = s({ trig = "adgui", dscr = "AutoDbg: 找窗口并截图（给 AI 看界面）" }, {
    t('local hwnd = gui.find({ title = "'),
    i(1, "窗口标题"),
    t({ '" })', 'local shot = gui.screenshot({ hwnd = hwnd, format = "png" })' }),
    t({ "", 'write_file("' }),
    i(2, "shot.png"),
    t({ '", shot.data, "wb")' }),
    i(0, ""),
  })

  list[#list + 1] = s({ trig = "adclick", dscr = "AutoDbg: 激活窗口并点击控件" }, {
    t("gui.activate("),
    i(1, "hwnd"),
    t(")"),
    t({ "", 'gui.click(' }),
    i(2, "x"),
    t(", "),
    i(3, "y"),
    t(")"),
    i(0, ""),
  })

  list[#list + 1] = s({ trig = "adfile", dscr = "AutoDbg: 读写客户端（本机）文件" }, {
    t("local data, err = read_file("),
    i(1, '"C:\\\\tmp\\\\in.bin"'),
    t(")"),
    t({ "", 'write_file("' }),
    i(2, "C:\\\\tmp\\\\out.bin"),
    t({ '", data, "wb")' }),
    i(0, ""),
  })

  return list
end

--- 注册到某个 filetype（默认 lua）；重复调用只保留最新一份
---@param filetype string?
---@return boolean ok
function M.add(filetype)
  local L = ls()
  local list = M.get()
  if not L or not list then
    return false
  end
  L.add_snippets(filetype or "lua", list, { key = "autodbg" })
  return true
end

return M
