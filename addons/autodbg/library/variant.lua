---@meta
-- ---------------------------------------------------------------------------
-- AutoDbg.nvim —— LuaLS 注解：LuaVariant / Var 元表与类型构造函数（U8…F64 / V）
--
-- 来源：由 AutoDbg 模块（迁移前）的 generate_templete() 模板原样迁入；
--   之后新增的 API 见 lualib.lua（effects / mcp）与 file_io.lua（read_file / write_file）。
-- 不要 require 本文件：它只给 lua_ls 看（首行 ---@meta）。
-- ---------------------------------------------------------------------------

---@class LuaVariant : userdata
---@field bin string 返回内存中二进制字符序列
---@field hex string 16进制字符串表示
---@field val string 10进制字符串表示
---@field rawval number 数值
---@field type string 类型
local LuaVariant = {}

---@type fun(type: string): LuaVariant
---@param type string support i8、u8、i16、u16、i32、u32、i64、u64、f32、f64
---@return LuaVariant
function LuaVariant:as(type) end

---@type fun(type: string): LuaVariant
---@param type string support i8、u8、i16、u16、i32、u32、i64、u64、f32、f64
---@return LuaVariant
function LuaVariant:to(type) end

---
---U8 创建无符号8位LuaVariant，参数可为数字或16进制字符串
---
---@type fun(value: string|number): LuaVariant
function U8(value) end

---
---I8 创建有符号8位LuaVariant
---
---@type fun(value: string|number): LuaVariant
function I8(value) end

---
---U16 创建无符号16位LuaVariant，参数可为数字或16进制字符串
---
---@type fun(value: string|number): LuaVariant
function U16(value) end

---
---I16 创建有符号16位LuaVariant
---
---@type fun(value: string|number): LuaVariant
function I16(value) end

---
---U32 创建无符号32位LuaVariant，参数可为数字或16进制字符串
---
---@type fun(value: string|number): LuaVariant
function U32(value) end

---
---I32 创建有符号32位LuaVariant
---
---@type fun(value: string|number): LuaVariant
function I32(value) end

---
---U64 创建无符号64位LuaVariant
---
---@type fun(value: string|number): LuaVariant
function U64(value) end

---
---I64 创建有符号64位LuaVariant
---
---@type fun(value: string|number): LuaVariant
function I64(value) end

---
---F32 创建32位浮点LuaVariant
---
---@type fun(value: string|number): LuaVariant
function F32(value) end

---
---F64 创建64位浮点LuaVariant
---
---@type fun(value: string|number): LuaVariant
function F64(value) end

---@class Var : userdata
local Var = {}

---
---V 创建指向目标进程内存的Var指针对象
---Var支持: 
--- 1. var[LuaVariant|number]解引用
--- 2. var:off(a)偏移
--- 3. var:to(type[, offset])、var:tos(type, count[, offset])、var:sto(type, count[, offset])、类型化读取
--- 4. var:write(type[, offset])、var:writes(type, count[, offset])、var:swrite(type, count[, offset])、类型化读取
---
---@type fun(addr: LuaVariant): Var
function V(addr) end

---
---@type fun(a: LuaVariant|integer): LuaVariant 偏移
---@param a LuaVariant|integer 解析偏移
---@return LuaVariant
function Var:off(a) end

---
---@type fun(type: string, offset: (LuaVariant|integer)?): LuaVariant 读取类型化数据
---@param type string 类型标识，支持:
---                   'c'=char 'b'=uchar 'h'=short 'H'=ushort 'i'=int 'I'=uint
---                   'q'=longlong 'Q'=ulonglong 'z'=size_t 'f'=float 'd'=double
---@param offset (LuaVariant|integer)? 解析偏移，可选
---@return LuaVariant
function Var:to(type, offset) end

---
---@type fun(type: string, count: LuaVariant|integer, offset: (LuaVariant|integer)?): LuaVariant[] 读取类型化数据数组
---@param type string 类型标识，支持:
---                   'c'=char 'b'=uchar 'h'=short 'H'=ushort 'i'=int 'I'=uint
---                   'q'=longlong 'Q'=ulonglong 'z'=size_t 'f'=float 'd'=double
---@param count LuaVariant|integer 解析数量
---@param offset (LuaVariant|integer)? 解析偏移，可选
---@return LuaVariant[]
function Var:tos(type, count, offset) end

---
---@type fun(type: string, count: LuaVariant|integer, offset: (LuaVariant|integer)?): LuaVariant[] 读取字符串数据
---@param type string 类型标识，支持:
---                   's'=utf8字符串 'b'=字节数据 'w'=utf16-le字符串
---@param count LuaVariant|integer 解析字符串长度数量
---@param offset (LuaVariant|integer)? 解析偏移，可选
---@return string
function Var:sto(type, count, offset) end

---
---@type fun(val: LuaVariant|number, offset: (LuaVariant|integer)?) 写入类型化数据
---@param val LuaVariant|number 待写入的值
---@param offset (LuaVariant|integer)? 解析偏移，可选
function Var:write(val, offset) end

---
---@type fun(vals: (LuaVariant|number)[], offset: (LuaVariant|integer)?) 写入类型化数据数组
---@param vals (LuaVariant|number)[] 待写入的值数组
---@param offset (LuaVariant|integer)? 解析偏移，可选
function Var:writes(vals, offset) end

---
---@type fun(val: string, offset: (LuaVariant|integer)?) 写入字节数组数据
---@param val string 字节数组
---@param offset (LuaVariant|integer)? 解析偏移，可选
function Var:swrite(val, offset) end
