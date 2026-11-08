# Stream 接手说明

OBS 通过本机 WHIP 发布 H.264 和 Opus，MediaMTX 向局域网浏览器提供 WebRTC 播放。观看地址、网段和端口以[部署指南](../guides/deployment.md)为准。

- `src/Stream.ps1` 实现启停、状态检查与防火墙配置。OBS 控制请求由 `src/Obs.ps1` 发送。
- `Setup-Live.cmd` 调用 `src/Setup.ps1`。配置脚本使用已安装的 Windows x64 OBS，补齐独立直播配置和场景，并按 `vendor/mediamtx/release.json` 校验下载。配置阶段使用当前用户，防火墙阶段调用原有 Firewall 入口。`-PrepareOnly` 可单独验证准备阶段。已有 OBS 场景与编码参数以用户设置为准，缺失配置在 OBS 关闭后补齐。
- `config/mediamtx.yml` 管理发布和观看权限。MediaMTX 在建立连接时从网卡获取 ICE 地址，OBS 发布固定走回环。`config/local.json` 保存 OBS 启动与推流参数。
- `src/Stream.ps1` 在 Start 和 Status 时读取当前观看地址。防火墙规则绑定 MediaMTX 程序、观看端口和私有 IPv4 范围。调整网段范围时同步 MediaMTX 阅读权限和防火墙范围。内置播放器走同源请求，WebRTC 跨站来源列表留空。
- OBS 音视频参数由 LAN Stream 配置维护。MediaMTX 和验证日志归 `dev/artifacts`，第三方程序来源见 [MediaMTX 说明](../../vendor/mediamtx/SOURCE.md)。
