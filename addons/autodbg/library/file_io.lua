---@meta
-- ---------------------------------------------------------------------------
-- AutoDbg.nvim —— LuaLS 注解：client 文件 I/O（read_file / write_file）
--
-- 来源：由 AutoDbg 模块（迁移前）的 generate_templete() 模板原样迁入；
--   之后新增的 API 见 lualib.lua（effects / mcp）与 file_io.lua（read_file / write_file）。
-- 不要 require 本文件：它只给 lua_ls 看（首行 ---@meta）。
-- ---------------------------------------------------------------------------

---
---读取**客户端（本机）**上的文件；server 模式下由插件在本地执行后再恢复脚本
---@param path string
---@param mode string? "rb"（默认）/ "r"：带 b = 二进制，否则按文本做行尾翻译
---@param opts {offset: integer?, length: integer?}? 0 表示从头 / 到末尾；单次 ≤ 8 MB
---@return string? data, string? err
function read_file(path, mode, opts) end

---
---写入**客户端（本机）**上的文件
---@param path string
---@param data string
---@param mode string? "wb"（默认）/ "w" / "a" / "ab"
---@param opts {append: boolean?}?
---@return integer? written, string? err
function write_file(path, data, mode, opts) end
