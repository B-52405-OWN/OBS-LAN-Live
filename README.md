# Stream

本机 OBS 的局域网直播部署，版本见 [VERSION](VERSION)。

- 首次使用：右键 `Configure-Firewall.cmd`，选择“以管理员身份运行”，仅放行局域网观看端口。
- 双击 `Start-Live.cmd`：启动 MediaMTX，切换 OBS 到独立的 **LAN Stream** 配置和场景集合，开始直播。
- 观看端用浏览器打开 `http://主播当前局域网IP:8889/live/`。物理网和蒲公英都使用对应网卡当前的地址。
- 免登录范围、查看地址的方法和防火墙配置见[部署说明](docs/guides/deployment.md)。
- 双击 `Stop-Live.cmd`：停止本项目直播并退出本项目的 MediaMTX；OBS 保留打开。
- 在 OBS 的 **LAN Stream** 场景集合中选择采集场景。`链路测试`用于测试画面与声音，`场景`保留原集合的采集配置副本。
- LAN Stream 的桌面音频、麦克风初始静音；直播时按需在 OBS 混音器解除对应静音。测试视频带低音量测试音。
- WHIP 的音频编码器须保持 **FFmpeg Opus**；启动器会检查，AAC 等编码不匹配时会提示更正。本机观看页面保持静音，避免播放声被桌面音频再次采集。

首次部署与运行原理见 [部署说明](docs/guides/deployment.md)，本次结果见 [部署验收](docs/guides/verification.md)，Agent 约定见 [AGENTS.md](AGENTS.md)。
