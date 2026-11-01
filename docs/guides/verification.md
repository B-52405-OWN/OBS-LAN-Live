# 部署验收

日期：2026-11-01；适用版本：0.1.0。仅记录本次实测，不代表其他网络与设备。

## 已通过

- 官方 MediaMTX 1.21.3 Windows AMD64 包下载 SHA256 与发行资产的 digest 一致。
- OBS 33.0.1 的 LAN Stream 独立配置，WHIP 推送至回环地址；服务器报告 `live` 就绪，轨道为 H.264 High 1920×1080 与 Opus 双声道。
- Playwright Chromium 通过 `http://192.168.1.6:8889/live/` 完成 WebRTC 播放。采样：1920×1080、30fps，解码 286 帧，丢帧 0；视频和音频 packetsLost 均为 0。音频接收 501120 samples，totalAudioEnergy 为 0.0009990895496063234，解除静音后确认非零信号。
- NVENC 编码日志确认 CBR 6000 kbps、关键帧 30 帧（1 秒）、低延迟调优、B 帧 0、前瞻关闭、多遍关闭。
- 重复 Start 返回 Already streaming，复用同一 MediaMTX；Stop 及重复 Stop 成功。停止后 OBS 直播状态为 false，本项目 MediaMTX 进程、TCP 8889/9997 与 UDP 8189 均已释放。
- OBS 保持完整开发界面和原最大化模式，移动到右侧屏幕。原配置与场景的备份保留在 dev/artifacts/obs-backup-20261101；原未命名项目不被覆盖。

原始截图为 `dev/artifacts/playback.png`，运行日志为 `dev/artifacts/runtime`，浏览器控制台原始记录为 `dev/artifacts/browser`，均不提交 Git。

## 未完成

Windows 当前以太网归类为公用网络。管理员方式启动防火墙配置被自动审批拒绝，错误为 `blocked by policy`，因此未创建 Stream-MediaMTX-* 规则。本机访问不经过与其他设备相同的入站路径，不能据此证明手机或其他设备可达。

用户以管理员运行 Configure-Firewall.cmd 后，需在同一局域网的另一台设备打开观看入口，验证 TCP 页面访问、UDP 媒体和声音。没有进行路由器端口映射，没有修改网络类别，没有开启公网服务或自启。

## 已处理的问题

初次启动遇到 OBS GetReplayBufferStatus 返回 604：当前配置没有回放缓冲输出。启动器现在明确识别该状态为“功能不可用”，不影响正常推流；其他失败仍保留日志并报错。原始异常保存在 errors.jsonl。

初次简单输出使用约 8.3 秒的默认关键帧周期，新观众可能等待画面。切换为高级输出并设置 1 秒关键帧、关闭前瞻，重新验证播放与音频通过。

MediaMTX 内置页面没有 favicon，浏览器记录其 404；启停时旧 WHEP 会话也可能记录 404。与媒体错误分开保留，不增加用户通知。
