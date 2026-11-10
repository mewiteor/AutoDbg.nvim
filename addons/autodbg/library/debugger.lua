---@meta
-- ---------------------------------------------------------------------------
-- AutoDbg.nvim —— LuaLS 注解：29 个契约全局（Run / SetBreakpoint / ReadMemory …）与它们用到的类
--
-- 来源：由 AutoDbg 模块（迁移前）的 generate_templete() 模板原样迁入；
--   之后新增的 API 见 lualib.lua（effects / mcp）与 file_io.lua（read_file / write_file）。
-- 不要 require 本文件：它只给 lua_ls 看（首行 ---@meta）。
-- ---------------------------------------------------------------------------

---
---Run 启动调试进程并进入调试循环（阻塞直到进程退出或按键退出）
---按Shift+Q分离进程不终止，按Q终止进程
---
---@class RunOpt
---@field imagepath string? 程序路径
---@field cmdline string? 命令行（含imagepath时可省略imagepath）
---@field cwd string? 工作目录
---@field is_new_console boolean? 是否新建控制台窗口
---@field use_scylla_hide boolean? 是否使用ScyllaHide反反调试
---@field callback fun(pid: LuaVariant, tid: LuaVariant)? 入口断点回调
---@field exception_callback fun(info: ExceptInfo)? 异常回调
---@field on_any_debug_event fun(opt: OnEnvWithCode)? Debug 任意调试事件回调
---@field on_exception fun(opt: OnEnvWithCodeAndAddr)? Debug 任意异常事件回调
---@field on_breakpoint fun(opt: OnEnvWithAddr)? Debug 任意断点事件回调
---@field on_single_step fun(opt: OnEnvWithAddr)? Debug 任意单步事件回调
---@field on_create_thread fun(opt: OnEnvWithAddr)? Debug 创建线程事件回调
---@field on_create_process fun(opt: OnCreateProcess)? Debug 创建进程事件回调
---@field on_exit_thread fun(opt: OnEnvWithCode)? Debug 线程退出事件回调
---@field on_exit_process fun(opt: OnEnvWithCode)? Debug 进程退出事件回调
---@field on_load_dll fun(opt: OnLoadDll)? Debug 加载dll事件回调
---@field on_unload_dll fun(opt: OnUnloadDll)? Debug 卸载dll事件回调
---@field on_output_debug_string fun(opt: OnOutputDebugString)? Debug 输出调试字符串事件回调
---@field on_rip fun(opt: OnRip)? Debug RIP 事件回调
---@field on_console_event fun(opt: OnConsoleEvent)? 终端事件回调
---
---@type fun(opt: RunOpt)
function Run(opt) end

---
---Attach 附加调试进程并进入调试循环
---按Shift+Q分离进程不终止，按Q终止进程
---
---@class AttachOpt
---@field pid integer? 程序pid
---@field callback fun(pid: LuaVariant, tid: LuaVariant)? 入口断点回调
---@field exception_callback fun(info: ExceptInfo)? 异常回调
---@field on_any_debug_event fun(opt: OnEnvWithCode)? Debug 任意调试事件回调
---@field on_exception fun(opt: OnEnvWithCodeAndAddr)? Debug 任意异常事件回调
---@field on_breakpoint fun(opt: OnEnvWithAddr)? Debug 任意断点事件回调
---@field on_single_step fun(opt: OnEnvWithAddr)? Debug 任意单步事件回调
---@field on_create_thread fun(opt: OnEnvWithAddr)? Debug 创建线程事件回调
---@field on_create_process fun(opt: OnCreateProcess)? Debug 创建进程事件回调
---@field on_exit_thread fun(opt: OnEnvWithCode)? Debug 线程退出事件回调
---@field on_exit_process fun(opt: OnEnvWithCode)? Debug 进程退出事件回调
---@field on_load_dll fun(opt: OnLoadDll)? Debug 加载dll事件回调
---@field on_unload_dll fun(opt: OnUnloadDll)? Debug 卸载dll事件回调
---@field on_output_debug_string fun(opt: OnOutputDebugString)? Debug 输出调试字符串事件回调
---@field on_rip fun(opt: OnRip)? Debug RIP 事件回调
---@field on_console_event fun(opt: OnConsoleEvent)? 终端事件回调
---
---@type fun(callback: function): nil
function Attach(callback) end
---@type fun(opt: AttachOpt): nil
function Attach(opt) end

---
---Detach 脱离调试进程
---
---@type fun()
function Detach() end

---
---Kill 杀死调试进程
---
---@type fun()
function Kill() end

---
---ForceKill 强制杀死调试进程
---
---@type fun()
function ForceKill() end

---
---SetBreakpoint 设置一个断点，如果模块已加载则立即写入0xCC
---
---@class BpOpt
---@field modname string 模块名（不含路径）
---@field rva LuaVariant 断点RVA
---@field is_single boolean? 是否为一次性断点（触发后自动删除）
---@field callback fun(info: BpInfo)? 断点回调
---
---@class BpInfo
---@field ea LuaVariant 断点地址
---@field modname string 模块名
---@field rva LuaVariant RVA
---@field pid LuaVariant 进程ID
---@field tid LuaVariant 线程ID
---
---@type fun(opt: BpOpt)
function SetBreakpoint(opt) end

---
---SetBreakpoints 批量设置断点
---格式: {[modname] = {[rva: LuaVariant] = {callback?, is_single?}}}
---
---@type fun(breakpoints: table)
function SetBreakpoints(breakpoints) end

---
---DelBreakpoint 删除断点并恢复原始字节
---
---@type fun(ea: LuaVariant)
function DelBreakpoint(ea) end
---@type fun(modname: string, rva: LuaVariant)
function DelBreakpoint(modname, rva) end

---
---SetHardwareBreakpoint 设置硬件断点
---
---@class HwBpOpt
---@field ea LuaVariant 断点地址
---@field index integer? 硬件断点dr寄存器序号，支持0~3
---@field type string 硬件断点类型，支持e: 执行、w: 写入、r: 读写
---@field size integer 硬件断点大小，支持
---@field callback fun(info: HwBpInfo)? 硬件断点回调
---
---@class HwBpInfo
---@field ea LuaVariant 断点地址
---@field pid LuaVariant 进程ID
---@field tid LuaVariant 线程ID
---
---@type fun(opt: HwBpOpt)
function SetHardwareBreakpoint(opt) end

---
---DelHardwareBreakpoint 删除断点并恢复原始字节
---
---@type fun(index: integer?)
function DelHardwareBreakpoint(index) end

---
---EnableBreakpoint 启用已禁用的断点
---
---@type fun(ea: LuaVariant)
function EnableBreakpoint(ea) end
---@type fun(modname: string, rva: LuaVariant)
function EnableBreakpoint(modname, rva) end

---
---DisableBreakpoint 禁用断点（恢复原始字节但不删除记录）
---
---@type fun(ea: LuaVariant)
function DisableBreakpoint(ea) end
---@type fun(modname: string, rva: LuaVariant)
function DisableBreakpoint(modname, rva) end

---
---ReadMemory 读取目标进程内存
---
---@type fun(addr: UZ, size: UZ): table
function ReadMemory(addr, size) end

---
---WriteMemory 修改目标进程内存
---
---@type fun(addr: UZ, new_data: table, is_up_intrin: boolean?)
function WriteMemory(addr, new_data, is_up_intrin) end

---
---GetContext 读取线程上下文
---@class XMM
---@field Low LuaVariant
---@field High LuaVariant
---
---@class Context
---@field ContextFlags LuaVariant
---@field SegGs LuaVariant
---@field SegFs LuaVariant
---@field SegEs LuaVariant
---@field SegDs LuaVariant
---@field SegCs LuaVariant
---@field SegSs LuaVariant
---@field EFlags LuaVariant
---@field Dr0 LuaVariant
---@field Dr1 LuaVariant
---@field Dr2 LuaVariant
---@field Dr3 LuaVariant
---@field Dr6 LuaVariant
---@field Dr7 LuaVariant
---@field Cax LuaVariant
---@field Cbx LuaVariant
---@field Ccx LuaVariant
---@field Cdx LuaVariant
---@field Csi LuaVariant
---@field Cdi LuaVariant
---@field Csp LuaVariant
---@field Cbp LuaVariant
---@field Cip LuaVariant
---@field P1Home LuaVariant
---@field P2Home LuaVariant
---@field P3Home LuaVariant
---@field P4Home LuaVariant
---@field P5Home LuaVariant
---@field P6Home LuaVariant
---@field MxCsr LuaVariant
---@field R8 LuaVariant
---@field R9 LuaVariant
---@field R10 LuaVariant
---@field R11 LuaVariant
---@field R12 LuaVariant
---@field R13 LuaVariant
---@field R14 LuaVariant
---@field R15 LuaVariant
---@field Xmm0 XMM
---@field Xmm1 XMM
---@field Xmm2 XMM
---@field Xmm3 XMM
---@field Xmm4 XMM
---@field Xmm5 XMM
---@field Xmm6 XMM
---@field Xmm7 XMM
---@field Xmm8 XMM
---@field Xmm9 XMM
---@field Xmm10 XMM
---@field Xmm11 XMM
---@field Xmm12 XMM
---@field Xmm13 XMM
---@field Xmm14 XMM
---@field Xmm15 XMM
---@field VectorControla LuaVariant
---@field DebugControla LuaVariant
---@field LastBranchToRipa LuaVariant
---@field LastBranchFromRipa LuaVariant
---@field LastExceptionToRipa LuaVariant
---@field LastExceptionFromRipa LuaVariant
---
---@type fun(tid: LuaVariant): Context
function GetContext(tid) end

---
---SetContext 修改线程上下文
---
---@type fun(tid: LuaVariant, ctx: Context)
function SetContext(tid, ctx) end

---
---Ea2ModnameRva 将有效地址转换为模块名和RVA
---地址不在任何已知模块中则返回nil,nil
---
---@type fun(ea: LuaVariant): string?, LuaVariant?
function Ea2ModnameRva(ea) end

---
---GetModBase 获取模块基址
---无效模块则返回nil
---
---@type fun(name: string): LuaVariant?
function GetModBase(name) end

---
---StackTrace 获取线程调用堆栈
---
---@class StackFrame
---@field ea LuaVariant 有效地址
---@field modname string? 模块名
---@field rva LuaVariant? RVA
---
---@type fun(tid: LuaVariant): StackFrame, ...
function StackTrace(tid) end

---
---LoadStr 读取字符串
---
---@type fun(addr: LuaVariant): string?
function LoadStr(addr) end

---
---Hide 隐藏调试器,以防检测
---
---@type fun()
function Hide() end

---
---FindFuncRva 查找指定dll中指定函数的rva
---
---@type fun(dllname: string, funcname: string): LuaVariant?
function FindFuncRva(dllname, funcname) end

---
---GetCppClassName 读取字符串
---
---@type fun(addr: LuaVariant): string?
function GetCppClassName(addr) end

---
---GetMemoryRegion 获取内存布局
---
---@class MemoryRegion
---@field BaseAddress LuaVariant BaseAddress
---@field AllocationBase LuaVariant AllocationBase
---@field AllocationProtect LuaVariant AllocationProtect
---@field RegionSize LuaVariant RegionSize
---@field State LuaVariant State
---@field Protect LuaVariant Protect
---@field Type LuaVariant Type
---
---@type fun():MemoryRegion[] 
function GetMemoryRegion() end

---
---FindMemory 查找内存
---
---@type fun(pattern: string): (LuaVariant,string), ... 
function FindMemory(pattern) end

---
---ResetDir 清空文件夹
---
---@type fun(to_del_dir: string): boolean 
function ResetDir(to_del_dir) end

---
---BsonEncode bson编码
---
---@type fun(obj: table): string 
function BsonEncode(obj) end

---
---BsonDecode bson解码
---
---@type fun(value: string): table 
function BsonDecode(value) end
