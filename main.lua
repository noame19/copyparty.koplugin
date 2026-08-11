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
    ftp_enabled     = false,    -- 是否启用 FTP（默认关，省电+安全）
    require_pass    = false,    -- 是否要求密码（默认匿名访问）
    admin_user      = "admin",  -- 管理员用户名
    admin_pass      = "",       -- 管理员密码（仅在 require_pass=true 时使用）
    readonly        = false,    -- 是否只读
    quiet           = true,     -- 是否安静模式（少打日志）
    enable_thumb    = true,     -- 是否启用缩略图（默认开；Kindle 无 ffmpeg，实际只能生成 jpg/png 封面）
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
    -- 仿 filebrowserplus.koplugin：用 kill -0 PID 验证进程真在
    -- 避免 PID 文件残留但进程已死的误判
    local f = io.open(pid_path, "r")
    if not f then return false end
    local pid = f:read("*l")
    f:close()
    if not pid or pid == "" then
        os.remove(pid_path)
        return false
    end
    local check = os.execute(string.format("kill -0 %s 2>/dev/null", pid))
    if check == 0 or check == true then
        return true
    end
    -- PID 文件残留但进程已死
    os.remove(pid_path)
    return false
end

local function read_pid()
    local f = io.open(pid_path, "r")
    if not f then return nil end
    local pid = f:read("*l")
    f:close()
    return pid
end

local function get_network_info()
    -- 仿 filebrowserplus.koplugin：Device:retrieveNetworkInfo() 在不同平台可能返回
    -- table {ip=...} 或字符串，两种都处理
    if Device.retrieveNetworkInfo then
        local ok, info = pcall(Device.retrieveNetworkInfo, Device)
        if ok and info then
            if type(info) == "table" and info.ip then
                return info.ip
            elseif type(info) == "string" then
                local ip = info:match("(%d+%.%d+%.%d+%.%d+)")
                if ip then return ip end
            end
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

    -- ===========================================================
    -- 边缘设备省资源参数（基于 copyparty v1.20.20 源码调研）
    -- 单核 ARM / 512MB RAM / 慢 eMMC 的 Kindle 必须关掉这些
    -- ===========================================================

    -- 单核强制走线程 broker（避免 multiprocessing 启动开销）
    table.insert(parts, "-j")
    table.insert(parts, "1")

    -- LAN 上禁用 TLS（http-only 模式）
    table.insert(parts, "--http-only")

    -- 关掉开发者调试端点（?reload=cfg / ?scan / ?stack / 启动 voldump）
    -- 这些不是用户功能，是 copyparty 给自己排查用的，关掉减少攻击面
    table.insert(parts, "--no-reload")
    table.insert(parts, "--no-rescan")
    table.insert(parts, "--no-stack")
    table.insert(parts, "--no-voldump")

    -- KOReader 不浏览 zip/tar 内部，也不下载成 zip/tar
    -- 但保留 "下载整个文件夹为 zip" 功能（--zipmaxn/s 限制大小）
    table.insert(parts, "--no-zls")
    table.insert(parts, "--no-tarcmp")
    table.insert(parts, "--zipmaxn")
    table.insert(parts, "9999")
    table.insert(parts, "--zipmaxs")
    table.insert(parts, "4G")

    -- 关 markdown / readme / prologue 渲染（省 jinja2 + marked.js）
    -- KOReader 用户在电脑浏览器看，不在 copyparty 渲染
    table.insert(parts, "--no-readme")
    table.insert(parts, "--no-logues")

    -- 把 HTML 当纯文本显示 + 关 JS 注入（防 XSS，省渲染）
    table.insert(parts, "--no-html")
    table.insert(parts, "--no-script")

    -- http-only 模式下不需要自动签发证书
    table.insert(parts, "--no-crt")

    -- 日志不强制 fsync（省 eMMC 寿命，丢几行无伤大雅）
    table.insert(parts, "--no-logflush")

    -- 缩略图：用户可关（默认开；Kindle 无 ffmpeg 实际只能跑 jpg/png/webp 等纯图片）
    if not get_setting("enable_thumb") then
        table.insert(parts, "--no-thumb")
    end

    -- 数据目录：用 -v 挂载（copyparty 不接受位置参数，必须 -v）
    -- vol 格式: SRC:DST:FLAG
    --   DST 用 "/" 表示根；'.::r'（双冒号）表示空 DST + FLAG=r
    --   copyparty 默认就能列文件（走 httpsrv 常规 VFS）
    --   不传 -e2dsa 就不建 up2k sqlite（省 5 分钟 SHA-512 扫盘 + eMMC 写入）
    local dp = get_setting("data_path")
    local flag = get_setting("readonly") and "r" or ""
    table.insert(parts, "-v")
    table.insert(parts, dp .. ":/:" .. flag)

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

    -- 仿照 SSH.koplugin / filebrowserplus.koplugin：
    -- Kindle 的 INPUT 链默认 policy DROP，必须显式放行端口
    if Device:isKindle() then
        os.execute(string.format("%s %s %s",
            "iptables -A INPUT -p tcp --dport", get_setting("http_port"),
            "-m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT"))
        os.execute(string.format("%s %s %s",
            "iptables -A OUTPUT -p tcp --sport", get_setting("http_port"),
            "-m conntrack --ctstate ESTABLISHED -j ACCEPT"))
        if get_setting("ftp_enabled") then
            os.execute(string.format("%s %s %s",
                "iptables -A INPUT -p tcp --dport", get_setting("ftp_port"),
                "-m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT"))
            os.execute(string.format("%s %s %s",
                "iptables -A OUTPUT -p tcp --sport", get_setting("ftp_port"),
                "-m conntrack --ctstate ESTABLISHED -j ACCEPT"))
        end
    end

    local cmd = build_command()
    -- nohup 防 SIGHUP；& echo $! > pid_file 跟 filebrowserplus 同样的写法
    local full_cmd = string.format(
        "nohup %s > %s 2>&1 & echo $! > %s",
        cmd, log_path, pid_path
    )

    logger.dbg("[Copyparty] 启动命令: ", full_cmd)
    os.execute(full_cmd)

    -- 给点时间让进程起来
    os.execute("sleep 1")

    if is_running() then
        -- 启动成功：复用「当前状态」的 8 行模板，避免两处文案不一致
        -- show_server_info 在文件下方定义
        show_server_info()
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

    -- 收尾：把 Kindle 上的 iptables 规则删掉（仿 filebrowserplus.koplugin）
    if Device:isKindle() then
        os.execute(string.format("%s %s %s",
            "iptables -D INPUT -p tcp --dport", get_setting("http_port"),
            "-m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT"))
        os.execute(string.format("%s %s %s",
            "iptables -D OUTPUT -p tcp --sport", get_setting("http_port"),
            "-m conntrack --ctstate ESTABLISHED -j ACCEPT"))
        if get_setting("ftp_enabled") then
            os.execute(string.format("%s %s %s",
                "iptables -D INPUT -p tcp --dport", get_setting("ftp_port"),
                "-m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT"))
            os.execute(string.format("%s %s %s",
                "iptables -D OUTPUT -p tcp --sport", get_setting("ftp_port"),
                "-m conntrack --ctstate ESTABLISHED -j ACCEPT"))
        end
    end

    UIManager:show(InfoMessage:new{
        text = _("Copyparty 已停止。"),
    })
end

-- ============================================================
-- 显示服务器信息
-- ============================================================
-- ============================================================
-- "当前状态" 弹窗（用户给的 8 行紧凑版）
-- ============================================================
local function show_server_info()
    local running = is_running()
    local ip = get_network_info()
    local http_port = get_setting("http_port")
    local ftp_port = get_setting("ftp_port")
    local ftp_on = get_setting("ftp_enabled")
    local readonly = get_setting("readonly")
    local pass = get_setting("admin_pass")

    -- 严格按用户给的模板，每行字段位置固定
    -- 字段对齐规则（中文2字符宽 ≈ 英文4字符宽）：
    --   "HTTP端口" (5字) + 4 空格
    --   "FTP端口"  (4字) + 4 空格
    --   "模式"     (2字) + 1 空格
    --   "认证"     (2字) + 8 空格
    --   "根目录"   (3字) + 4 空格
    --   "访问地址"  (4字) + 1 空格 + "：" + 1 空格（"访问地址 ："）
    --   URL 独立一行（无缩进）
    local lines = {
        -- 第 1 行
        T(_("Copyparty %1"), running and _("运行中") or _("未运行")),
        -- 第 2 行：HTTP端口
        "  " .. _("HTTP端口") .. "    " .. http_port,
        -- 第 3 行：FTP端口（关闭时附"（关闭）"）
        "  " .. _("FTP端口") .. "    " .. (ftp_on and ftp_port or (ftp_port .. "（关闭）")),
        -- 第 4 行：模式（只读 / 读写）
        "  " .. _("模式") .. " " .. (readonly and _("只读") or _("读写")),
        -- 第 5 行：认证
        "  " .. _("认证") .. "        " .. (pass ~= "" and _("需要密码") or _("匿名无密码")),
        -- 第 6 行：根目录
        "  " .. _("根目录") .. "    " .. get_setting("data_path"),
        -- 第 7 行：访问地址 ：
        "  " .. _("访问地址") .. " ：",
        -- 第 8 行：HTTP URL（独立一行，无缩进）
        "http://" .. ip .. ":" .. http_port .. "/",
    }
    -- FTP 启用时附加 FTP URL（独立一行）
    if ftp_on then
        table.insert(lines, "ftp://" .. ip .. ":" .. ftp_port .. "/")
    end

    UIManager:show(InfoMessage:new{
        text = table.concat(lines, "\n"),
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
-- 旧的 build_settings_items / build_access_info_items 已删除
-- 现在所有项平铺在 addToMainMenu 的 sub_item_table 里（按用户给的最终版）
-- ============================================================

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
    -- 全部项平铺在 Copyparty 顶层（用户最终版）
    -- - 不写 sorting_hint：让 KOReader 默认处理（orphan，"NEW:" 前缀）
    --   之前用 sorting_hint = "filemanager" 触发 MenuSorter 数组越界崩溃
    --   用 sorting_hint = "network" 会跑到 SSH 子菜单里去（不符合用户预期）
    -- - 父菜单项加 checked_func：运行时显示 ✓，停止显示空格（仿 SSH）
    -- - 父菜单项加 hold_callback：长按 Copyparty 这一行也能启动/停止（仿 SSH）
    -- - 运行时灰掉配置项（除运行 toggle、当前状态、缩略图、开机自启）
    -- - 所有 callback 项 keep_menu_open=true（弹窗不关闭菜单，仿 SSH）
    -- - 文案用 text_func 把当前值拼进去（SSH 风格）
    menu_items.copyparty = {
        text = _("Copyparty"),
        checked_func = function() return is_running() end,
        -- 长按父项也能启动/停止服务（仿 SSH plugin）
        hold_callback = function(touchmenu_instance)
            if is_running() then stop_server() else start_server(self) end
            ffiutil.sleep(1)
            if touchmenu_instance and touchmenu_instance.updateItems then
                touchmenu_instance:updateItems()
            end
        end,
        sub_item_table = {
            -- 主开关：始终可点
            {
                text = _("运行 Copyparty"),
                checked_func = function() return is_running() end,
                keep_menu_open = true,
                callback = function()
                    if is_running() then stop_server() else start_server(self) end
                end,
            },
            -- 操作型：弹窗后保持菜单（仿 SSH 的"SSH public key"）
            {
                text = _("当前状态"),
                keep_menu_open = true,
                callback = function() show_server_info() end,
            },
            -- 配置项：运行时灰掉
            {
                text = _("启用缩略图"),
                checked_func = function() return get_setting("enable_thumb") end,
                enabled_func = function() return not is_running() end,
                keep_menu_open = true,
                callback = function()
                    set_setting("enable_thumb", not get_setting("enable_thumb"))
                end,
            },
            {
                text_func = function()
                    return T(_("HTTP/WebDAV端口: %1"), get_setting("http_port"))
                end,
                enabled_func = function() return not is_running() end,
                keep_menu_open = true,
                callback = function()
                    show_port_dialog(
                        _("HTTP/WebDAV 端口"),
                        get_setting("http_port"),
                        function(v) set_setting("http_port", v) end
                    )
                end,
            },
            {
                text = _("启用 FTP"),
                checked_func = function() return get_setting("ftp_enabled") end,
                enabled_func = function() return not is_running() end,
                keep_menu_open = true,
                callback = function()
                    set_setting("ftp_enabled", not get_setting("ftp_enabled"))
                end,
            },
            {
                text_func = function()
                    return T(_("FTP端口: %1"), get_setting("ftp_port"))
                end,
                -- 运行时灰掉 AND 未启用 FTP 时灰掉
                enabled_func = function()
                    return get_setting("ftp_enabled") and not is_running()
                end,
                keep_menu_open = true,
                callback = function()
                    show_port_dialog(
                        _("FTP 端口"),
                        get_setting("ftp_port"),
                        function(v) set_setting("ftp_port", v) end
                    )
                end,
            },
            {
                text_func = function()
                    return T(_("根目录: %1"), get_setting("data_path"))
                end,
                enabled_func = function() return not is_running() end,
                keep_menu_open = true,
                callback = function()
                    show_text_dialog(
                        _("根目录"),
                        get_setting("data_path"),
                        function(v) set_setting("data_path", v) end
                    )
                end,
            },
            {
                text_func = function()
                    return T(_("用户名: %1"), get_setting("admin_user"))
                end,
                -- 运行时灰掉（密码已设置时才有意义，但运行时仍不能改）
                enabled_func = function() return not is_running() end,
                keep_menu_open = true,
                callback = function()
                    show_text_dialog(
                        _("用户名"),
                        get_setting("admin_user"),
                        function(v) set_setting("admin_user", v) end
                    )
                end,
            },
            {
                text_func = function()
                    local p = get_setting("admin_pass")
                    return T(_("密码: %1"), p == "" and _("未设置") or _("已设置"))
                end,
                enabled_func = function() return not is_running() end,
                keep_menu_open = true,
                callback = function()
                    -- 永远不显示已设密码，让用户重新输入
                    -- 输入空字符串 = 取消密码（删除 require_pass 逻辑依赖）
                    show_text_dialog(
                        _("密码（输入空 = 无密码）"),
                        "",
                        function(v) set_setting("admin_pass", v) end,
                        true  -- password mode
                    )
                end,
            },
            {
                text = _("文件只读"),
                checked_func = function() return get_setting("readonly") end,
                enabled_func = function() return not is_running() end,
                keep_menu_open = true,
                callback = function()
                    set_setting("readonly", not get_setting("readonly"))
                end,
            },
            {
                text = _("启用安静日志"),
                checked_func = function() return get_setting("quiet") end,
                enabled_func = function() return not is_running() end,
                keep_menu_open = true,
                callback = function()
                    set_setting("quiet", not get_setting("quiet"))
                end,
            },
            -- 始终可点（仿 SSH autostart：运行中也能切）
            {
                text = _("开机自启"),
                checked_func = function() return get_setting("autostart") end,
                keep_menu_open = true,
                callback = function()
                    set_setting("autostart", not get_setting("autostart"))
                end,
            },
        },
    }
end

return Copyparty