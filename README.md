# exit-ip-manager

Debian/Ubuntu 出口IP管理器 — 一键添加额外出口IP，基于 Linux 策略路由。

## 功能

- 自动检测当前网卡、IP、网关
- 通过策略路由添加新出口IP，不影响原有IP的SSH连接
- 支持回退到初始状态
- 持久化配置，重启自动恢复
- 支持 `/etc/network/interfaces` 和 netplan

## 快速使用

```bash
# 下载
curl -O https://raw.githubusercontent.com/cold-sword/exit-ip-manager/main/exit-ip-manager.sh
chmod +x exit-ip-manager.sh

# 添加新出口IP
sudo ./exit-ip-manager.sh add 103.140.137.137/25 103.140.137.129

# 查看状态
sudo ./exit-ip-manager.sh status

# 回退
sudo ./exit-ip-manager.sh restore
```

## 工作原理

```
┌─────────────────────────────────────┐
│            ens17 (网卡)              │
│                                     │
│  161.129.35.42/24  (原IP，SSH入口)   │
│  103.140.137.137/25 (新IP，出口)     │
└──────────────┬──────────────────────┘
               │
      ┌────────┴────────┐
      │   策略路由规则    │
      │                  │
      │  from 103.x.x.x  │──→ table 100 → gw 103.140.137.129 (新网关)
      │  from 161.x.x.x  │──→ table 200 → gw 161.129.35.1    (原网关)
      │  (default)       │──→ main      → gw 103.140.137.129 (新网关)
      └──────────────────┘
```

- 新出站连接默认走新IP和新网关
- 原有SSH连接（入口IP）继续走旧网关，不会断开
- 重启后通过 `/etc/network/if-up.d/` 自动恢复

## 命令

| 命令 | 说明 |
|------|------|
| `add <IP/前缀> <网关>` | 添加新出口IP |
| `remove <IP/前缀>` | 移除指定出口IP |
| `restore` | 回退到初始状态 |
| `status` | 查看当前网络状态 |
| `backup` | 手动创建备份 |
| `backups` | 列出所有备份 |
| `restore-from-backup [文件]` | 从备份恢复 |

## 要求

- Debian 9+ / Ubuntu 16.04+
- root 权限（sudo）
- `iproute2`（系统自带）
- `curl`（用于验证出口IP）

## License

MIT
