-- =============================================================================
-- nvim/plugin/autodbg.lua —— 命令注册（runtimepath 里加载本目录即生效）
--
-- 来源：新写（plan_server.md S3 / §6.1）。
-- 命令：
--   :AutoDbgRun [range]   执行当前 buffer / 选区
--   :AutoDbgCancel        取消正在执行的脚本
--   :AutoDbgHealth        server 状态（busy/queue）
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
end, { desc = "AutoDbg: 取消正在执行的脚本" })

vim.api.nvim_create_user_command("AutoDbgHealth", function()
  require("autodbg").health()
end, { desc = "AutoDbg: 查看 server 状态" })
