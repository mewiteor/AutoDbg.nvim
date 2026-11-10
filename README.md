# AutoDbg neovim 插件

把**当前 buffer（或选区）**发到远端 AutoDbg server 执行，结果写进一个 scratch buffer；
`<file>:<line>:` 形式的 Lua 错误行会同时进 quickfix（`:copen` / `]q` 可直达）。

对应 `plan_server.md` 的 S3（§6.1）。协议细节见该文档 §4.4 / §4.5；server 的启动见 §4.1。

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
  dir = "C:/Users/lzx/Documents/git/AutoDbgX/nvim",
  config = function()
    require("autodbg").setup({ url = "http://127.0.0.1:8642" })
  end,
}
```

### 内置 `vim.pack` / 手工

把本目录（`nvim/`）加到 `runtimepath` 即可，`plugin/autodbg.lua` 会自动注册命令：

```lua
vim.opt.runtimepath:append("C:/Users/lzx/Documents/git/AutoDbgX/nvim")
require("autodbg").setup({ url = "http://127.0.0.1:8642" })
```

## 命令

| 命令 | 作用 |
| --- | --- |
| `:AutoDbgRun` | 执行当前 buffer |
| `:'<,'>AutoDbgRun` | 只执行选区 |
| `:AutoDbgCancel` | 取消正在跑的脚本（server 端 100 ms 粒度） |
| `:AutoDbgHealth` | 看 server 状态（`busy` / `queue`） |

## 配置

```lua
require("autodbg").setup({
  url = "http://127.0.0.1:8642",
  token = nil,            -- nil → 依次看 $AUTODBG_TOKEN、token_file
  token_file = nil,       -- 第一行作为 token
  curl = "curl",
  format = "json",        -- json（信息全）| text（只 stdout）
  timeout_ms = 0,         -- curl --max-time（0 = 不设；server 侧另有 --server-timeout）
  open = "split",         -- split | vsplit | float | none
  keymaps = { run = "<leader>dr", cancel = "<leader>dc" },
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
