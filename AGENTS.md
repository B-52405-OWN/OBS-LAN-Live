# Stream

开始工作先读 README.md 和 docs/guides/deployment.md。

- 使用已安装的 OBS + MediaMTX；OBS 负责采集编码，MediaMTX 负责局域网分发，浏览器使用内置 WebRTC 播放器。
- 优先 OBS 原生 WHIP（H.264 + Opus），不新增转码常驻进程。
- 保留用户原配置，独立维护 LAN Stream 配置和场景集合；修改前备份到 dev/artifacts，禁止提交备份、凭据和运行数据。
- 发布仅允许本机；观看仅允许回环和当前局域网。管理 API 仅绑定回环，不启用公网转发、自启或自动重启。
- 第三方程序归 vendor/mediamtx，记录来源、版本、许可证和校验；源码使用 src，配置使用 config，验证辅助工具使用 dev/tools。
- 版本单一来源 VERSION。运行状态和诊断归 dev/artifacts，不作为当前设计说明。
