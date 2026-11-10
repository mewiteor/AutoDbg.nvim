-- =============================================================================
-- nvim/plugin/autodbg.lua —— 命令与 autocmd 注册（runtimepath 里加载本目录即生效）
--
-- 命令：
--   :AutoDbgRun [range]   执行当前 buffer / 选区
--   :AutoDbgCancel        取消正在执行的脚本
--   :AutoDbgHealth        server 状态（busy/queue），并打印实际用的地址
--   :AutoDbgHeader        在 buffer 头部插入 `--!autodbg` 标记（含远程地址）
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
end, { desc = "AutoDbg: 取消正在执行的脚本" })

vim.api.nvim_create_user_command("AutoDbgHealth", function()
  require("autodbg").health()
end, { desc = "AutoDbg: 查看 server 状态" })

vim.api.nvim_create_user_command("AutoDbgHeader", function()
  require("autodbg").insert_header()
end, { desc = "AutoDbg: 在 buffer 头部插入 --!autodbg 标记" })

vim.api.nvim_create_user_command("AutoDbgLsp", function(o)
  local lsp = require("autodbg.lsp")
  local arg = vim.trim(o.args or "")
  if arg == "off" then
    local n = lsp.disable()
    vim.notify(string.format("AutoDbg: 已摘掉 LuaLS 注解库（%d 个 client）", n), vim.log.levels.INFO)
  elseif arg == "on" or arg == "" then
    local n = lsp.enable()
    vim.notify(
      string.format("AutoDbg: 注解库 %s（改动 %d 个 lua_ls client）", lsp.addon_dir(), n),
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
