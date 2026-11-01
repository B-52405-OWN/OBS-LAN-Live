# 局域网直播

## 架构

OBS 33.0.1 → WHIP（H.264 + Opus）→ MediaMTX 1.21.3 → WebRTC 浏览器观看。

使用现有 OBS 安装 `C:/Programs/obs-studio/bin/64bit/obs64.exe`。MediaMTX 使用官方 Windows AMD64 独立程序，不依赖 Docker。直播配置与场景集合均命名为 `LAN Stream`，原 `未命名` 配置、场景不覆盖。独立配置采用 1920×1080、30fps、NVENC H.264、6000 kbps 和 Opus 128 kbps 音频。高级输出使用低延迟调优、1 秒关键帧，禁用 B 帧、前瞻和多遍编码。

观看地址：`http://192.168.1.6:8889/live`。推流地址：`http://127.0.0.1:8889/live/whip`。OBS 中服务选 WHIP，令牌为空。

当前物理以太网为 192.168.1.6/24；不改变网卡现有的公用网络分类。防火墙仅放行此网卡地址、本地子网的 TCP 8889 与 UDP 8189。服务器的观看权限也仅允许回环和 192.168.1.0/24；发布权限只允许回环。STUN/TURN 不配置，局域网链路不依赖公网服务。

## 操作

1. 双击根目录 `Start-Live.cmd`。
2. OBS 切换至 LAN Stream。原场景集合被复制到 LAN Stream，选择 `场景`可使用原有屏幕来源；测试时选择 `链路测试`。
3. 观看端连接同一局域网，用浏览器打开观看地址。播放器可能需要点击播放或解除静音。
4. 双击 `Stop-Live.cmd` 停止直播及分发服务。也可先在 OBS 停止直播，再运行该入口退出 MediaMTX。

本项目场景集合中的桌面音频和麦克风初始静音，开始正式直播时按需解除；原场景集合的音量和静音状态不改。测试视频带低音量 440 Hz 测试音，默认不在 OBS 本机监听。

Start 发现 OBS 正在进行其他直播、录制或回放缓冲时，不切换配置。重复启动复用已有本项目进程；Stop 只结束具有本项目路径和 PID 记录的 MediaMTX，不退出用户 OBS。

OBS 内置 WebSocket 用于本机启动、停止和查询，沿用其本地密码配置，不对局域网放行端口，不保存密码到项目。MediaMTX 管理 API 仅在 `127.0.0.1:9997` 监听。日志保存在 `dev/artifacts/runtime`，不录制直播内容。

MediaMTX 在使用期间运行，未注册 Windows 服务、计划任务、自启或异常自动拉起。Start/Stop 入口负责其生命周期。

## 安装与维护

第三方来源与校验见 [MediaMTX 来源](../../vendor/mediamtx/SOURCE.md)。程序二进制被 Git 忽略；恢复安装时从所记官方发行版下载，核对 SHA256 后将 mediamtx.exe 解压至 vendor/mediamtx。

首次配置防火墙需要 Windows 管理员权限：右键根目录 `Configure-Firewall.cmd`，选择“以管理员身份运行”。等价命令为 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File src/Stream.ps1 -Action Firewall`。若地址变化，同步 config/mediamtx.yml、观看地址和防火墙范围，再重启服务。

本次安装状态和验证限制见 [部署验收](verification.md)。运行防火墙配置入口后，以 `dev/artifacts/runtime/firewall-result.json` 与实际规则为准。

原 OBS 配置备份在 `dev/artifacts/obs-backup-20261101`，包括 user.ini、原配置文件、原场景与原 WebSocket 设置。回滚时先正常退出 OBS，再恢复所需文件；本项目新增的 LAN Stream 项目可单独删除，不覆盖原项。

## 验证边界

实际验证记录写入 `dev/artifacts`。本机通过局域网 IP 播放只能证明本机链路，其他设备访问还需要独立设备验收；不得据此声称手机已验证。
