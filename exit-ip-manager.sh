#!/usr/bin/env bash
set -u

#===============================================================================
# exit-ip-manager — Linux 出口IP管理器（交互菜单版）
# 基于策略路由，一键添加额外出口IP，支持回退。
# 新IP走新网关，原IP保留原网关，原有连接不受影响。
#
# 用法:
#   bash <(curl -fsSL https://raw.githubusercontent.com/cold-sword/exit-ip-manager/main/exit-ip-manager.sh)
#===============================================================================

[[ $EUID -eq 0 ]] || { echo "请使用 root 运行"; exit 1; }

# ── 常量 ────────────────────────────────────────────────────────────────────
APP_NAME="exit-ip-manager"
STATE_DIR="/etc/${APP_NAME}"
BACKUP_DIR="${STATE_DIR}/backups"
MANAGED_IPS_FILE="${STATE_DIR}/managed_ips"
IFUP_SCRIPT="/etc/network/if-up.d/${APP_NAME}"
NM_DISPATCHER_SCRIPT="/etc/NetworkManager/dispatcher.d/90-${APP_NAME}"
NETWORKD_DISPATCHER_SCRIPT="/etc/networkd-dispatcher/routable.d/50-${APP_NAME}"

TABLE_NEW=100
TABLE_ORIG=200

# ── 颜色 ────────────────────────────────────────────────────────────────────
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_WHITE='\033[1;37m'
C_CYAN='\033[1;36m'
C_BLUE='\033[1;34m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
C_GRAY='\033[0;37m'

# ── UI ──────────────────────────────────────────────────────────────────────
line()    { printf "%b%s%b\n" "$C_GRAY"   "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "$C_RESET"; }
subline() { printf "%b%s%b\n" "$C_GRAY"   "────────────────────────────────────────────────────────────" "$C_RESET"; }

header() {
  clear 2>/dev/null || true
  echo
  printf "  %b%s%b\n" "$C_CYAN$C_BOLD" "✦ Exit IP Manager" "$C_RESET"
  printf "  %b出口IP管理器 — 策略路由，一键切换%b\n" "$C_GRAY" "$C_RESET"
  line
}

section() {
  echo
  printf "  %b%s%b\n" "$C_CYAN$C_BOLD" "$1" "$C_RESET"
  subline
}

ok()    { printf "%b  [✓]%b %s\n"   "$C_GREEN"  "$C_RESET" "$*"; }
fail()  { printf "%b  [✗]%b %s\n"   "$C_RED"    "$C_RESET" "$*"; }
info()  { printf "%b  [i]%b %s\n"   "$C_CYAN"   "$C_RESET" "$*"; }
warn()  { printf "%b  [!]%b %s\n"   "$C_YELLOW" "$C_RESET" "$*"; }

kv() {
  printf "  %b%-10s%b %s\n" "$C_GRAY" "$1" "$C_RESET" "$2"
}

menu_item() {
  printf "  %b[%s]%b %s\n" "$C_BLUE$C_BOLD" "$1" "$C_RESET" "$2"
}

pause() {
  echo
  read -r -p "  按回车返回菜单..." _
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    fail "缺少命令: $1，请先安装"
    exit 1
  }
}

for c in ip awk grep cut sed head sort curl ping; do
  need_cmd "$c"
done

mkdir -p "$STATE_DIR" "$BACKUP_DIR"

# ── 网络检测 ────────────────────────────────────────────────────────────────

get_default_iface() {
  ip -4 route show default 2>/dev/null | awk 'NR==1{print $5}'
}

get_default_gateway() {
  ip -4 route show default 2>/dev/null | awk 'NR==1{print $3}'
}

get_ips_on_iface() {
  local iface="$1"
  ip -o -4 addr show dev "$iface" scope global 2>/dev/null | awk '{print $4}'
}

get_exit_ip() {
  curl -s --connect-timeout 5 ifconfig.me 2>/dev/null \
    || curl -s --connect-timeout 5 ip.sb 2>/dev/null \
    || echo "未知"
}

detect_config_type() {
  # 检测当前使用的网络配置系统
  if [ -d /etc/netplan ] && ls /etc/netplan/*.yaml &>/dev/null; then
    echo "netplan"
  elif [ -f /etc/network/interfaces ] && grep -q "iface" /etc/network/interfaces 2>/dev/null; then
    echo "interfaces"
  elif systemctl is-active NetworkManager &>/dev/null; then
    echo "networkmanager"
  elif [ -d /etc/sysconfig/network-scripts ] && ls /etc/sysconfig/network-scripts/ifcfg-* &>/dev/null; then
    echo "sysconfig"
  elif systemctl is-active systemd-networkd &>/dev/null; then
    echo "systemd-networkd"
  else
    echo "unknown"
  fi
}

get_managed_ips() {
  [ -f "$MANAGED_IPS_FILE" ] && cat "$MANAGED_IPS_FILE" 2>/dev/null || true
}

# ── 备份 ────────────────────────────────────────────────────────────────────

create_backup() {
  local tag="$1"
  local backup_file="${BACKUP_DIR}/$(date +%Y%m%d%H%M%S)_${tag}.tar.gz"
  local tmpdir=$(mktemp -d)

  ip route show table all > "$tmpdir/routes.txt" 2>/dev/null || true
  ip rule show > "$tmpdir/rules.txt" 2>/dev/null || true
  ip addr show > "$tmpdir/addr.txt" 2>/dev/null || true

  local ct=$(detect_config_type)
  case "$ct" in
    netplan) cp -r /etc/netplan "$tmpdir/" 2>/dev/null || true ;;
    interfaces)
      cp /etc/network/interfaces "$tmpdir/" 2>/dev/null || true
      [ -d /etc/network/interfaces.d ] && cp -r /etc/network/interfaces.d "$tmpdir/" 2>/dev/null || true
      ;;
    networkmanager)
      cp /etc/NetworkManager/NetworkManager.conf "$tmpdir/" 2>/dev/null || true
      ;;
    sysconfig)
      cp -r /etc/sysconfig/network-scripts "$tmpdir/" 2>/dev/null || true
      ;;
    systemd-networkd)
      cp -r /etc/systemd/network "$tmpdir/" 2>/dev/null || true
      ;;
  esac

  [ -f "$MANAGED_IPS_FILE" ] && cp "$MANAGED_IPS_FILE" "$tmpdir/" || true
  [ -f "$IFUP_SCRIPT" ] && cp "$IFUP_SCRIPT" "$tmpdir/" || true
  [ -f "$NM_DISPATCHER_SCRIPT" ] && cp "$NM_DISPATCHER_SCRIPT" "$tmpdir/" || true

  tar czf "$backup_file" -C "$tmpdir" . 2>/dev/null
  rm -rf "$tmpdir"
  ok "备份已保存: $(basename "$backup_file")"
}

# ── 持久化 ──────────────────────────────────────────────────────────────────

write_ifup_script() {
  cat > "$IFUP_SCRIPT" << 'INNER'
#!/bin/bash
# Auto-generated by exit-ip-manager
MANAGED_IPS_FILE="/etc/exit-ip-manager/managed_ips"
TABLE_NEW=100
TABLE_ORIG=200
[ ! -f "$MANAGED_IPS_FILE" ] && exit 0

while IFS='|' read -r iface ip_cidr gw; do
  [ -z "$iface" ] && continue
  local_ip="${ip_cidr%/*}"

  ip addr add "$ip_cidr" dev "$iface" 2>/dev/null || true
  ip route add default via "$gw" dev "$iface" table $TABLE_NEW 2>/dev/null || true
  ip rule add from "$local_ip" table $TABLE_NEW priority 100 2>/dev/null || true

  ORIG_GW=$(ip -4 route show default dev "$iface" 2>/dev/null | awk 'NR==1{print $3}' || true)
  ORIG_IP=$(ip -o -4 addr show dev "$iface" scope global 2>/dev/null | awk 'NR==1{print $4}' || true)
  if [ -n "$ORIG_GW" ] && [ -n "$ORIG_IP" ]; then
    ip route add default via "$ORIG_GW" dev "$iface" table $TABLE_ORIG 2>/dev/null || true
    ip rule add from "${ORIG_IP%/*}" table $TABLE_ORIG priority 200 2>/dev/null || true
  fi

  ip route replace default via "$gw" dev "$iface" src "$local_ip" 2>/dev/null || true
done < "$MANAGED_IPS_FILE"
INNER
  chmod +x "$IFUP_SCRIPT"
}

persist_interfaces() {
  write_ifup_script
  local iface=$(get_default_iface)
  if ! grep -q "${APP_NAME}" /etc/network/interfaces 2>/dev/null; then
    if grep -q "iface ${iface} inet" /etc/network/interfaces 2>/dev/null; then
      sed -i "/iface ${iface} inet/a \    post-up ${IFUP_SCRIPT}" /etc/network/interfaces
    fi
  fi
  ok "持久化已写入 /etc/network/interfaces"
}

persist_netplan() {
  write_ifup_script
  ok "持久化已通过 ${IFUP_SCRIPT} 实现 (netplan 启动时自动加载)"
}

# NetworkManager dispatcher (RHEL/CentOS 7-9, Fedora 等)
persist_networkmanager() {
  mkdir -p /etc/NetworkManager/dispatcher.d/
  cat > "$NM_DISPATCHER_SCRIPT" << 'NM_INNER'
#!/bin/bash
# Auto-generated by exit-ip-manager
# NetworkManager dispatcher — 网卡 up 时应用策略路由

INTERFACE="$1"
STATUS="$2"
MANAGED_IPS_FILE="/etc/exit-ip-manager/managed_ips"

if [ "$STATUS" != "up" ]; then
  exit 0
fi

TABLE_NEW=100
TABLE_ORIG=200

[ ! -f "$MANAGED_IPS_FILE" ] && exit 0

while IFS='|' read -r iface ip_cidr gw; do
  [ -z "$iface" ] && continue
  [ "$iface" != "$INTERFACE" ] && continue

  local_ip="${ip_cidr%/*}"

  ip addr add "$ip_cidr" dev "$iface" 2>/dev/null || true
  ip route add default via "$gw" dev "$iface" table $TABLE_NEW 2>/dev/null || true
  ip rule add from "$local_ip" table $TABLE_NEW priority 100 2>/dev/null || true

  ORIG_GW=$(ip -4 route show default dev "$iface" 2>/dev/null | awk 'NR==1{print $3}' || true)
  ORIG_IP=$(ip -o -4 addr show dev "$iface" scope global 2>/dev/null | awk 'NR==1{print $4}' || true)
  if [ -n "$ORIG_GW" ] && [ -n "$ORIG_IP" ]; then
    ip route add default via "$ORIG_GW" dev "$iface" table $TABLE_ORIG 2>/dev/null || true
    ip rule add from "${ORIG_IP%/*}" table $TABLE_ORIG priority 200 2>/dev/null || true
  fi

  ip route replace default via "$gw" dev "$iface" src "$local_ip" 2>/dev/null || true
done < "$MANAGED_IPS_FILE"
NM_INNER
  chmod +x "$NM_DISPATCHER_SCRIPT"
  ok "持久化已写入 NetworkManager dispatcher: ${NM_DISPATCHER_SCRIPT}"
}

# sysconfig/ifcfg (RHEL/CentOS 7 旧式无 NetworkManager)
persist_sysconfig() {
  write_ifup_script
  ok "持久化已通过 ${IFUP_SCRIPT} 实现 (需 ifupdown 支持)"
}

# systemd-networkd
persist_networkd() {
  mkdir -p /etc/networkd-dispatcher/routable.d/
  cat > "$NETWORKD_DISPATCHER_SCRIPT" << 'ND_INNER'
#!/bin/bash
# Auto-generated by exit-ip-manager
# networkd-dispatcher — routable 状态时应用策略路由

IFACE="$IFACE"
MANAGED_IPS_FILE="/etc/exit-ip-manager/managed_ips"
TABLE_NEW=100
TABLE_ORIG=200

[ ! -f "$MANAGED_IPS_FILE" ] && exit 0

while IFS='|' read -r m_iface ip_cidr gw; do
  [ -z "$m_iface" ] && continue
  [ "$m_iface" != "$IFACE" ] && continue

  local_ip="${ip_cidr%/*}"

  ip addr add "$ip_cidr" dev "$m_iface" 2>/dev/null || true
  ip route add default via "$gw" dev "$m_iface" table $TABLE_NEW 2>/dev/null || true
  ip rule add from "$local_ip" table $TABLE_NEW priority 100 2>/dev/null || true

  ORIG_GW=$(ip -4 route show default dev "$m_iface" 2>/dev/null | awk 'NR==1{print $3}' || true)
  ORIG_IP=$(ip -o -4 addr show dev "$m_iface" scope global 2>/dev/null | awk 'NR==1{print $4}' || true)
  if [ -n "$ORIG_GW" ] && [ -n "$ORIG_IP" ]; then
    ip route add default via "$ORIG_GW" dev "$m_iface" table $TABLE_ORIG 2>/dev/null || true
    ip rule add from "${ORIG_IP%/*}" table $TABLE_ORIG priority 200 2>/dev/null || true
  fi

  ip route replace default via "$gw" dev "$m_iface" src "$local_ip" 2>/dev/null || true
done < "$MANAGED_IPS_FILE"
ND_INNER
  chmod +x "$NETWORKD_DISPATCHER_SCRIPT"
  ok "持久化已写入 networkd-dispatcher: ${NETWORKD_DISPATCHER_SCRIPT}"
}

persist_unknown() {
  mkdir -p /etc/network/if-up.d/
  write_ifup_script
  ok "持久化已通过 ${IFUP_SCRIPT} 实现"
}

persist_config() {
  local ct=$(detect_config_type)
  case "$ct" in
    interfaces)       persist_interfaces ;;
    netplan)          persist_netplan ;;
    networkmanager)   persist_networkmanager ;;
    sysconfig)        persist_sysconfig ;;
    systemd-networkd) persist_networkd ;;
    *)                persist_unknown ;;
  esac
}

# ── 核心操作 ────────────────────────────────────────────────────────────────

do_status() {
  local iface=$(get_default_iface)
  local current_gw=$(get_default_gateway)
  local exit_ip=$(get_exit_ip)
  local ct=$(detect_config_type)

  header

  section "环境信息"
  kv "网卡"     "${iface:-未检测到}"
  kv "配置方式" "$ct"
  kv "默认网关" "${current_gw:-未知}"
  kv "出口IP"   "${exit_ip}"

  section "网卡IP"
  if [ -n "$iface" ]; then
    get_ips_on_iface "$iface" | while read cidr; do
      local ip_only="${cidr%/*}"
      if [ "$ip_only" = "$exit_ip" ]; then
        printf "  %b●%b %b%s%b  ← 当前出口\n" "$C_GREEN" "$C_RESET" "$C_BOLD" "$cidr" "$C_RESET"
      else
        printf "  ○ %s\n" "$cidr"
      fi
    done
  else
    echo "  (无)"
  fi

  section "策略路由"
  echo -e "  Table ${TABLE_NEW} (新IP):"
  ip route show table $TABLE_NEW 2>/dev/null | sed 's/^/    /' || echo "    (空)"
  echo
  echo -e "  Table ${TABLE_ORIG} (原IP):"
  ip route show table $TABLE_ORIG 2>/dev/null | sed 's/^/    /' || echo "    (空)"

  section "策略规则"
  ip rule show | grep -E "from|lookup (local|main|default|${TABLE_NEW}|${TABLE_ORIG})" | sed 's/^/  /' || true

  if [ -f "$MANAGED_IPS_FILE" ] && [ -s "$MANAGED_IPS_FILE" ]; then
    section "已托管IP"
    while IFS='|' read -r m_iface m_ip m_gw; do
      [ -z "$m_ip" ] && continue
      printf "  %b%s%b → %s (%s)\n" "$C_CYAN" "$m_ip" "$C_RESET" "$m_gw" "$m_iface"
    done < "$MANAGED_IPS_FILE"
  fi

  echo
  line
  pause
}

do_add() {
  local iface=$(get_default_iface)
  local orig_gw=$(get_default_gateway)
  local orig_cidr=$(get_ips_on_iface "$iface" | head -1)
  local orig_ip="${orig_cidr%/*}"

  if [ -z "$iface" ]; then
    fail "无法检测默认网卡，请确认网络配置"
    pause
    return 1
  fi

  header

  section "添加新出口IP"

  kv "网卡"       "$iface"
  kv "当前主IP"   "${orig_cidr:-未知}"
  kv "当前网关"   "${orig_gw:-未知}"
  echo

  # 输入新IP
  local new_cidr=""
  while [ -z "$new_cidr" ]; do
    printf "  %b请输入新IP/前缀 (如 1.2.3.4/25):%b " "$C_YELLOW" "$C_RESET"
    read -r new_cidr
  done

  # 解析
  local new_ip="${new_cidr%/*}"
  local new_prefix="${new_cidr#*/}"
  if [ -z "$new_ip" ] || [ -z "$new_prefix" ] || [ "$new_ip" = "$new_cidr" ]; then
    fail "格式错误，请使用 IP/前缀 格式，如 1.2.3.4/25"
    pause
    return 1
  fi

  # 输入新网关
  local new_gw=""
  while [ -z "$new_gw" ]; do
    printf "  %b请输入新网关 (如 1.2.3.1):%b   " "$C_YELLOW" "$C_RESET"
    read -r new_gw
  done

  echo
  subline
  echo
  printf "  %b确认配置:%b\n" "$C_WHITE$C_BOLD" "$C_RESET"
  kv "新IP"   "$new_cidr"
  kv "新网关" "$new_gw"
  echo
  printf "  %b确认执行? [y/N]:%b " "$C_YELLOW" "$C_RESET"
  read -r confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    info "已取消"
    pause
    return 0
  fi

  echo
  create_backup "before_add_${new_ip}"

  # 1. 检查新IP是否已在网卡上
  if ip addr show "$iface" 2>/dev/null | grep -q "$new_ip/"; then
    warn "IP $new_ip 已存在于 $iface，跳过添加"
  else
    info "添加 IP $new_cidr 到 $iface..."
    if ip addr add "$new_cidr" dev "$iface" 2>/dev/null; then
      ok "IP 已添加"
    else
      fail "IP 添加失败"
      pause; return 1
    fi
  fi

  # 2. 测试网关
  if ping -c 1 -W 2 "$new_gw" >/dev/null 2>&1; then
    ok "网关 $new_gw 可达"
  else
    warn "网关 $new_gw 不可达，将继续配置但可能不生效"
  fi

  # 3. 策略路由
  info "配置策略路由..."
  ip route add default via "$new_gw" dev "$iface" table $TABLE_NEW 2>/dev/null || true
  ip rule add from "$new_ip" table $TABLE_NEW priority 100 2>/dev/null || true

  # 4. 保留原IP路由
  if [ -n "$orig_gw" ] && [ -n "$orig_ip" ]; then
    ip route add default via "$orig_gw" dev "$iface" table $TABLE_ORIG 2>/dev/null || true
    ip rule add from "$orig_ip" table $TABLE_ORIG priority 200 2>/dev/null || true
  fi

  # 5. 改主路由表
  info "切换全局出口..."
  ip route replace default via "$new_gw" dev "$iface" src "$new_ip"

  # 6. 持久化
  echo "${iface}|${new_cidr}|${new_gw}" >> "$MANAGED_IPS_FILE"
  sort -u "$MANAGED_IPS_FILE" -o "$MANAGED_IPS_FILE"
  persist_config

  # 7. 验证
  sleep 1
  local exit_ip=$(get_exit_ip)
  echo

  if [ "$exit_ip" = "$new_ip" ]; then
    ok "出口IP已切换为: ${C_BOLD}${exit_ip}${C_RESET}"
  else
    warn "出口IP: $exit_ip (预期 $new_ip，可能需要几秒生效)"
  fi

  echo
  line
  pause
}

do_remove() {
  local iface=$(get_default_iface)

  header
  section "移除出口IP"

  if [ ! -f "$MANAGED_IPS_FILE" ] || [ ! -s "$MANAGED_IPS_FILE" ]; then
    info "没有托管的IP，无需移除"
    pause
    return 0
  fi

  echo "  当前托管IP:"
  local idx=1
  local ips=()
  while IFS='|' read -r m_iface m_ip m_gw; do
    [ -z "$m_ip" ] && continue
    ips+=("$m_iface|$m_ip|$m_gw")
    printf "  %b[%d]%b %s → %s\n" "$C_BLUE$C_BOLD" "$idx" "$C_RESET" "$m_ip" "$m_gw"
    idx=$((idx + 1))
  done < "$MANAGED_IPS_FILE"

  if [ ${#ips[@]} -eq 0 ]; then
    info "没有托管的IP"
    pause; return 0
  fi

  echo
  printf "  输入序号移除，或输入 %bA%b 移除全部，%bC%b 取消: " "$C_YELLOW" "$C_RESET" "$C_YELLOW" "$C_RESET"
  read -r choice

  case "$choice" in
    [Cc]) info "已取消"; pause; return 0 ;;
    [Aa])
      create_backup "before_remove_all"
      info "移除所有托管IP..."
      for entry in "${ips[@]}"; do
        local t_ip_cidr=$(echo "$entry" | cut -d'|' -f2)
        local t_ip="${t_ip_cidr%/*}"
        ip addr del "$t_ip_cidr" dev "$iface" 2>/dev/null || true
        ip route del default table $TABLE_NEW 2>/dev/null || true
        ip rule del from "$t_ip" table $TABLE_NEW priority 100 2>/dev/null || true
      done
      rm -f "$MANAGED_IPS_FILE"
      ;;
    *)
      if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#ips[@]} ]; then
        fail "无效选择"
        pause; return 1
      fi
      local target="${ips[$((choice-1))]}"
      local t_ip_cidr=$(echo "$target" | cut -d'|' -f2)
      local t_ip="${t_ip_cidr%/*}"

      create_backup "before_remove_${t_ip}"
      info "移除 $t_ip_cidr ..."
      ip addr del "$t_ip_cidr" dev "$iface" 2>/dev/null || true
      ip route del default table $TABLE_NEW 2>/dev/null || true
      ip rule del from "$t_ip" table $TABLE_NEW priority 100 2>/dev/null || true
      grep -v "|${t_ip_cidr}|" "$MANAGED_IPS_FILE" > "${MANAGED_IPS_FILE}.tmp"
      mv "${MANAGED_IPS_FILE}.tmp" "$MANAGED_IPS_FILE"
      ;;
  esac

  # 清理已空的策略
  if [ ! -f "$MANAGED_IPS_FILE" ] || [ ! -s "$MANAGED_IPS_FILE" ]; then
    info "无托管IP，恢复原始路由..."
    ip rule del priority 100 2>/dev/null || true
    ip rule del priority 200 2>/dev/null || true
    ip route flush table $TABLE_NEW 2>/dev/null || true
    ip route flush table $TABLE_ORIG 2>/dev/null || true

    local orig_gw=$(get_default_gateway)
    local orig_ip=$(get_ips_on_iface "$iface" | head -1 | cut -d/ -f1)
    if [ -n "$orig_gw" ] && [ -n "$orig_ip" ]; then
      ip route replace default via "$orig_gw" dev "$iface" src "$orig_ip"
    fi
    rm -f "$IFUP_SCRIPT"
    rm -f "$NM_DISPATCHER_SCRIPT"
    rm -f "$NETWORKD_DISPATCHER_SCRIPT"
    sed -i "/${APP_NAME}/d" /etc/network/interfaces 2>/dev/null || true
    ok "已恢复原始配置"
  else
    # 更新主路由到下一个托管IP
    local next_line=$(head -1 "$MANAGED_IPS_FILE")
    local next_ip=$(echo "$next_line" | cut -d'|' -f2 | cut -d/ -f1)
    local next_gw=$(echo "$next_line" | cut -d'|' -f3)
    ip route replace default via "$next_gw" dev "$iface" src "$next_ip"
    ok "主出口已切换到: $next_ip"
  fi

  sleep 1
  local exit_ip=$(get_exit_ip)
  info "当前出口IP: ${C_BOLD}${exit_ip}${C_RESET}"

  echo
  line
  pause
}

do_restore() {
  header
  section "回退到初始状态"

  printf "  %b此操作将清除所有托管IP和策略路由%b\n" "$C_YELLOW" "$C_RESET"
  printf "  %b恢复为系统原始出口IP%b\n" "$C_YELLOW" "$C_RESET"
  echo
  printf "  %b确认回退? [y/N]:%b " "$C_YELLOW" "$C_RESET"
  read -r confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    info "已取消"
    pause
    return 0
  fi

  local iface=$(get_default_iface)
  local orig_gw=$(get_default_gateway)
  local orig_ip=$(get_ips_on_iface "$iface" | head -1 | cut -d/ -f1)

  create_backup "before_restore"

  # 移除托管IP
  if [ -f "$MANAGED_IPS_FILE" ] && [ -s "$MANAGED_IPS_FILE" ]; then
    info "移除托管IP..."
    while IFS='|' read -r m_iface m_ip m_gw; do
      [ -z "$m_ip" ] && continue
      ip addr del "$m_ip" dev "$m_iface" 2>/dev/null || true
    done < "$MANAGED_IPS_FILE"
  fi

  # 清理策略路由
  info "清理策略路由..."
  ip rule del priority 100 2>/dev/null || true
  ip rule del priority 200 2>/dev/null || true
  ip route flush table $TABLE_NEW 2>/dev/null || true
  ip route flush table $TABLE_ORIG 2>/dev/null || true

  # 恢复原始路由
  if [ -n "$orig_gw" ] && [ -n "$orig_ip" ]; then
    ip route replace default via "$orig_gw" dev "$iface" src "$orig_ip"
    ok "默认网关已恢复: $orig_gw"
  fi

  # 清理持久化
  rm -f "$MANAGED_IPS_FILE"
  rm -f "$IFUP_SCRIPT"
  rm -f "$NM_DISPATCHER_SCRIPT"
  rm -f "$NETWORKD_DISPATCHER_SCRIPT"
  sed -i "/${APP_NAME}/d" /etc/network/interfaces 2>/dev/null || true

  sleep 1
  local exit_ip=$(get_exit_ip)
  ok "出口IP: ${C_BOLD}${exit_ip}${C_RESET}"
  ok "已回退到初始状态"

  echo
  line
  pause
}

do_backup() {
  header
  section "创建备份"
  create_backup "manual"
  echo
  line
  pause
}

do_backups() {
  header
  section "备份列表"
  if [ -d "$BACKUP_DIR" ] && ls "$BACKUP_DIR"/*.tar.gz &>/dev/null; then
    ls -1t "$BACKUP_DIR"/*.tar.gz | while read f; do
      local sz=$(du -h "$f" | cut -f1)
      printf "  %b%s%b (%s)\n" "$C_CYAN" "$(basename "$f")" "$C_RESET" "$sz"
    done
  else
    echo "  (无备份)"
  fi
  echo
  line
  pause
}

# ── 主菜单 ──────────────────────────────────────────────────────────────────

main_menu() {
  while true; do
    header
    section "菜单"

    local exit_ip=$(get_exit_ip)
    local managed_count=0
    [ -f "$MANAGED_IPS_FILE" ] && managed_count=$(grep -c '|' "$MANAGED_IPS_FILE" 2>/dev/null || echo 0)

    kv "出口IP"   "${C_BOLD}${exit_ip}${C_RESET}"
    kv "托管IP数" "$managed_count"
    echo

    menu_item "1" "添加新出口IP"
    menu_item "2" "移除出口IP"
    menu_item "3" "回退到初始状态"
    menu_item "4" "查看当前状态"
    echo
    menu_item "5" "创建备份"
    menu_item "6" "查看备份"
    echo
    menu_item "7" "退出"
    echo

    subline
    printf "  %b请选择 [1-7]:%b " "$C_GREEN" "$C_RESET"
    read -r choice

    case "$choice" in
      1) do_add ;;
      2) do_remove ;;
      3) do_restore ;;
      4) do_status ;;
      5) do_backup ;;
      6) do_backups ;;
      7) header; echo; ok "再见"; echo; exit 0 ;;
      *) warn "无效选项，请输入 1-7"; sleep 1 ;;
    esac
  done
}

main_menu
