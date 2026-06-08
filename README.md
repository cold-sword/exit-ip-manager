# exit-ip-manager

Linux 出口IP管理器 — 基于策略路由，一键添加额外出口IP，支持回退。

## 功能

- 交互式菜单，一行命令运行
- 自动检测当前网卡、IP、网关
- 策略路由：新IP走新网关，原IP保留原网关，原有连接不受影响
- `restore` 一键回退到初始状态
- 持久化配置，重启自动恢复
- 适配主流 Linux 发行版

## 快速使用

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/cold-sword/exit-ip-manager/main/exit-ip-manager.sh)
```

## 菜单选项

1. **添加新出口IP** — 输入新IP/前缀和网关，自动配置策略路由
2. **移除出口IP** — 移除指定IP并清理路由
3. **回退到初始状态** — 清除所有更改，恢复原始配置
4. **查看当前状态** — 显示IP、路由、策略规则
5. **退出**

## 工作原理

```
┌─────────────────────────────────┐
│           网卡                   │
│                                 │
│  原IP  (入口/原有服务)            │
│  新IP  (出口)                    │
└────────────┬────────────────────┘
             │
    ┌────────┴────────┐
    │   策略路由规则    │
    │                  │
    │  from 新IP       │──→ 新网关 (全局出口)
    │  from 原IP       │──→ 原网关 (不受影响)
    │  (default)       │──→ 新网关
    └──────────────────┘
```

## 要求

- 任意 Linux 发行版（策略路由通用）
- root 权限
- `iproute2` `curl`（系统自带）

**持久化支持（重启自动恢复）：**

| 系统 | 持久化方式 |
|------|-----------|
| Debian 9+ / Ubuntu | /etc/network/interfaces |
| Ubuntu 18+ (netplan) | netplan + if-up.d |
| RHEL / CentOS 7-9 / Rocky / Alma | NetworkManager dispatcher |
| Fedora | NetworkManager dispatcher |
| Arch / systemd-networkd | networkd-dispatcher |
| Alpine | if-up.d |

## License

MIT
