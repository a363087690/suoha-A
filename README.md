# suoha-A

智能双通道代理一键部署脚本，自动选路、自动降级、开箱可用。

| 通道 | 协议 | 传输 | 默认端口 | 说明 |
| --- | --- | --- | --- | --- |
| 主通道 | VLESS + Vision + REALITY | TCP | 443 | 无需域名和证书，抗封锁 |
| 备通道 | Hysteria2 | UDP/QUIC | 8443 | 弱网/高丢包环境提速 |

## 一键部署

```bash
curl -fsSL https://raw.githubusercontent.com/a363087690/suoha-A/main/suoha.sh -o suoha.sh && bash suoha.sh
```

或：

```bash
wget -O suoha.sh https://raw.githubusercontent.com/a363087690/suoha-A/main/suoha.sh && bash suoha.sh
```

## 要求

- root 权限
- systemd（KVM 等常规 VPS，OpenVZ/LXC 不支持）
- 公网 IPv4 或 IPv6
- 放行 TCP 443 与 UDP 8443

支持三种网络环境：

| 环境 | 监听 | 下发节点 |
| --- | --- | --- |
| 仅 IPv4 | `0.0.0.0` | IPv4 |
| 仅 IPv6 | `[::]` | IPv6 |
| IPv4 + IPv6 | `[::]` 双栈 | IPv4 和 IPv6 各一组，Clash 自动择优 |

## 脚本会自动完成

- 识别系统、CPU 架构、公网 IP（单栈 v4 / 单栈 v6 / 双栈）
- 测速挑选最快的 REALITY 伪装目标（SNI），纯 IPv6 环境按 v6 测速
- 443 / 8443 被占用时自动换端口
- Hysteria2 部署失败自动降级为纯 REALITY
- 开启 BBR + fq，并调整 TCP 缓冲、MTU 探测、端口复用等弱网参数
- Hysteria2 启用 salamander 混淆，降低 UDP 被 QoS/识别的概率
- Clash Meta 启用 `tcp-concurrent`、`unified-delay`，测速选路更贴近实际
- 注册 systemd 服务，崩溃自动重启
- 输出节点链接与 Clash Meta 自动择优配置

## 中国大陆 / 广东移动优化

默认配置已按大陆移动网络调优：

- **REALITY 伪装域名**只保留大陆可访问、支持 TLS 1.3 + HTTP/2 的目标：
  `www.bing.com`、`www.cloudflare.com`、`www.samsung.com`、`www.lovelive-anime.jp`
  已移除 Google 等可能被 SNI 拦截或 DNS 污染的域名。
- **Hysteria2 开启 salamander 混淆**，避免移动网络对裸 QUIC/UDP 的限速与识别。
- **QUIC 关闭 PMTU 探测**并保持 10 秒心跳，减少 PPPoE / 丢包环境下的卡死。
- **服务端 BBR + fq**，放大 TCP 收发缓冲，适合移动网络的高延迟、高丢包链路。
- **Clash 端并发连接 + 统一延迟**，`Auto` 组能更快切到可用的 IPv4/IPv6 或 TCP/UDP 通道。

VPS 位置建议：广东移动优先香港、日本、新加坡，延迟和晚高峰稳定性通常明显好于美西。

## 常用命令

```bash
bash suoha.sh                  # 交互菜单（非交互环境直接部署）
bash suoha.sh --install        # 部署；已安装则显示状态
bash suoha.sh --install --force
bash suoha.sh --upgrade        # 原地升级监听，保留 UUID/密码/端口
bash suoha.sh --status
bash suoha.sh --links
bash suoha.sh --update
bash suoha.sh --no-hysteria    # 仅部署 REALITY
bash suoha.sh --uninstall --yes
```

## 原地升级

已经部署过的机器，如果要把监听从单栈切换成双栈（或反过来），用：

```bash
bash suoha.sh --upgrade
```

- UUID、REALITY 私钥、Hysteria2 密码、端口、证书和 `pinSHA256` 全部保持不变
- 旧 REALITY 节点链接继续可用，只新增/调整 IPv4、IPv6 地址
- 旧版升级时会自动补上 Hysteria2 salamander 混淆，Hysteria2 节点需重新导入
- 旧配置会备份在 `/etc/suoha/backup-时间戳/`，新配置校验失败会自动回滚

如果需要更换凭证（旧客户端全部失效），才使用 `--install --force`。

部署完成后：

- 节点链接：`bash suoha.sh --links`
- Clash Meta 配置：`/etc/suoha/clash-meta.yaml`

## 说明

请遵守所在国家或地区的法律法规，仅用于合法用途。
