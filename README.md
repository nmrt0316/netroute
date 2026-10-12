# netroute

> Debian 轻量级策略路由管理器：按端口配置回程路由，自动检测，开机自启，一键回滚。

![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Debian-red?logo=debian&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-blue)

## 📖 简介

在旁路由（如 OpenWrt）和主路由共存的局域网中，如果主路由做了端口转发（DNAT）指向内网某台 Debian 主机，由于主机默认网关指向旁路由，回程流量会因路径不对称被主路由丢弃。

`netroute.sh` 通过 `fwmark` + `CONNMARK` + 独立路由表（`table 100`）的组合，把指定端口的回程流量强制引导到主路由，同时**完全不影响其他流量的正常出站**。

## ✨ 特性

- 🔒 **零侵入**：不修改 DNS、不碰网络配置文件、不接管默认网关
- 🚀 **零断网风险**：只标记指定端口，SSH、DNS、普通上网完全不受影响
- 🔧 **交互式菜单**：无需记忆命令，跟着菜单一步步配置
- 🎯 **端口管理**：支持添加、删除、重置端口列表，自动排序去重
- 🛡️ **输入校验**：IP 格式和端口范围严格校验，避免误配
- 🔄 **开机自启**：自动写入 systemd 服务，重启后规则自动恢复
- 🧹 **一键回滚**：清理所有规则，网络瞬间恢复默认状态
- 🌐 **自动检测**：自动识别网卡、本机 IP、默认网关，回程网关可从 `table 100` 中检测

## 🎯 适用场景

```text
                ┌─────────┐
                │  外网   │
                └────┬────┘
                     │ 端口映射
                     ▼
┌─────────────────────────────────────┐
│      主路由 (如 192.168.1.1)        │
└──────┬───────────────────────▲──────┘
       │                       │
       │ DNAT                  │ 回程
       │ 特定端口              │ (table 100)
       ▼                       │
┌──────────────┐               │
│    Debian    │───────────────┘
│(如192.168.1.8)│
└──────┬───────┘
       │
       │ 默认出站
       ▼
┌──────────────┐
│   旁路由     │
│(如192.168.1.2)│
└──────────────┘
```

- 主路由将外网端口 DNAT 到 Debian 的特定端口
- 希望这些特定端口的回包走主路由（如 `192.168.1.1`）
- 其他所有流量（包括 Debian 主动出站）依然走旁路由（如 `192.168.1.2`）

## 📦 安装

```bash
# 1. 下载脚本
sudo curl -fsSL -o /root/netroute.sh https://raw.githubusercontent.com/nmrt0316/netroute/main/netroute.sh

# 2. 修复 Windows 换行符（可选）
sudo sed -i 's/\r$//' /root/netroute.sh

# 3. 赋执行权限
sudo chmod +x /root/netroute.sh

# 4. 运行
sudo /root/netroute.sh
```

> **前置依赖**：`iptables`（Debian 通常自带，若缺失请执行 `apt install iptables`）

## 🚀 使用

```bash
sudo /root/netroute.sh
```

首次运行会自动检测网络环境，输出类似下面的菜单：

```text
==================================================
        回程路由配置菜单
==================================================
系统信息：
  网卡      : eth0
  本机 IP   : 192.168.1.8
  默认网关  : 192.168.1.2
--------------------------------------------------
配置项：
  回程网关  : 未配置
  回程端口  : ———          [需先配置回程网关]
--------------------------------------------------
  1. 设置回程网关
  2. 设置回程端口
  3. 查看详细配置与状态
  4. 清理并恢复默认
  0. 退出
==================================================
请选择 [0-4]: 
```

### 典型配置流程

1. 首次运行 → 选 `1` → 输入主路由 IP（如 `192.168.1.1`）
2. 选 `2` → 输入端口列表（如 `80,443`）
3. 配置自动保存并生效
4. 选 `3` 验证规则是否生效
5. 重启后，规则由 systemd 自动恢复

## 🔍 工作原理

脚本通过三条协同工作的规则实现精细化的回程路由：

1. **`iptables` 标记入站连接**：为从主路由进来的特定端口连接打上 `fwmark 100`。
2. **`ip rule` 策略路由**：让带有 `fwmark 100` 标记的数据包查 `table 100` 路由表。
3. **`table 100` 指定回程网关**：在独立路由表中指定默认网关为主路由。

**为什么不会断网？**
- 只标记特定端口，SSH、DNS 不受影响
- 不修改默认网关，系统默认路由保持指向旁路由
- 不碰系统配置，DNS、网卡配置完全不变

## 📂 文件说明

| 路径 | 用途 |
|---|---|
| `/root/netroute.sh` | 主脚本（菜单 + 应用 + 清理） |
| `/etc/public-return-route.conf` | 保存用户配置（网卡、IP、网关、端口） |
| `/etc/systemd/system/public-return-route.service` | systemd 开机自启服务 |

## ❓ 常见问题

### Q1: 会不会把我的机器搞断网？
**不会。** 脚本只操作 `fwmark`、`table 100` 和 `iptables mangle` 表，完全不碰 DNS、网卡配置和默认路由。就算配置填错，最多是特定端口访问不通，SSH 和内网依然正常。

### Q2: 为什么菜单显示「未配置」但规则明明在生效？
这是 iptables 显示格式差异导致的。脚本已兼容 `--set-mark 100` 和 `--set-xmark 0x64` 两种写法。

### Q3: 支持哪些系统？
目前只在 **Debian 12/13** 上测试通过。理论上兼容使用 `iptables` 和 `systemd` 的其他 Linux 发行版，但未做完整验证。

### Q4: 支持 IPv6 吗？
不支持，脚本只处理 IPv4。

### Q5: 为什么支持这么复杂的策略路由，却完全不担心搞坏系统？
因为它只操作 `fwmark` 和路由表，完全不修改系统默认路由和DNS。最坏的情况只是特定端口不通，你的 SSH 和基础网络永远安全。

## 🧹 卸载 / 回滚

### 方式一：通过菜单清理（推荐）

```bash
sudo /root/netroute.sh
# 选择 4，确认清理
```

### 方式二：手动彻底清理（脚本丢失时使用）

如果不小心删除了 `netroute.sh`，可以手动执行以下命令清理所有残留：

```bash
# 清理路由规则
sudo ip rule del fwmark 100 table 100 2>/dev/null || true
sudo ip route flush table 100 2>/dev/null || true

# 清理 iptables 规则（兼容两种 mark 写法）
sudo iptables -t mangle -S PREROUTING | grep "CONNMARK" | \
    sed 's/^-A //' | while read rule; do
        sudo iptables -t mangle -D $rule 2>/dev/null
    done
sudo iptables -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null || true

# 停止并删除 systemd 服务
sudo systemctl disable --now public-return-route.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/public-return-route.service
sudo systemctl daemon-reload

# 删除配置文件
sudo rm -f /etc/public-return-route.conf
```

## ⚠️ 免责声明

本脚本操作系统的网络层规则。虽然经过谨慎设计，但使用者仍需自行承担风险。建议在生产环境使用前先做好快照或备份。

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📄 License

[MIT](LICENSE)