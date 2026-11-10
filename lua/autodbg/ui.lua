-- =============================================================================
-- nvim/lua/autodbg/ui.lua —— 结果展示（scratch buffer + quickfix 跳转）
--
-- 来源：新写（plan_server.md S3 / §6.1）。
-- 形态：一个可复用的 scratch buffer（`buftype=nofile`），内容 = 头部摘要 + stdout
--   + 可选的 `--- stderr ---` 段；错误行（`<file>:<line>: msg`）同时写进 quickfix，
--   于是 `:copen` / `]q` 能直接跳到脚本的出错行。
-- 高亮：用 extmark 而不是 syntax 文件 —— 内容结构是运行时才知道的，extmark 更直接。
-- =============================================================================

local M = {}

local state = {
  buf = nil, -- 复用的结果 buffer
}

local function ensure_buf()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return state.buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  state.buf = buf
  return buf
end

--- 把结果写进结果 buffer 并（按配置）打开窗口。
-- @param lines   string[]
-- @param marks   { line_index(0-based), hl_group }[]
-- @param how     "split" | "vsplit" | "float" | nil（只更新不打开）
function M.render(lines, marks, how)
  local buf = ensure_buf()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local ns = vim.api.nvim_create_namespace("autodbg")
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(marks or {}) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, m.line, 0, {
      end_col = m.end_col or #(lines[m.line + 1] or ""),
      hl_group = m.hl,
    })
  end

  if how == "split" then
    vim.cmd("sbuffer " .. buf)
  elseif how == "vsplit" then
    vim.cmd("vsplit | buffer " .. buf)
  elseif how == "float" then
    local width = math.min(120, math.max(40, vim.o.columns - 10))
    local height = math.min(30, math.max(8, #lines + 1))
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)
    vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      row = row,
      col = col,
      width = width,
      height = height,
      style = "minimal",
      border = "rounded",
      title = " AutoDbg ",
    })
  end
  return buf
end

--- 从文本里抽 `<file>:<line>: <msg>` 写进 quickfix（不认识的格式忽略）。
function M.set_quickfix(text, default_file)
  local items = {}
  if type(text) ~= "string" then
    text = ""
  end
  for line in (text or ""):gmatch("[^\r\n]+") do
    local file, lnum, msg = line:match("^(.-):(%d+):%s*(.+)$")
    if file and lnum then
      items[#items + 1] = {
        filename = file,
        lnum = tonumber(lnum),
        text = msg,
        type = "E",
      }
    end
  end
  if #items == 0 and default_file then
    return 0
  end
  vim.fn.setqflist({}, " ", { title = "AutoDbg", items = items })
  return #items
end

--- 把带 extmarks 的「纯文本 + 段」拼成行，并返回需要高亮的标记。
-- @return lines, marks
function M.build(res)
  local lines = {}
  local marks = {}

  local head = string.format(
    "-- autodbg: %s  exit=%s  %sms  %s/%s  req=%s%s%s",
    res.ok and "ok" or "FAILED",
    tostring(res.exit),
    tostring(res.elapsed_ms or "-"),
    tostring(res.flavor or "?"),
    tostring(res.variant or "?"),
    tostring(res.request_id or "-"),
    res.truncated and "  (output truncated)" or "",
    res.canceled and "  (canceled)" or (res.timed_out and "  (timed out)" or "")
  )
  lines[#lines + 1] = head
  marks[#marks + 1] = { line = 0, hl = res.ok and "Title" or "DiagnosticError" }

  local function push_block(text, hl)
    -- `vim.json.decode` 的 null → vim.NIL（userdata）→ 调用方应已归一化，这里再兜一层
    if type(text) ~= "string" or text == "" then
      return
    end
    for line in (text .. "\n"):gmatch("(.-)\n") do
      lines[#lines + 1] = line
      if hl then
        marks[#marks + 1] = { line = #lines - 1, hl = hl }
      end
    end
  end

  push_block(res.stdout, nil)

  if type(res.stderr) == "string" and res.stderr ~= "" then
    lines[#lines + 1] = "--- stderr ---"
    marks[#marks + 1] = { line = #lines - 1, hl = "Comment" }
    push_block(res.stderr, "DiagnosticWarn")
  end

  if type(res.error) == "string" and res.error ~= "" then
    lines[#lines + 1] = "--- error ---"
    marks[#marks + 1] = { line = #lines - 1, hl = "Comment" }
    push_block(res.error, "DiagnosticError")
  end

  return lines, marks
end

return M
