-- =============================================================================
-- nvim/plugin/autodbg.lua —— 命令与 autocmd 注册（runtimepath 里加载本目录即生效）
--
-- 命令：
--   :AutoDbgRun [range]   执行当前 buffer / 选区（有 exe 就本地，否则远程）
--   :AutoDbgCancel        取消当前脚本（硬 cancel）
--   :AutoDbgKill          只结束当前 Attach/Run（软），脚本继续
--   :AutoDbgDetach        真 detach：目标继续活着（NT+）
--   :AutoDbgHealth        状态（本地报 exe/arch，远程问 server）
--   :AutoDbgVersion       查 server 版本 / ABI（远程）
--   :AutoDbgHeader [local|remote]  在 buffer 头部插入 `--!autodbg` 标记
--   :AutoDbgLsp [on|off]  手动挂/摘 LuaLS 注解库（默认按脚本标记懒启用）
--
-- autocmd：
--   · BufReadPost / BufNewFile / BufWritePost / FileType
--       → 内容是 AutoDbg 脚本（头部有 `--!autodbg` 标记）时挂上 LuaLS 注解库；
--         `FileType lua` 时顺便注册 LuaSnip 片段（LuaSnip 不在就安静跳过）
--   · LspAttach → lua_ls 起来时补挂一次（server 可能比 buffer 晚启动）
-- 配置用 `require("autodbg").setup{...}`（见 lua/autodbg/init.lua 顶部注释）。
-- =============================================================================

if vim.g.loaded_autodbg then
  return
end
vim.g.loaded_autodbg = true

vim.api.nvim_create_user_command("AutoDbgRun", function(o)
  local range = nil
  if o.range and o.range > 0 then
    range = { o.line1, o.line2 }
  end
  require("autodbg").run({ range = range })
end, { range = true, desc = "AutoDbg: 执行当前 buffer/选区（远程 server）" })

vim.api.nvim_create_user_command("AutoDbgCancel", function()
  require("autodbg").cancel()
end, { desc = "AutoDbg: 取消正在执行的脚本（硬）" })

vim.api.nvim_create_user_command("AutoDbgKill", function()
  require("autodbg").kill()
end, { desc = "AutoDbg: 只结束当前 Attach/Run（软），脚本继续" })

vim.api.nvim_create_user_command("AutoDbgDetach", function()
  require("autodbg").detach()
end, { desc = "AutoDbg: 真 detach，目标继续活着（NT+）" })

vim.api.nvim_create_user_command("AutoDbgHealth", function()
  require("autodbg").health()
end, { desc = "AutoDbg: 查看 server 状态" })

vim.api.nvim_create_user_command("AutoDbgVersion", function()
  require("autodbg").version()
end, { desc = "AutoDbg: 查 server 版本 / ABI" })

vim.api.nvim_create_user_command("AutoDbgHeader", function(o)
  local kind = vim.trim(o.args or "")
  if kind ~= "local" and kind ~= "remote" then
    kind = nil
  end
  require("autodbg").insert_header({ kind = kind })
end, {
  nargs = "?",
  complete = function()
    return { "remote", "local" }
  end,
  desc = "AutoDbg: 插入 --!autodbg 标记（remote=host+port / local=exe+arch）",
})

vim.api.nvim_create_user_command("AutoDbgLsp", function(o)
  local lsp = require("autodbg.lsp")
  local arg = vim.trim(o.args or "")
  if arg == "off" then
    local n = lsp.disable()
    vim.notify(string.format("AutoDbg: 已摘掉 LuaLS 注解库（%d 个 client）", n), vim.log.levels.INFO)
  elseif arg == "on" or arg == "" then
    local arch = lsp.resolve_arch(vim.api.nvim_get_current_buf())
    local n = lsp.enable(arch)
    vim.notify(
      string.format("AutoDbg: 注解库 arch=%s → %s（改动 %d 个 lua_ls client）", arch, lsp.addon_dir(), n),
      vim.log.levels.INFO
    )
  else
    local st = lsp.status()
    vim.notify("AutoDbg lsp: " .. vim.inspect(st), vim.log.levels.INFO)
  end
end, { nargs = "?", complete = function() return { "on", "off", "status" } end, desc = "AutoDbg: 挂/摘 LuaLS 注解库" })

local group = vim.api.nvim_create_augroup("autodbg", { clear = true })

-- 内容驱动的“这是不是 AutoDbg 脚本”判定：无名 buffer 一样适用
vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufWritePost" }, {
  group = group,
  callback = function(args)
    require("autodbg.lsp").maybe_enable(args.buf)
  end,
})

vim.api.nvim_create_autocmd("FileType", {
  group = group,
  pattern = "lua",
  callback = function()
    require("autodbg.lsp").maybe_enable(vim.api.nvim_get_current_buf())
    local sn = require("autodbg").config.snippets or {}
    if sn.enable then
      require("autodbg.snippets").add("lua")
    end
  end,
})

vim.api.nvim_create_autocmd("LspAttach", {
  group = group,
  callback = function(args)
    require("autodbg.lsp").attach(args)
  end,
})
