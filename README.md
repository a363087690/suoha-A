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
- 开启 BBR + fq，优化文件句柄
- 注册 systemd 服务，崩溃自动重启
- 输出节点链接与 Clash Meta 自动择优配置

## 常用命令

```bash
bash suoha.sh                  # 交互菜单（非交互环境直接部署）
bash suoha.sh --install        # 部署；已安装则显示状态
bash suoha.sh --install --force
bash suoha.sh --status
bash suoha.sh --links
bash suoha.sh --update
bash suoha.sh --no-hysteria    # 仅部署 REALITY
bash suoha.sh --uninstall --yes
```

部署完成后：

- 节点链接：`bash suoha.sh --links`
- Clash Meta 配置：`/etc/suoha/clash-meta.yaml`

## 说明

请遵守所在国家或地区的法律法规，仅用于合法用途。
