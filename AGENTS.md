# Stream

开始工作先读 [README](README.md)、[接手说明](docs/ai/handoff.md)和[部署指南](docs/guides/deployment.md)。

- 使用已安装的 OBS + MediaMTX；OBS 负责采集编码，MediaMTX 负责局域网分发，浏览器使用内置 WebRTC 播放器。
- 优先 OBS 原生 WHIP（H.264 + Opus），不新增转码常驻进程。
- 局域网观看使用 TCP 8889 页面与信令、UDP 8189 音视频。MediaMTX 自动发现主播地址。观看范围遵循部署指南，发布和管理仅允许回环。
- WHIP 音频编码必须为 Opus；启动前检查实际输出模式对应的音频编码，不能仅凭服务器报告的 Opus 轨道或音轨存在判定有效。修改音频后验证静音基线和已知信号的浏览器解码。
- 用户在 OBS 保存的视频分辨率、帧率和码率由 OBS 配置维护，修复音频不覆盖这些设置。保留桌面音频、麦克风的用户静音与监听选择，不自动开启话筒。
- 保留用户原配置，独立维护 LAN Stream 配置和场景集合；修改前备份到 dev/artifacts，禁止提交备份、凭据和运行数据。
- 管理 API 仅绑定回环，公网转发、自启和自动重启均关闭。
- 第三方程序归 vendor/mediamtx，记录来源、版本、许可证和校验；源码使用 src，配置使用 config，验证辅助工具使用 dev/tools。
- 版本单一来源 VERSION。运行状态和诊断归 dev/artifacts，不作为当前设计说明。
