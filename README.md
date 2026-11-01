# Stream

本机 OBS 的局域网直播部署，版本见 [VERSION](VERSION)。

- 首次使用：右键 `Configure-Firewall.cmd`，选择“以管理员身份运行”，仅放行局域网观看端口。
- 双击 `Start-Live.cmd`：启动 MediaMTX，切换 OBS 到独立的 **LAN Stream** 配置和场景集合，开始直播。
- 物理局域网观看：**http://192.168.1.6:8889/live**；虚拟局域网观看：**http://172.16.3.2:8889/live**。
- 虚拟网段 172.16.3.0/24 已加入免登录观看范围；其他设备接入需以管理员重新运行 Configure-Firewall.cmd，添加虚拟网卡范围的规则。
- 观看使用 TCP 8889（页面）和 UDP 8189（音视频）。如之前更新过 TCP 媒体防火墙规则，请重新以管理员运行 Configure-Firewall.cmd。
- 双击 `Stop-Live.cmd`：停止本项目直播并退出本项目的 MediaMTX；OBS 保留打开。
- 在 OBS 的 **LAN Stream** 场景集合中选择采集场景。`链路测试`用于测试画面与声音，`场景`保留原集合的采集配置副本。
- LAN Stream 的桌面音频、麦克风初始静音；直播时按需在 OBS 混音器解除对应静音。测试视频带低音量测试音。
- WHIP 的音频编码器须保持 **FFmpeg Opus**；启动器会检查，AAC 等编码不匹配时会提示更正。本机观看页面保持静音，避免播放声被桌面音频再次采集。

首次部署与运行原理见 [部署说明](docs/guides/deployment.md)，本次结果见 [部署验收](docs/guides/verification.md)，Agent 约定见 [AGENTS.md](AGENTS.md)。
