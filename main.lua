-- main.lua — Copyparty plugin for KOReader
-- 把 Kindle 变成文件服务器：HTTP / WebDAV / FTP 三协议同时跑
-- 用纯 Python 的 copyparty-sfx.py (1.2MB)，依赖 KOReader 之外的 python3
--
-- Author: <you>
-- License: MIT (继承自上游 copyparty, https://github.com/9001/copyparty)
-- Copyparty version bundled: v1.20.20
-- 协议说明（说人话）：
--   HTTP  —— 浏览器打开看/传文件
--   WebDAV —— 电脑资源管理器挂载成网络盘，不用装客户端
--   FTP —— 老式文件传输协议，给老设备用

local BD = require("ui/bidi")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiutil = require("ffi/util")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiutil.template

-- 路径常量
local data_dir = DataStorage:getFullDataDir()
local plugin_dir = data_dir .. "/plugins/copyparty.koplugin"
local sfx_path = plugin_dir .. "/assets/copyparty-sfx.py"
local log_path = plugin_dir .. "/copyparty.log"
local pid_path = "/tmp/copyparty_koreader.pid"

-- 检查 sfx.py 是否存在；不存在就禁用插件
if not util.pathExists(sfx_path) then
    logger.info("[Copyparty] assets/copyparty-sfx.py 缺失，插件禁用")
    return { disabled = true }
end

-- 确保 assets 目录可执行
os.execute("chmod +x " .. sfx_path)

-- ============================================================
-- 默认设置
-- ============================================================
local DEFAULTS = {
    http_port       = "3923",   -- HTTP/WebDAV 主端口
    ftp_port        = "3921",   -- FTP 端口（仅在启用 FTP 时使用）
    data_path       = "/mnt/us",-- 默认数据目录（Kindle 用户区）
    autostart       = false,    -- 开机自启
    ftp_enabled     = true,     -- 是否启用 FTP
    require_pass    = false,    -- 是否要求密码（默认匿名访问）
    admin_user      = "admin",  -- 管理员用户名
    admin_pass      = "",       -- 管理员密码（仅在 require_pass=true 时使用）
    readonly        = false,    -- 是否只读
    quiet           = true,     -- 是否安静模式（少打日志）
}

-- ============================================================
-- 读取设置（含默认值回退）
-- ============================================================
local function get_setting(key)
    local val = G_reader_settings:readSetting("Copyparty_" .. key)
    if val == nil then return DEFAULTS[key] end
    if type(DEFAULTS[key]) == "boolean" then
        return G_reader_settings:isTrue("Copyparty_" .. key)
    end
    return val
end

local function set_setting(key, val)
    G_reader_settings:saveSetting("Copyparty_" .. key, val)
end

-- ============================================================
-- 状态查询
-- ============================================================
local function is_running()
    return util.pathExists(pid_path)
end

local function read_pid()
    local f = io.open(pid_path, "r")
    if not f then return nil end
    local pid = f:read("*l")
    f:close()
    return pid
end

local function get_network_info()
    if Device.retrieveNetworkInfo then
        local ok, info = pcall(Device.retrieveNetworkInfo, Device)
        if ok and info and info ~= "" then
            return info
        end
    end
    return _("未能获取 IP（请确认 WiFi 已连接）")
end

-- ============================================================
-- 启动 / 停止 服务
-- ============================================================
local function build_command()
    local parts = { "python3", sfx_path }

    -- 监听端口
    table.insert(parts, "-p")
    table.insert(parts, get_setting("http_port"))

    -- 监听接口：0.0.0.0 = 接受所有连接（局域网内）
    table.insert(parts, "-i")
    table.insert(parts, "0.0.0.0")

    -- FTP
    if get_setting("ftp_enabled") then
        table.insert(parts, "--ftp")
        table.insert(parts, get_setting("ftp_port"))
    end

    -- 安静模式
    if get_setting("quiet") then
        table.insert(parts, "-q")
    end

    -- 密码（如果开启）
    if get_setting("require_pass") then
        local user = get_setting("admin_user")
        local pass = get_setting("admin_pass")
        if user and pass and pass ~= "" then
            table.insert(parts, "-a")
            table.insert(parts, user .. ":" .. pass)
        end
    end

    -- 只读模式（通过 volume 标志实现）
    if get_setting("readonly") then
        local dp = get_setting("data_path")
        table.insert(parts, "-v")
        table.insert(parts, dp .. ":/:r")
    end

    -- 数据路径（最后一个位置参数）
    table.insert(parts, get_setting("data_path"))

    return table.concat(parts, " ")
end

local function start_server(self)
    if is_running() then
        UIManager:show(InfoMessage:new{
            icon = "notice-info",
            text = _("Copyparty 已经在跑了。"),
        })
        return
    end

    -- 确保日志目录存在
    os.execute("mkdir -p " .. plugin_dir)

    local cmd = build_command()
    -- 把进程丢到后台，日志写文件，PID 写文件
    local full_cmd = string.format(
        "%s > %s 2>&1 & echo $! > %s",
        cmd, log_path, pid_path
    )

    logger.dbg("[Copyparty] 启动命令: ", full_cmd)
    os.execute(full_cmd)

    -- 给点时间让进程起来
    os.execute("sleep 1")

    if is_running() then
        local info_text = T(_("Copyparty 已启动\n\nHTTP/WebDAV: 端口 %1\nFTP: %2\n数据目录: %3\n\n%4"),
            get_setting("http_port"),
            get_setting("ftp_enabled") and get_setting("ftp_port") or _("关闭"),
            get_setting("data_path"),
            get_network_info())
        UIManager:show(InfoMessage:new{
            timeout = 10,
            text = info_text,
        })
    else
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("Copyparty 启动失败。\n请查看日志：%1"), log_path),
        })
    end
end

local function stop_server()
    if not is_running() then
        UIManager:show(InfoMessage:new{
            icon = "notice-info",
            text = _("Copyparty 没在跑。"),
        })
        return
    end

    local pid = read_pid()
    if pid then
        -- 优雅退出（SIGTERM）
        os.execute("kill " .. pid .. " 2>/dev/null")
        os.execute("sleep 1")
        -- 还在就强杀
        if util.pathExists(pid_path) then
            os.execute("kill -9 " .. pid .. " 2>/dev/null")
        end
    end
    os.remove(pid_path)

    UIManager:show(InfoMessage:new{
        text = _("Copyparty 已停止。"),
    })
end

-- ============================================================
-- 显示服务器信息
-- ============================================================
local function show_server_info()
    local status = is_running() and _("运行中") or _("未运行")
    local lines = {
        _("Copyparty 服务状态"),
        "",
        T(_("状态: %1"), status),
        "",
        T(_("HTTP/WebDAV 端口: %1"), get_setting("http_port")),
    }
    if get_setting("ftp_enabled") then
        table.insert(lines, T(_("FTP 端口: %1"), get_setting("ftp_port")))
    else
        table.insert(lines, _("FTP: 关闭"))
    end
    table.insert(lines, T(_("数据目录: %1"), get_setting("data_path")))
    if get_setting("readonly") then
        table.insert(lines, _("模式: 只读"))
    end
    if get_setting("require_pass") then
        table.insert(lines, _("认证: 需要密码"))
    else
        table.insert(lines, _("认证: 匿名（无密码）"))
    end
    table.insert(lines, "")
    table.insert(lines, _("网络信息:"))
    table.insert(lines, get_network_info())
    table.insert(lines, "")
    table.insert(lines, _("访问地址:"))
    table.insert(lines, T(_("http://<你的 IP>:%1/"), get_setting("http_port")))
    if get_setting("ftp_enabled") then
        table.insert(lines, T(_("ftp://<你的 IP>:%1/"), get_setting("ftp_port")))
    end
    table.insert(lines, "")
    table.insert(lines, _("WebDAV 地址（同 HTTP 端口）:"))
    table.insert(lines, T(_("http://<你的 IP>:%1/"), get_setting("http_port")))

    UIManager:show(InfoMessage:new{
        text = table.concat(lines, "\n"),
    })
end

-- ============================================================
-- 显示日志（最近 50 行）
-- ============================================================
local function show_log()
    local f = io.open(log_path, "r")
    local content = _("（暂无日志）")
    if f then
        local lines = {}
        for line in f:lines() do
            table.insert(lines, line)
        end
        f:close()
        if #lines > 0 then
            local start = math.max(1, #lines - 49)
            local buf = {}
            for i = start, #lines do
                table.insert(buf, lines[i])
            end
            content = table.concat(buf, "\n")
        end
    end

    UIManager:show(InfoMessage:new{
        text = content,
    })
end

-- ============================================================
-- 输入对话框：端口号
-- ============================================================
local function show_port_dialog(title, current_value, on_save)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = current_value,
        input_type = "number",
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(dialog) end,
                },
            },
            {
                {
                    text = _("确定"),
                    is_enter_default = true,
                    callback = function()
                        local v = dialog:getInputValue()
                        if v and v ~= "" and v:match("^%d+$") then
                            on_save(v)
                        end
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- 输入对话框：文本
local function show_text_dialog(title, current_value, on_save, password_mode)
    local dialog
    local dlg_args = {
        title = title,
        input = current_value,
        buttons = {
            {
                {
                    text = _("取消"),
                    callback = function() UIManager:close(dialog) end,
                },
            },
            {
                {
                    text = _("确定"),
                    is_enter_default = true,
                    callback = function()
                        local v = dialog:getInputValue()
                        if v then on_save(v) end
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    if password_mode then
        dlg_args.password = true
    end
    dialog = InputDialog:new(dlg_args)
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ============================================================
-- 设置菜单
-- ============================================================
local function show_settings_menu(self)
    local function refresh()
        show_settings_menu(self)
    end

    local items = {
        {
            text = T(_("HTTP/WebDAV 端口: %1"), get_setting("http_port")),
            callback = function()
                show_port_dialog(
                    _("HTTP/WebDAV 端口"),
                    get_setting("http_port"),
                    function(v) set_setting("http_port", v); refresh() end
                )
            end,
        },
        {
            text = T(_("FTP: %1"), get_setting("ftp_enabled") and _("开启") or _("关闭")),
            callback = function()
                set_setting("ftp_enabled", not get_setting("ftp_enabled"))
                refresh()
            end,
        },
        {
            text = T(_("FTP 端口: %1（需要先开启FTP）"), get_setting("ftp_port")),
            enabled_func = function() return get_setting("ftp_enabled") end,
            callback = function()
                show_port_dialog(
                    _("FTP 端口"),
                    get_setting("ftp_port"),
                    function(v) set_setting("ftp_port", v); refresh() end
                )
            end,
        },
        {
            text = T(_("数据目录: %1"), get_setting("data_path")),
            callback = function()
                show_text_dialog(
                    _("数据目录（注意权限）"),
                    get_setting("data_path"),
                    function(v) set_setting("data_path", v); refresh() end
                )
            end,
        },
        {
            text = T(_("开机自启: %1"), get_setting("autostart") and _("开") or _("关")),
            callback = function()
                set_setting("autostart", not get_setting("autostart"))
                refresh()
            end,
        },
        {
            text = T(_("需要密码: %1"), get_setting("require_pass") and _("开") or _("关（匿名）")),
            callback = function()
                set_setting("require_pass", not get_setting("require_pass"))
                refresh()
            end,
        },
        {
            text = T(_("管理员用户名: %1"), get_setting("admin_user")),
            enabled_func = function() return get_setting("require_pass") end,
            callback = function()
                show_text_dialog(
                    _("管理员用户名"),
                    get_setting("admin_user"),
                    function(v) set_setting("admin_user", v); refresh() end
                )
            end,
        },
        {
            text = get_setting("admin_pass") ~= "" and _("设置密码（已设置）") or _("设置密码（未设置）"),
            enabled_func = function() return get_setting("require_pass") end,
            callback = function()
                show_text_dialog(
                    _("管理员密码"),
                    get_setting("admin_pass"),
                    function(v) set_setting("admin_pass", v); refresh() end,
                    true  -- password mode
                )
            end,
        },
        {
            text = T(_("只读模式: %1"), get_setting("readonly") and _("开") or _("关")),
            callback = function()
                set_setting("readonly", not get_setting("readonly"))
                refresh()
            end,
        },
        {
            text = T(_("安静模式: %1"), get_setting("quiet") and _("开（推荐）") or _("关（更详细日志）")),
            callback = function()
                set_setting("quiet", not get_setting("quiet"))
                refresh()
            end,
        },
        {
            text = _("返回"),
            callback = function() UIManager:close(self._settings_menu) end,
        },
    }

    self._settings_menu = Menu:new{
        title = _("Copyparty 设置"),
        item_table = items,
    }
    UIManager:show(self._settings_menu)
end

-- ============================================================
-- 主体类
-- ============================================================
local Copyparty = WidgetContainer:extend{
    name = "Copyparty",
    is_doc_only = false,
}

function Copyparty:init()
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()

    if get_setting("autostart") then
        logger.info("[Copyparty] 开机自启已开启，正在启动...")
        start_server(self)
    end
end

function Copyparty:onDispatcherRegisterActions()
    Dispatcher:registerAction("Copyparty_toggle",
        { category = "none", event = "CopypartyToggle", title = _("Copyparty 启动/停止"),
          general = true })
end

function Copyparty:addToMainMenu(menu_items)
    menu_items.copyparty = {
        text = _("Copyparty"),
        sub_item_table = {
            {
                text = is_running() and _("停止 Copyparty") or _("启动 Copyparty"),
                callback = function()
                    if is_running() then stop_server() else start_server(self) end
                end,
            },
            {
                text = _("服务信息"),
                callback = function() show_server_info() end,
            },
            {
                text = _("设置"),
                callback = function() show_settings_menu(self) end,
            },
            {
                text = _("查看日志"),
                callback = function() show_log() end,
            },
        },
    }
end

return Copyparty