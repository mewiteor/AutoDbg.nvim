---@meta
-- ---------------------------------------------------------------------------
-- AutoDbg.nvim —— LuaLS 注解：文件对象（`open_file`，唯一文件 API）
--
-- 来源：由 AutoDbg 模块（迁移前）的 generate_templete() 模板迁入，随后按 T4/T5 改写：
--   `read_file` / `write_file` + 效果协议在 T5（D44）**已删除**，只剩 `open_file`。
-- 不要 require 本文件：它只给 lua_ls 看（首行 ---@meta）。
-- ---------------------------------------------------------------------------

--- 文件对象（`open_file` 的返回值）。remote 模式下 `f:write` 直接进帧（不占内存），
--- `f:read` 是阻塞 RPC（回调里也能用；超时 → `nil, "timeout"`，取消 → `nil, "cancelled"`）。
---@class AutoDbgFile : userdata
---@field read fun(self: AutoDbgFile, format?: string|integer): string|number|nil, string?
---@field read_line fun(self: AutoDbgFile): string|nil, string?
---@field lines fun(self: AutoDbgFile): fun(): string|nil
---@field seek fun(self: AutoDbgFile, whence?: "set"|"cur"|"end", offset?: integer): integer|nil, string?
---@field tell fun(self: AutoDbgFile): integer
---@field setbuf fun(self: AutoDbgFile, n?: integer): boolean
---@field write fun(self: AutoDbgFile, ...: (string|number)): integer?, string?
---@field flush fun(self: AutoDbgFile): boolean
---@field close fun(self: AutoDbgFile): boolean?, string?
---@field ok fun(self: AutoDbgFile): boolean|nil, string?
local AutoDbgFile = {}

---
---打开**客户端（本机）**上的文件，返回 io 风格的文件对象。
---本地模式：就是真文件；remote 模式：字节在**本机**（帧里传原始字节），
---所以调试回调里也能读写（不需要 yield）。
---
---```lua
---local f, err = open_file("C:/tmp/out.bin", "wb")
---if not f then error(err) end
---f:write(ReadMemory(addr, 0x1000))
---f:close()
---```
---@param path string
---@param mode string? "r"/"rb"（读，默认）/ "w"/"wb"（写）/ "a"/"ab"（追加）
---@return AutoDbgFile? file, string? err
function open_file(path, mode) end
