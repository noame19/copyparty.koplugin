# Copyparty Plugin for KOReader

把 Kindle / Kobo / 安卓等 KOReader 支持的设备变成一台轻量文件服务器。底层是 [copyparty](https://github.com/9001/copyparty) （46k+ ⭐ 的纯 Python 文件服务器），通过 KOReader 插件外壳拉起，无须额外装 Python 包。

> [!IMPORTANT]
> **本插件的 copyparty 内核版本：v1.20.20**（与上游最新 release 同步）
> 跟随上游更新，详见 [Releases](https://github.com/9001/copyparty/releases)

## 这个插件能干什么

打开菜单 → 一键启动 → 在浏览器或电脑资源管理器里访问 Kindle 上的书和文件。

支持的协议（同时开启，无需切换）：

| 协议 | 怎么用 | 端口 |
|------|--------|------|
| **HTTP** | 浏览器打开看/传/删文件，带缩略图预览、批量下载为 zip | 3923 |
| **WebDAV** | Windows 资源管理器 / macOS Finder 挂载成"网络位置" | 3923（和 HTTP 同一个端口） |
| **FTP** | 老式客户端、路由器文件管理器、NAS 工具 | 3921（可在菜单关闭） |

相比 `filebrowserplus.koplugin`（KUAL 圈最常见的同类方案）的**差异**：

- ✅ **功能多得多**：HTTP + WebDAV + FTP 三协议同时跑，比 filebrowser 的纯 HTTP 实用
- ✅ **缩略图更好**：copyparty 内置 ffmpeg 集成，能给视频缩略图（需要 ffmpeg 二进制）
- ⚠️ **更耗电**：Python 运行时 + 多协议监听，空载 CPU 比 filebrowser 高 30–50%
- ⚠️ **需要装 Python 3**：Kindle 用户得自己装（见下文前置条件）

## 前置条件

### 1. 你的设备已经装了 KOReader

- ✅ 越狱后的 Kindle / Kobo / PocketBook / Android 设备
- ✅ KOReader 通过 [koreader/koreader](https://github.com/koreader/koreader) 安装
- ⚠️ 商店版 KOReader 也行，但需要设备已经解锁 / 有写权限到 `/mnt/us`

### 2. 系统里能找到 `python3` 命令

在 Kindle 上通过 SSH（KOReader 自带 SSH 插件）执行：

```bash
which python3
python3 --version
```

需要看到 Python 3.3 或更高版本。

#### 如果没有 Python 3

Kindle 官方固件不带 Python。常见解决方案：

- **KUAL 用户**：到 [MobileRead 论坛](https://www.mobileread.com/forums/showthread.php?t=341923) 找适配你 Kindle 型号的 `Python3 for Kindle` 包（注意 ARMv7 vs ARM64）
- **KOReader 用户**：到 [kindlemodshelf](https://kindlemodshelf.me/) 的 Python 分类下找社区打包版
- **自己编译**：交叉编译 CPython 到 ARM，目标设备架构要查清楚（Kindle 大多 ARMv7，新 Paperwhite 11 / Scribe 是 ARM64）

> [!WARNING]
> **不要在没有装 Python 的设备上启动插件** —— 启动命令会直接失败，看日志会看到 `python3: not found`。

## 安装

### 方法 A：手动安装（推荐）

1. 打开本仓库的 [Releases 页面](https://github.com/<your-username>/copyparty.koplugin/releases) 下载最新 ZIP
2. 把整个 `copyparty.koplugin` 文件夹（包含 `assets/copyparty-sfx.py`）放到设备的 `koreader/plugins/` 目录下
3. 重启 KOReader
4. 顶部菜单 → 齿轮箱（Gearbox）→ 网络（Network）→ 应该能看到 "Copyparty" 菜单项

### 方法 B：通过 KOReader 插件管理器

如果你装了 [appstore.koplugin](https://github.com/omer-faruq/appstore.koplugin)，可以直接在设备上搜索安装。

## 使用

1. **顶部菜单 → 齿轮箱 → 网络 → Copyparty**
2. 第一次用：选"设置"调整端口 / 数据目录 / 是否要密码
3. 回到上级菜单，选"启动 Copyparty"
4. 屏幕上会弹出你的 Kindle 当前 IP + 端口
5. 在电脑浏览器里输入 `http://192.168.x.x:3923/`（替换为你的 IP）就能看到文件

### 设置菜单里的可选项

| 选项 | 默认 | 说明 |
|------|------|------|
| **HTTP/WebDAV 端口** | 3923 | copyparty 主端口，改端口要确保路由器没封 |
| **FTP** | 开 | 关掉就不启动 FTP 服务 |
| **FTP 端口** | 3921 | FTP 服务端口 |
| **数据目录** | `/mnt/us` | Kindle 用户区；Kobo 用户改成 `/mnt/onboard` |
| **开机自启** | 关 | KOReader 启动时自动拉起 copyparty |
| **需要密码** | 关（无密码匿名） | 开了就用菜单里的"管理员用户名/密码"登录 |
| **管理员用户名** | `admin` | 登录用户名 |
| **设置密码** | 空 | 登录密码（不显示已设值） |
| **只读模式** | 关 | 开了就只能下载/浏览，不能上传或删 |
| **安静模式** | 开（推荐） | 关掉会输出详细日志 |

### 协议使用示例

**HTTP / 浏览器**

```
http://192.168.1.100:3923/
```

**WebDAV / Windows 资源管理器**

1. 打开"此电脑" → "映射网络驱动器"
2. 文件夹填：`http://192.168.1.100:3923/`
3. 勾选"使用其他凭据连接" → 填你设置的用户名密码（如果开了密码）
4. 完成

**FTP / FileZilla 或浏览器**

```
ftp://192.168.1.100:3921/
```

## 卸载步骤

1. 关闭 KOReader（确保 Copyparty 完全停止）
2. SSH 进设备执行 `pkill -f copyparty-sfx.py`（保险）
3. 删除设备的 `koreader/plugins/copyparty.koplugin/` 目录
4. KOReader 设置里的 `Copyparty_*` 项需要手动清理：在设备上 SSH 找到 KOReader 配置文件（通常是 `koreader/settings.lua`），删掉以 `Copyparty_` 开头的行

## 故障排查

### 启动后立刻停止

看日志：`koreader/plugins/copyparty.koplugin/copyparty.log`

常见原因：
- `python3: not found` → 装 Python 3
- `Address already in use` → 端口被占用，换端口或 `pkill -f copyparty`
- `Permission denied` → 80/443 等特权端口 Kindle 上不能用，换 3923 或更高

### 找不到菜单

- 确认 `_meta.lua` 和 `main.lua` 都在 `copyparty.koplugin/` 第一层
- 确认 `assets/copyparty-sfx.py` 文件**没有**被压缩成 zip（要看 `.py` 后缀）
- 确认有读写权限
- 重启 KOReader

### 浏览器打不开

- Kindle 确认连了 WiFi
- 电脑和 Kindle 在**同一个局域网**（不能 Kindle 连 5GHz WiFi 而电脑连 2.4GHz 隔离的网络）
- 试一下防火墙：Kindle 上执行 `iptables -L` 看 INPUT 链是不是被默认拒了

## 资源占用 / 续航参考

| 指标 | 参考值 |
|------|--------|
| **磁盘** | 1.2 MB（插件本身）+ Kindle 用户区大小 |
| **空载 RAM** | 30–60 MB（Python 解释器 + copyparty runtime） |
| **空载 CPU** | 1–3%（多协议监听 + 内存管理） |
| **WiFi 开着但没传输时每小时耗电** | 比单跑 KOReader SSH 多约 5–10% |

**续航建议**：不用的时候别 autostart，要用时再启动 → 用完在菜单里点"停止"。

## 上游 & 致谢

- [copyparty](https://github.com/9001/copyparty) — ed / zaerald（46k+ ⭐，built in Norway 🇳🇴）
- [filebrowserplus.koplugin](https://github.com/patelneeraj/filebrowserplus.koplugin) — 主要参考的插件结构
- [KOReader](https://github.com/koreader/koreader) — 提供插件宿主环境

## License

MIT（同上游 copyparty）。`assets/copyparty-sfx.py` 的版权归 ed 所有。

## 反馈 / 提 Issue

GitHub Issues：<your-repo-url>/issues

提问题时请附：
1. 设备型号和固件版本
2. `python3 --version` 输出
3. `copyparty.log` 内容
4. KOReader 版本