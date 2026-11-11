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

--------------------------------------------------------------------- 流式文件（大块数据 / 调试回调里用）
--- 文件对象（`open_file` 的返回值）。server 流式模式下 `f:write` 由脚本线程直接写
--- `/run` 的连接（不 yield、不占内存），所以**断点/异常回调里也能用**。
---@class AutoDbgFile : userdata
---@field write fun(self: AutoDbgFile, ...: (string|number)): integer?, string?
---@field flush fun(self: AutoDbgFile): boolean
---@field close fun(self: AutoDbgFile): boolean?, string?
local AutoDbgFile = {}

---
---打开一个**客户端（本机）**上的文件，返回可增量写的文件对象（用法与 `io.open` 一致）。
---本地模式：真文件；server 模式：需要流式请求（插件默认开，头 `X-AutoDbg-Stream: 1`）。
---❗在脚本末尾（调试回调**之外**）调 `f:close()`。
---@param path string
---@param mode string? "wb"（默认）/ "w" / "ab" / "a"
---@return AutoDbgFile? file, string? err
function open_file(path, mode) end
