# 局域网直播

## 架构

OBS 33.0.1 → WHIP（H.264 + Opus）→ MediaMTX 1.21.3 → WebRTC 浏览器观看。

使用现有 OBS 安装 `C:/Programs/obs-studio/bin/64bit/obs64.exe`。MediaMTX 使用官方 Windows AMD64 独立程序，不依赖 Docker。直播配置与场景集合均命名为 `LAN Stream`，原 `未命名` 配置、场景不覆盖。安装默认采用 1920×1080、30fps、NVENC H.264、6000 kbps 和 Opus 128 kbps 音频。高级输出使用低延迟调优、1 秒关键帧，禁用 B 帧、前瞻和多遍编码。用户后续修改的视频参数由 OBS 保存，启动器不重置。

观看地址采用 `http://主播当前局域网IP:8889/live/`。OBS 的 WHIP 推流地址为 `http://127.0.0.1:8889/live/whip`，令牌为空。

免登录观看范围包括回环和私有 IPv4 网段 `10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16` 以及链路本地网段 `169.254.0.0/16`。发布和管理仅允许回环。主播与观看端之间需要可达的局域网或组网路由。

观看页面和信令使用 TCP 8889，WebRTC 音视频使用 UDP 8189。Windows 防火墙规则按上述 IPv4 范围放行，不绑定固定网卡或单个 IP。

主播和观看端更换私有网段或 IP 后，播放器会使用当前可达地址。主播 IP 变动时，观看端用新地址打开直播页。可以运行 `powershell.exe -NoProfile -File src/Stream.ps1 -Action Status` 查看 `watchUrls` 中列出的地址，并选用观看设备可达的那一个。

FRP 端口映射需要 TCP 页面隧道和 UDP 媒体隧道，并同步可达地址、ICE 媒体端口和页面来源。

若使用虚拟地址看到浏览器用户名/密码弹窗，先检查请求来源网段是否在观看白名单；当前没有为观看设置账号密码，白名单外会返回 401，不能靠填写默认密码解决。

## 操作

1. 双击根目录 `Start-Live.cmd`。
2. OBS 切换至 LAN Stream。原场景集合被复制到 LAN Stream，选择 `场景`可使用原有屏幕来源；测试时选择 `链路测试`。
3. 观看端连接同一局域网，用浏览器打开观看地址。播放器可能需要点击播放或解除静音。
4. 双击 `Stop-Live.cmd` 停止直播及分发服务。也可先在 OBS 停止直播，再运行该入口退出 MediaMTX。

本项目场景集合中的桌面音频和麦克风初始静音，开始正式直播时按需解除；原场景集合的音量和静音状态不改。测试视频带低音量 440 Hz 测试音，默认不在 OBS 本机监听。

**WHIP 音频必须使用 Opus。** 在 OBS「设置 → 输出 → 高级 → 直播/推流」中保持音频编码器为 **FFmpeg Opus**，音频采样率保持 48 kHz、双声道。仅修改分辨率、帧率、视频码率时不要改成 AAC。修改音频编码器后停止直播、应用设置、重新开始，观看端刷新播放器。启动器检查当前输出模式实际使用的音频编码，不匹配时给出更正位置并保存诊断日志；不靠 MediaMTX 显示的轨道名称代替编码检查。

编码检查在 Start-Live.cmd 入口执行；直接点击 OBS 的开始直播按钮时，仍需自行保持正确的音频编码设置。

开启桌面音频前，将主播电脑自己的观看页面静音，防止收到的直播声音再次被采集形成循环回声。麦克风按需手动开启；修复编码不会自动改变用户的静音、增益和监听设置。

Start 发现 OBS 正在进行其他直播、录制或回放缓冲时，不切换配置。重复启动复用已有本项目进程；Stop 只结束具有本项目路径和 PID 记录的 MediaMTX，不退出用户 OBS。

OBS 内置 WebSocket 用于本机启动、停止和查询，沿用其本地密码配置，不对局域网放行端口，不保存密码到项目。MediaMTX 管理 API 仅在 `127.0.0.1:9997` 监听。日志保存在 `dev/artifacts/runtime`，不录制直播内容。

MediaMTX 在使用期间运行，未注册 Windows 服务、计划任务、自启或异常自动拉起。Start/Stop 入口负责其生命周期。

## 安装与维护

主播电脑需安装 Windows x64 桌面版 OBS Studio 33 或更高版本。首次部署时关闭 OBS，双击 `Setup-Live.cmd`，然后确认 Windows 管理员提示以应用局域网防火墙规则。配置入口会按需下载并校验 MediaMTX，创建缺失的 LAN Stream 配置与场景，准备本机 OBS 控制。已有配置可直接复用。

新建场景初始为空。在 OBS 选用 LAN Stream 场景集合，添加想直播的采集源，再运行 `Start-Live.cmd`。配置完成与开播是两个独立操作。若 OBS 装在非标准位置且配置入口未找到它，可在 `config/local.json` 设置 `obsExecutable`。

仅需更新防火墙时，也可以右键 `Configure-Firewall.cmd`，选择“以管理员身份运行”。规则安装成功后，在支持的网段内换网或换 IP 无需再修改防火墙和直播配置。MediaMTX 下载来源见 [MediaMTX 说明](../../vendor/mediamtx/SOURCE.md)。

本次安装状态和验证限制见 [部署验收](verification.md)。运行防火墙配置入口后，以 `dev/artifacts/runtime/firewall-result.json` 与实际规则为准。

音频编码问题的修复与验证见 [2026-11-01 音频修复](../history/2026-11-01-audio.md)。

原 OBS 配置备份在 `dev/artifacts/obs-backup-20261101`，包括 user.ini、原配置文件、原场景与原 WebSocket 设置。回滚时先正常退出 OBS，再恢复所需文件；本项目新增的 LAN Stream 项目可单独删除，不覆盖原项。

## 验证边界

实际验证记录写入 `dev/artifacts`。本机通过局域网 IP 播放只能证明本机链路，其他设备访问还需要独立设备验收；不得据此声称手机已验证。

## 游戏团战掉帧排查

在同一场直播采集两端数据。两台电脑使用自动同步的系统时间，保留平常的游戏、OBS、浏览器和网络设置。保持一位观众，从开打前几秒录到卡顿结束后几秒。

1. 观看端先在 Chrome 打开 `chrome://webrtc-internals`，再打开直播页，让直播标签页保持在前台。
2. 主播在项目目录运行下面的命令，复现团战并留意游戏帧率。脚本通过本机接口采集 OBS 帧率和 MediaMTX WebRTC 会话统计，生成 `dev/artifacts/frame-rate-*.csv`。
3. 观看端记下画面卡顿的大概时刻，切回诊断页，展开 **Create a WebRTC-Internals dump**，点击 **Download the "rtcstats dump"**。保留下载的 `rtcstats_dump.gz`。此文件可能含连接地址和其他 WebRTC 会话的统计，放在 `dev/artifacts` 或保留在本机。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\dev\tools\Measure-LiveFrameRate.ps1 -DurationSeconds 180
```

把两份采样放在同一台电脑上，用 Python 3.11 或更高版本运行分析脚本。把示例文件名替换成实际路径。

```powershell
python .\dev\tools\analyze-live-stall.py .\dev\artifacts\frame-rate-实际文件名.csv .\dev\artifacts\rtcstats_dump.gz
```

分析默认选择两端重叠时段中持续最久的浏览器冻结，其次选择明显的解码帧率下降。如果那段画面与肉眼看到的卡顿时刻不同，可加 `--at "2026-11-15T20:30:25+08:00"` 指定时间。报告列出回环发布丢包、MediaMTX 转发弃帧、观看端丢包和解码耗时，以及 OBS 渲染、编码和输出帧率。MediaMTX 的观看会话计数要求同一个观看连接连续存在，缺少连续样本时对应项显示缺数据。

- `renderMissedFrames` 在团战时增加，先在游戏内限制帧率，给 OBS 渲染留出 GPU 余量。如果现在采集的是整块屏幕，游戏支持时可单独试用「游戏捕获」。每次只改一项，再跑同一段场景对照。
- `encodingSkippedFrames` 增加且当前用 x264，先用相同的分辨率、帧率和码率对比可用的 H.264 硬件编码器。如果硬件编码仍跳帧，可用相同帧率对比降低输出分辨率后的表现。
- 如果两端帧数都正常，仍可能是游戏或采集源送出了重复画面。对照当时的游戏帧率与 OBS 预览。网络丢包能定位到发布段或观看段，细到 Wi-Fi、组网隧道或中间路由时再做路径对照。

参考 [OBS 编码性能排查](https://obsproject.com/kb/encoding-performance-troubleshooting)、[MediaMTX 1.21.3 API](https://github.com/bluenviron/mediamtx/blob/v1.21.3/api/openapi.yaml)、[Chromium RTCStats 导出](https://github.com/chromium/chromium/blob/main/content/browser/webrtc/resources/dump_creator.js)和 [WebRTC 统计规范](https://www.w3.org/TR/webrtc-stats/)。
