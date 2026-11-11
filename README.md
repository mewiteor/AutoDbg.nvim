# AutoDbg neovim 插件

把**当前 buffer（或选区）**发到远端 AutoDbg server 执行，结果写进一个 scratch buffer；
`<file>:<line>:` 形式的 Lua 错误行会同时进 quickfix（`:copen` / `]q` 可直达）。

接口约定见 AutoDbg 仓库的 `AGENTS.md` §12（server 选项、`/run` 与 `/effects`、结果字段）；
剩余工作见 `plan_server.md`。

## 依赖

- neovim ≥ 0.10（用到 `vim.system`；本仓库实测 0.12.6）
- `curl`（Windows 10+ 系统自带；各 Linux 发行版都有）
- 一个在跑的 AutoDbg server：
  ```bash
  .out/AutoDbg_64.exe --server            # 127.0.0.1:8642，loopback 免 token
  ```

## 安装

### lazy.nvim

```lua
{
  -- 指向本插件仓库（AutoDbg.nvim）的本地克隆目录
  dir = "~/src/AutoDbg.nvim",
  config = function()
    require("autodbg").setup({ url = "http://127.0.0.1:8642" })
  end,
}
```

### 内置 `vim.pack` / 手工

把本插件目录加到 `runtimepath` 即可，`plugin/autodbg.lua` 会自动注册命令：

```lua
vim.opt.runtimepath:append(vim.fn.expand("~/src/AutoDbg.nvim"))
require("autodbg").setup({ url = "http://127.0.0.1:8642" })
```

## 命令

| 命令 | 作用 |
| --- | --- |
| `:AutoDbgRun` | 执行当前 buffer（**本地或远程**，见下） |
| `:'<,'>AutoDbgRun` | 只执行选区 |
| `:AutoDbgRun <file>` | 执行指定文件（chunkname 用该文件名） |
| `:AutoDbgCancel` | 取消：本地模式 kill 进程；远程模式发 `/cancel`（100 ms 粒度） |
| `:AutoDbgHealth` | 状态：本地报 `exe`/`arch`，远程打 `/health`（`busy`/`queue`） |
| `:AutoDbgHeader [remote\|local]` | 在 buffer 头部插入 `--!autodbg …` 标记（`local` = `exe=… arch=…`） |
| `:AutoDbgLsp [on\|off\|status]` | 手动挂/摘 LuaLS 注解库（默认按脚本标记懒启用） |

## 运行模式：本地 / 远程

插件有两种跑法，**按“能不能拿到 exe”自动选**（`setup{ mode = "auto" }` 是默认）：

```text
脚本里 exe=…  ──┐
setup{ exe }   ──┼─→ 能拿到可执行的 exe ？── 是 ─→ 本地模式（直接跑 exe）
PATH 里的 exe  ──┘                    └─ 否 ─→ 远程模式（HTTP /run，用 url/host/port）
```

- **本地优先**：只要“标记的 exe / `setup.exe` / PATH 里的 `AutoDbg_{64,86}.exe`”三者任一存在，就走本地；
  即使同时写了 `url=` / `host=` / `port=`，也**先试本地**；
- **回落远程**：标记里写了 `exe=` 但那个文件不存在 → 提示一次“找不到 exe，已回退远程”，然后走 `url`；
- **强制**：`setup{ mode = "remote" }` 完全不找 exe；`setup{ mode = "local" }` 则必须本地（找不到就报错，不静默回落）。

本地模式的细节：

- buffer 内容写到系统临时目录的一个临时文件，跑完即删（AutoDbg 的命令行只接受脚本路径）；
  错误信息里的临时路径会被换回你的 buffer 名字，所以 quickfix 跳转照常工作。
- 默认带 `--quiet`（关错误弹窗；headless 下弹 MessageBox 会把进程挂住）：`setup{ local_flags }` 可改。
- flavor 由脚本自己的 `--!lua` / `--!luajit` 决定（与命令行一致）；`--!autodbg` 标记会被 launcher 当**非 flavor 标记跳过**。
- 工作目录 = 有文件名的 buffer 所在目录，否则 nvim 的 cwd。

## 脚本头标记（modeline）

`setup{}` 里的 `url` / `token` / `exe` 只是**默认值**；每个脚本可以在头部（前/后 5 行，必须是 `--` 注释）自己声明：

```lua
--!autodbg exe=C:/tools/AutoDbg_64.exe arch=x64     -- 本地模式（exe 不存在则回落远程）
--!autodbg url=http://192.168.1.10:8642 token=deadbeef   -- 远程模式
--!autodbg host=192.168.1.10 port=8642              -- 只改地址/端口，其余仍用 setup 的
--!autodbg arch=x86                                 -- 只要标记 + 架构（补全按 x86）
--!autodbg                                         -- 裸标记：只表示“这是 AutoDbg 脚本”
-- autodbg: url=http://127.0.0.1:8642               -- modeline 风格也认；`-- adbg:` 是短别名

Run({ imagepath = "C:\\target.exe" })
```

| 键 | 含义 |
| --- | --- |
| `url` | 远程地址（优先于 host/port） |
| `host` / `port` | 只改远程地址的一部分（未给的部分从 setup 的 `url` 里取） |
| `token` | 远程模式的 bearer token（覆盖 `$AUTODBG_TOKEN` / token_file） |
| `exe` | AutoDbg 的 exe 路径 → 走**本地模式** |
| `arch` | `x86` / `x64`（别名 `32`/`64`/`i386`/`amd64`）→ 决定 LuaLS 挂哪份 `Context` 注解 |

- 多行/多键时**后出现的覆盖先出现的**；
- 这个标记同时是 **LuaLS 补全的开关**（只对带标记的 buffer 挂注解），所以**无名 buffer 也能用**；
- 结果表里 `mode` = `"local"` / `"remote"`（怎么跑的），`url_mode` = `"modeline"` / `"setup"`（地址从哪来）。

## LuaLS 补全（取代模块的 `generate_templete`）

本插件自带一个注解库：

```text
nvim/addons/autodbg/
  config.json
  library/{lualib,variant,callbacks,debugger,gui,file_io}.lua   ← 与架构无关（首行 ---@meta）
  arch/x64/context.lua    ← Context 60 项（含 Xmm0-15 / R8-R15 / P1Home…）
  arch/x86/context.lua    ← Context 23 项（没有 Xmm/R8-R15）
```

打开一个**带 `--!autodbg` 标记的 buffer** 时，插件把 `library/` + `arch/<arch>/`
加进 lua_ls 的 `Lua.workspace.library`：`Run` / `SetBreakpoint` / `gui.*` /
`read_file` / `jsonx` / `moses` 等全部有签名与补全，而 AutoDbg 模块本身
**不再往脚本目录写 `cdebugger.d.lua` / `.luarc.json`**。

架构选择顺序：标记 `arch=` → 标记 `exe=` 的文件名（`AutoDbg_86.exe` → x86）→
`setup{ lsp = { arch = … } }` → 默认 **x64**；换架构时插件会把另一份摘掉（两份同时挂着会让
两份 `Context` 定义混在一起）。

```lua
require("autodbg").setup({
  lsp = {
    enable = true,
    arch = nil,              -- "x86" | "x64"；nil = 跟着脚本标记，再缺省 x64
    runtime_version = nil,   -- 例如 "Lua 5.5" / "LuaJIT"；nil = 不改 LuaLS 既有设置
  },
})
```

❗`Lua.workspace.library` 是 **lua_ls 的客户端级（全局）设置**，它不支持“只对某个文件生效”。
所以插件是**懒启用**（没打开过 AutoDbg 脚本就不会动 lua_ls），但一旦启用，本次会话里其它
Lua 文件也会看到这些注解。不想要时：`setup{ lsp = { enable = false } }` 或 `:AutoDbgLsp off`。

## LuaSnip 片段

`lua/autodbg/snippets.lua`（**不硬依赖** LuaSnip；未安装时静默跳过，不影响其它功能）：

```lua
require("autodbg").setup({ snippets = { enable = true } })   -- 在 FileType lua 时自动注册
-- 或者手动：
require("luasnip").add_snippets("lua", require("autodbg.snippets").get())
```

| 触发词 | 内容 |
| --- | --- |
| `adbg` | 脚本头标记（远程：`--!autodbg url=… token=…`） |
| `adbgl` | 脚本头标记（本地：`--!autodbg exe=… arch=x64`） |
| `adrun` | `Run({ imagepath, callback })` |
| `adbp` | `SetBreakpoint({ modname, rva, callback })` |
| `adrunbp` | Run + 入口回调里下断点（最常用组合） |
| `adhw` | `SetHardwareBreakpoint({...})` |
| `adctx` | `local ctx = GetContext(tid)` |
| `admem` | `ReadMemory(addr, size)` |
| `adstack` | `StackTrace(tid)` 追栈 |
| `adexcept` | `Run` + `exception_callback` |
| `adgui` | 找窗口 + 截图 + `write_file` |
| `adclick` | `gui.activate(hwnd)` + `gui.click(x, y)` |
| `adfile` | `read_file` / `write_file` |

## 配置

```lua
require("autodbg").setup({
  url = "http://127.0.0.1:8642",
  token = nil,             -- nil → 依次看 $AUTODBG_TOKEN、token_file
  token_header = "Authorization",
  token_file = nil,        -- 第一行作为 token
  curl = "curl",
  format = "json",         -- json（信息全）| text（只 stdout）
  timeout_ms = 0,          -- curl --max-time（0 = 不设；server 侧另有 --server-timeout）
  sync_timeout_ms = 60000, -- run({ sync = true }) 的超时
  open = "split",          -- split | vsplit | float | none
  focus = true,            -- 结果 buffer 打开后是否跳过去
  keymaps = { run = nil, cancel = nil },   -- 例如 "<leader>dr" / "<leader>dc"
  modeline = { enable = true, head = 5, tail = 5 },  -- 脚本头标记的扫描范围
  mode = "auto",           -- auto（有 exe 就本地）| local（必须本地）| remote（强制远程）
  exe = nil,               -- AutoDbg 的 exe；nil = 去 PATH 里找 exe_names
  exe_names = { "AutoDbg_64.exe", "AutoDbg_86.exe", "AutoDbg.exe", "autodbg.exe" },
  local_flags = { "--quiet" },   -- 本地模式的固定参数（免 headless 被错误弹窗挂住）
  lsp = { enable = true, arch = nil, runtime_version = nil },   -- arch: "x86"|"x64"|nil(跟标记/缺省 x64)
  snippets = { enable = true },                      -- LuaSnip 片段
})
```

非 loopback 的 server 需要 token：

```lua
require("autodbg").setup({ url = "http://192.168.1.10:8642", token = "…" })
```

不知道服务器 IP？让 server 自己告诉你 —— 用 `--server-addr=0.0.0.0:8642` 启动时，
它会在启动横幅里列出**本机各网卡的地址 + 网卡描述**，直接抄一条进脚本头即可：

```text
$ AutoDbg_64.exe --server --server-addr=0.0.0.0:8642 --server-token=abcdefgh
autodbg server: listen=0.0.0.0:8642 (auth: bearer, token abcdefgh)
autodbg server: 本机网卡地址（client 填其中任一条）:
        192.168.0.195    Intel(R) Wi-Fi 6 AX201 160MHz
        172.30.224.1     Hyper-V Virtual Ethernet Adapter
```

## 结果 buffer 长什么样

```text
-- autodbg: ok  exit=0  12ms  lua/modern  req=7
<脚本的 stdout>
--- stderr ---
<脚本的 stderr（core 的 Error*/log_msg 也在这里）>
--- error ---
<Lua 错误（如果失败）>
```

失败时首行会变成 `-- autodbg: FAILED exit=3 … (canceled)`/`(timed out)`/`(output truncated)`。

## 客户端文件 I/O

插件默认用**流式**跑远程脚本（`setup{ stream = true }`），所以客户端文件有两种写法：

### ① `open_file`（推荐：大块数据 / 调试回调里）

```lua
local f, e = open_file("Z:/datas.bin", "wb")
if not f then print("ERROR: " .. e) else
    Attach({ pid = pid, callback = function()
        SetBreakpoint({ modname = "x.dll", rva = 0x1000, callback = function(info)
            local c = GetContext(info.tid)
            f:write(BsonEncode({ vols = V(c.Ccx):tos("d", 130) }))   -- 回调里也能写
        end })
    end })
    f:close()      -- 脚本末尾（回调之外）
end
```

- 数据由**服务端脚本线程直接写进 `/run` 的连接**（帧 + chunked），**不落盘、不占脚本内存**，
  总大小只受磁盘限制；插件收到 `data` 帧就直接追加到本地文件。
- 背压交给 socket：你读得慢就压在发送缓冲，服务端断开就 `f:write` 返回 `nil, err`。
- `print` / `Error*` 也走同一个流，长会话能实时看到输出。
- ❗必须调 `f:close()`；忘了只会收到一条服务端警告（客户端句柄会被插件收尾关闭）。
- 本地模式（有 exe 时）`open_file` 就是真文件，同一份脚本两边都能跑。

### ② `write_file` / `read_file`（一次性、小数据）

只在**非流式**模式（`setup{ stream = false }`）下可用：server 执行到它们会挂起并回
`pending{token, effects}`，插件在本机执行后 `POST /effects?token=…` 送回，最多 16 轮。
**调试回调里不能用**（回调是 C 调用进来的，挂不起协程）——那种场景请用 `open_file`。

## 直接调 API（脚本化）

```lua
local adbg = require("autodbg")
adbg.setup({ url = "http://127.0.0.1:8642" })

-- 同步（返回结果表；适合 CI / 自定义命令）
local res = adbg.run({ sync = true, open = "none" })
print(res.ok, res.exit, res.stdout)

-- 异步（返回 SystemObj；结果走回调/结果 buffer）
adbg.run({ on_done = function(res) vim.print(res.exit) end })
```

结果表字段：`ok / exit / elapsed_ms / stdout / stderr / error / truncated / canceled /
timed_out / flavor / variant / request_id / status / result_buf / qf_count`。

## 无头验收

```powershell
pwsh -File tools/server_test/nvim_smoke.ps1 -Render 64      # 起 server + headless nvim + 断言
```

## 许可证

MIT，见 [`LICENSE`](./LICENSE)。
