# Stream 接手说明

OBS 通过本机 WHIP 发布 H.264 和 Opus，MediaMTX 向局域网浏览器提供 WebRTC 播放。观看地址、网段和端口以[部署指南](../guides/deployment.md)为准。

- `src/Stream.ps1` 实现启停、状态检查与防火墙配置。OBS 控制请求由 `src/Obs.ps1` 发送。
- `config/mediamtx.yml` 管理发布、观看权限及 ICE 地址。`config/local.json` 保存本机地址与防火墙来源范围。调整观看范围时同步两份配置。
- OBS 音视频参数由 LAN Stream 配置维护。MediaMTX 和验证日志归 `dev/artifacts`，第三方程序来源见 [MediaMTX 说明](../../vendor/mediamtx/SOURCE.md)。
