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
| `:AutoDbgRun` | 执行当前 buffer |
| `:'<,'>AutoDbgRun` | 只执行选区 |
| `:AutoDbgRun <file>` | 执行指定文件（chunkname 用该文件名） |
| `:AutoDbgCancel` | 取消正在跑的脚本（server 端 100 ms 粒度） |
| `:AutoDbgHealth` | 看 server 状态（`busy` / `queue`），并打印**实际用的地址** |
| `:AutoDbgHeader` | 在 buffer 头部插入 `--!autodbg url=…` 标记 |
| `:AutoDbgLsp [on\|off\|status]` | 手动挂/摘 LuaLS 注解库（默认按脚本标记懒启用） |

## 在脚本里指定服务器（脚本头标记 / modeline）

`setup{}` 里的 `url` / `token` 只是**默认值**；每个脚本可以在头部（前/后 5 行，必须是 `--` 注释）自己声明：

```lua
--!autodbg url=http://192.168.1.10:8642 token=deadbeef
--!autodbg host=192.168.1.10 port=8642      -- 只改地址/端口，其余仍用 setup 的
--!autodbg                                  -- 裸标记：只表示“这是 AutoDbg 脚本”（地址走 setup）
-- autodbg: url=http://127.0.0.1:8642       -- modeline 风格也认；`-- adbg:` 是短别名

Run({ imagepath = "C:\\target.exe" })
```

- 键只有 `url` / `host` / `port` / `token`；多行/多键时**后出现的覆盖先出现的**。
- 这个标记同时是 **LuaLS 补全的开关**（只对带标记的 buffer 挂注解），所以**无名 buffer 也能用**。
- 想改远程地址又不想动配置？用 `:AutoDbgHeader` 插一行就够（不需要 LuaSnip）。
- 结果表的 `url` / `mode`（`"modeline"` / `"setup"`）会告诉你这次到底连了哪里。

## LuaLS 补全（取代模块的 `generate_templete`）

本插件自带一份 LLS-Addons 结构的注解库：`addons/autodbg/{config.json, library/*.lua}`
（`lualib` / `variant` / `callbacks` / `debugger` / `gui` / `file_io`，首行都是 `---@meta`）。
打开一个**带 `--!autodbg` 标记的 buffer**时，插件把它加进 lua_ls 的 `Lua.workspace.library`：
`Run` / `SetBreakpoint` / `gui.*` / `read_file` / `jsonx` / `moses` 等全部有签名与补全，
而 AutoDbg 模块本身**不再往脚本目录写 `cdebugger.d.lua` / `.luarc.json`**。

```lua
require("autodbg").setup({
  lsp = {
    enable = true,
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
| `adbg` | 脚本头标记（`--!autodbg url=… token=…`，地址与 LSP 开关都靠它） |
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
  lsp = { enable = true, runtime_version = nil },    -- LuaLS 注解库
  snippets = { enable = true },                      -- LuaSnip 片段
})
```

非 loopback 的 server 需要 token：

```lua
require("autodbg").setup({ url = "http://192.168.1.10:8642", token = "…" })
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

## 客户端文件 I/O（server 模式下的 `read_file` / `write_file`）

AutoDbg 的 `read_file` / `write_file` 读写的是**客户端这台机器**上的文件。server 执行到它们时会挂起并回
`pending{token, effects}`，插件自动在本机把 effect 执行掉、`POST /effects?token=…` 送回结果，
直到脚本跑完（最多 16 轮）；挂起前的输出会拼回最终结果，所以看到的是完整 stdout。

- 二进制安全（跨网络走 base64，本地按 `rb`/`wb` 处理）。
- 文本模式（`"r"` / `"w"` / `"a"`）的行尾翻译在**客户端**做，与 `io.open` 语义一致。
- 失败时脚本收到 `nil, errmsg`，可以自己判断。

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
