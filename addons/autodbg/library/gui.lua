---@meta
-- ---------------------------------------------------------------------------
-- AutoDbg.nvim —— LuaLS 注解：GUI 自动化表 `gui`
--
-- 来源：由 AutoDbg 模块（迁移前）的 generate_templete() 模板原样迁入；
--   之后新增的 API 见 lualib.lua（effects / mcp）与 file_io.lua（read_file / write_file）。
-- 不要 require 本文件：它只给 lua_ls 看（首行 ---@meta）。
-- ---------------------------------------------------------------------------

---@class AutoDbgGui GUI 自动化（pyautogui 等价物）
---坐标一律是屏幕绝对像素；hwnd 用整数；失败返回 nil, errmsg
gui = {}

---@return integer w, integer h 主屏宽高
function gui.size() end
---@return integer r, integer g, integer b
function gui.pixel(x, y) end
---@param opts table? {x=,y=,w=,h=,hwnd=,scale=,format="png"|"bmp"|"raw"}
---@return table|nil shot { w=, h=, format=, data=<二进制> }, string? err
function gui.screenshot(opts) end
---@return integer|nil bytes, string? err
function gui.screenshot_to(path, opts) end
---@return integer x, integer y
function gui.position() end
---@return boolean ok
function gui.move(x, y, duration_ms) end
---gui.click([x, y][, "left"|"right"|"middle"][, times])
---@return boolean ok
function gui.click(...) end
---@return boolean ok
function gui.down(button) end
---@return boolean ok
function gui.up(button) end
---@return boolean ok
function gui.drag(x, y, button, duration_ms) end
---@return boolean ok
function gui.scroll(delta, x, y) end
---@return boolean ok
function gui.write(text, interval_ms) end
---@param key string 如 "enter" / "f5" / "a" / "ctrl+c"
---@return boolean ok
function gui.press(key, times) end
---@return boolean ok
function gui.hotkey(...) end
---@return boolean ok
function gui.key_down(key) end
---@return boolean ok
function gui.key_up(key) end
---@return table[] { hwnd, pid, title, text, class, x, y, w, h, visible, enabled }
function gui.windows() end
---@return table[] 同上，多一个 id（GetDlgCtrlID）
function gui.children(hwnd) end
---@param spec string|table 标题子串或 {title=,class=,pid=}
---@return integer|nil hwnd, string? err
function gui.find(spec) end
---@return integer hwnd
function gui.active() end
---@return boolean ok
function gui.activate(hwnd) end
---@return boolean ok
function gui.focus(hwnd) end
---@return integer x, integer y, integer w, integer h
function gui.rect(hwnd) end
---@return boolean ok
function gui.set_rect(hwnd, x, y, w, h) end
---@return boolean ok
function gui.show(hwnd, cmd) end
---@return boolean ok
function gui.close(hwnd) end
---@return integer|nil hwnd, string? err
function gui.wait(spec, timeout_ms) end
---@return string
function gui.text(hwnd) end
---@return boolean ok
function gui.set_text(hwnd, text) end
---@return boolean ok
function gui.post(hwnd, msg, wparam, lparam) end
---@return integer result
function gui.send(hwnd, msg, wparam, lparam) end
---@return boolean ok
function gui.click_control(hwnd) end
---@return nil
function gui.sleep(ms) end
---@return integer pid
function gui.foreground_pid() end
---@return boolean ok
function gui.dpi_aware() end
---@return boolean ok
function gui.cursor_locked(lock) end
