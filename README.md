# exit-ip-manager

Debian/Ubuntu 出口IP管理器 — 基于策略路由，一键添加额外出口IP，支持回退。

## 功能

- 交互式菜单，一键运行
- 自动检测当前网卡、IP、网关
- 策略路由：新IP走新网关，原IP保留原网关（SSH连接不断）
- `restore` 一键回退到初始状态
- 持久化配置，重启自动恢复
- 支持 `/etc/network/interfaces` 和 netplan

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
│  原IP  (SSH入口)                 │
│  新IP  (出口)                    │
└────────────┬────────────────────┘
             │
    ┌────────┴────────┐
    │   策略路由规则    │
    │                  │
    │  from 新IP       │──→ 新网关 (全局出口)
    │  from 原IP       │──→ 原网关 (SSH保留)
    │  (default)       │──→ 新网关
    └──────────────────┘
```

## 要求

- Debian 9+ / Ubuntu 16.04+
- root 权限
- `iproute2` `curl`（系统自带）

## License

MIT
