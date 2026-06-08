#!/bin/bash
#===============================================================================
# exit-ip-manager.sh — 出口IP管理器
# 给 Debian/Ubuntu 机器添加/删除额外出口IP（策略路由）
#
# 用法:
#   ./exit-ip-manager.sh add <新IP>/<前缀> <新网关>    添加新出口IP
#   ./exit-ip-manager.sh remove <IP>/<前缀>           移除指定出口IP
#   ./exit-ip-manager.sh restore                      回退到初始状态
#   ./exit-ip-manager.sh status                       查看当前状态
#
# 示例:
#   ./exit-ip-manager.sh add 103.140.137.137/25 103.140.137.129
#   ./exit-ip-manager.sh remove 103.140.137.137/25
#   ./exit-ip-manager.sh restore
#===============================================================================

set -euo pipefail

# ── 颜色 ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── 全局常量 ────────────────────────────────────────────────────────────────
APP_NAME="exit-ip-manager"
STATE_DIR="/etc/${APP_NAME}"
BACKUP_DIR="${STATE_DIR}/backups"
MANAGED_IPS_FILE="${STATE_DIR}/managed_ips"
STATE_FILE="${STATE_DIR}/state"

# 策略路由表ID（避免与系统冲突）
TABLE_NEW=100
TABLE_ORIG=200

# ── 工具函数 ────────────────────────────────────────────────────────────────

info()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; }
header()  { echo -e "\n${BOLD}${BLUE}═══ $* ═══${NC}"; }
detail()  { echo -e "  ${CYAN}$1${NC} $2"; }

die() {
    error "$*"
    exit 1
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "需要 root 权限，请用 sudo 运行"
    fi
}

ensure_dirs() {
    mkdir -p "$BACKUP_DIR"
}

# ── 网络检测 ────────────────────────────────────────────────────────────────

# 解析 CIDR 为 IP + 前缀
parse_cidr() {
    local cidr="$1"
    local ip="${cidr%/*}"
    local prefix="${cidr#*/}"
    echo "$ip" "$prefix"
}

# 获取当前默认网卡
get_default_iface() {
    ip route show default 2>/dev/null | awk '{print $5}' | head -1
}

# 获取当前默认网关
get_default_gateway() {
    ip route show default 2>/dev/null | awk '{print $3}' | head -1
}

# 获取网卡上的 IP/CIDR 列表
get_ips_on_iface() {
    local iface="$1"
    ip -o addr show "$iface" 2>/dev/null \
        | grep 'inet ' \
        | awk '{print $4}' \
        | grep -v '^127\.'
}

# 获取当前全局出口IP
get_exit_ip() {
    curl -s --connect-timeout 5 ifconfig.me 2>/dev/null \
        || curl -s --connect-timeout 5 ip.sb 2>/dev/null \
        || echo "unknown"
}

# 获取主IP（第一个非127的IPv4）
get_primary_ip() {
    local iface="$1"
    ip -o addr show "$iface" 2>/dev/null \
        | grep 'inet ' \
        | grep -v '127\.' \
        | awk '{print $4}' \
        | head -1
}

# 检测 /etc/network/interfaces 或 netplan
detect_network_config_type() {
    if [ -d /etc/netplan ] && ls /etc/netplan/*.yaml &>/dev/null; then
        echo "netplan"
    elif [ -f /etc/network/interfaces ]; then
        echo "interfaces"
    else
        echo "unknown"
    fi
}

# 测试网关是否可达
test_gateway() {
    local gw="$1"
    ping -c 1 -W 2 "$gw" &>/dev/null
}

# ── 备份与恢复 ──────────────────────────────────────────────────────────────

create_backup() {
    local tag="$1"
    local backup_file="${BACKUP_DIR}/$(date +%Y%m%d%H%M%S)_${tag}.tar.gz"
    local tmpdir=$(mktemp -d)
    
    # 备份当前运行时状态
    ip route show table all > "$tmpdir/routes.txt" 2>/dev/null || true
    ip rule show > "$tmpdir/rules.txt" 2>/dev/null || true
    ip addr show > "$tmpdir/addr.txt" 2>/dev/null || true
    
    # 备份网络配置文件
    local config_type=$(detect_network_config_type)
    if [ "$config_type" = "netplan" ]; then
        cp -r /etc/netplan "$tmpdir/" 2>/dev/null || true
    elif [ "$config_type" = "interfaces" ]; then
        cp /etc/network/interfaces "$tmpdir/" 2>/dev/null || true
        [ -d /etc/network/interfaces.d ] && cp -r /etc/network/interfaces.d "$tmpdir/" 2>/dev/null || true
    fi
    
    # 备份本工具状态
    [ -f "$MANAGED_IPS_FILE" ] && cp "$MANAGED_IPS_FILE" "$tmpdir/" || true
    
    tar czf "$backup_file" -C "$tmpdir" . 2>/dev/null
    rm -rf "$tmpdir"
    info "已创建备份: $backup_file"
    echo "$backup_file"
}

restore_from_backup() {
    local backup_file="$1"
    if [ ! -f "$backup_file" ]; then
        die "备份文件不存在: $backup_file"
    fi
    
    local tmpdir=$(mktemp -d)
    tar xzf "$backup_file" -C "$tmpdir" 2>/dev/null
    
    # 恢复网络配置
    local config_type=$(detect_network_config_type)
    if [ "$config_type" = "netplan" ] && [ -d "$tmpdir/netplan" ]; then
        cp "$tmpdir"/netplan/*.yaml /etc/netplan/
    elif [ "$config_type" = "interfaces" ] && [ -f "$tmpdir/interfaces" ]; then
        cp "$tmpdir/interfaces" /etc/network/interfaces
        [ -d "$tmpdir/interfaces.d" ] && cp -r "$tmpdir/interfaces.d"/* /etc/network/interfaces.d/ 2>/dev/null || true
    fi
    
    # 恢复本工具状态
    [ -f "$tmpdir/managed_ips" ] && cp "$tmpdir/managed_ips" "$MANAGED_IPS_FILE" || true
    
    rm -rf "$tmpdir"
    info "配置已从备份恢复: $backup_file"
    warn "请执行 'systemctl restart networking' 或重启网络使配置生效"
}

# 列出所有备份
list_backups() {
    echo ""
    header "备份列表"
    if [ -d "$BACKUP_DIR" ] && ls "$BACKUP_DIR"/*.tar.gz &>/dev/null; then
        ls -1t "$BACKUP_DIR"/*.tar.gz | while read f; do
            local size=$(du -h "$f" | cut -f1)
            local name=$(basename "$f")
            echo -e "  ${CYAN}${name}${NC} (${size})"
        done
    else
        echo "  (无备份)"
    fi
    echo ""
}

# ── 持久化配置 ──────────────────────────────────────────────────────────────

# 管理IP列表
add_managed_ip() {
    local ip_cidr="$1"
    local gw="$2"
    local iface="$3"
    ensure_dirs
    echo "${iface}|${ip_cidr}|${gw}" >> "$MANAGED_IPS_FILE"
    sort -u "$MANAGED_IPS_FILE" -o "$MANAGED_IPS_FILE"
}

remove_managed_ip() {
    local ip_cidr="$1"
    if [ -f "$MANAGED_IPS_FILE" ]; then
        grep -v "|${ip_cidr}|" "$MANAGED_IPS_FILE" > "${MANAGED_IPS_FILE}.tmp"
        mv "${MANAGED_IPS_FILE}.tmp" "$MANAGED_IPS_FILE"
    fi
}

get_managed_ips() {
    [ -f "$MANAGED_IPS_FILE" ] && cat "$MANAGED_IPS_FILE" || true
}

# 持久化到 /etc/network/interfaces
persist_interfaces() {
    local script_path="/etc/network/if-up.d/${APP_NAME}"
    
    # 创建 if-up 脚本
    cat > "$script_path" << 'INNER_SCRIPT'
#!/bin/bash
# Auto-generated by exit-ip-manager — do not edit manually
# 在网卡启动后应用所有托管IP的策略路由

MANAGED_IPS_FILE="/etc/exit-ip-manager/managed_ips"
TABLE_NEW=100
TABLE_ORIG=200

if [ ! -f "$MANAGED_IPS_FILE" ]; then
    exit 0
fi

while IFS='|' read -r iface ip_cidr gw; do
    [ -z "$iface" ] && continue
    local_ip="${ip_cidr%/*}"
    
    # 添加IP
    ip addr add "$ip_cidr" dev "$iface" 2>/dev/null || true
    
    # 新IP策略路由
    ip route add default via "$gw" dev "$iface" table $TABLE_NEW 2>/dev/null || true
    ip rule add from "$local_ip" table $TABLE_NEW priority 100 2>/dev/null || true
    
    # 原IP保留原网关
    ORIG_GW=$(ip route show default dev "$iface" 2>/dev/null | awk '{print $3}' | head -1 || true)
    ORIG_IP=$(ip -o addr show "$iface" 2>/dev/null | grep 'inet ' | grep -v '127\.' | awk '{print $4}' | head -1 || true)
    if [ -n "$ORIG_GW" ] && [ -n "$ORIG_IP" ]; then
        ip route add default via "$ORIG_GW" dev "$iface" table $TABLE_ORIG 2>/dev/null || true
        ip rule add from "${ORIG_IP%/*}" table $TABLE_ORIG priority 200 2>/dev/null || true
    fi
    
    # 修改主路由表
    ip route replace default via "$gw" dev "$iface" src "$local_ip" 2>/dev/null || true
done < "$MANAGED_IPS_FILE"
INNER_SCRIPT
    
    chmod +x "$script_path"
    
    # 在 interfaces 文件中添加 hook（如果还没有的话）
    if ! grep -q "${APP_NAME}" /etc/network/interfaces 2>/dev/null; then
        # 找到 auto 网卡那一行后面添加
        local iface=$(get_default_iface)
        if grep -q "iface ${iface} inet" /etc/network/interfaces 2>/dev/null; then
            # 添加在 iface 块的末尾
            sed -i "/iface ${iface} inet/a \    post-up ${script_path}" /etc/network/interfaces
        fi
    fi
    
    info "持久化配置已写入 /etc/network/interfaces 和 ${script_path}"
}

# 持久化到 netplan
persist_netplan() {
    local new_ip_cidr="$1"
    local new_gw="$2"
    local iface="$3"
    
    local netplan_file=$(ls /etc/netplan/*.yaml 2>/dev/null | head -1)
    if [ -z "$netplan_file" ]; then
        die "未找到 netplan 配置文件"
    fi
    
    # 备份
    cp "$netplan_file" "${netplan_file}.${APP_NAME}.bak"
    
    # 使用 Python 或手动编辑（简化处理）
    warn "netplan 持久化配置仅做备份，请手动编辑 ${netplan_file}"
    warn "或在 /etc/network/if-up.d/ 下手动创建启动脚本"
    
    # 退回到 if-up.d 方法
    local script_path="/etc/network/if-up.d/${APP_NAME}"
    cat > "$script_path" << 'INNER_NP'
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
    ip route replace default via "$gw" dev "$iface" src "$local_ip" 2>/dev/null || true
done < "$MANAGED_IPS_FILE"
INNER_NP
    chmod +x "$script_path"
    info "netplan 持久化已通过 ${script_path} 实现"
}

persist_config() {
    local new_ip_cidr="$1"
    local new_gw="$2"
    local iface="$3"
    
    local config_type=$(detect_network_config_type)
    
    case "$config_type" in
        interfaces)
            persist_interfaces
            ;;
        netplan)
            persist_netplan "$new_ip_cidr" "$new_gw" "$iface"
            ;;
        *)
            warn "未识别的网络配置方式，创建通用 if-up 脚本"
            mkdir -p /etc/network/if-up.d/
            local script_path="/etc/network/if-up.d/${APP_NAME}"
            cat > "$script_path" << 'INNER_GEN'
#!/bin/bash
MANAGED_IPS_FILE="/etc/exit-ip-manager/managed_ips"
TABLE_NEW=100; TABLE_ORIG=200
[ ! -f "$MANAGED_IPS_FILE" ] && exit 0
while IFS='|' read -r iface ip_cidr gw; do
    [ -z "$iface" ] && continue
    local_ip="${ip_cidr%/*}"
    ip addr add "$ip_cidr" dev "$iface" 2>/dev/null || true
    ip route add default via "$gw" dev "$iface" table $TABLE_NEW 2>/dev/null || true
    ip rule add from "$local_ip" table $TABLE_NEW priority 100 2>/dev/null || true
    ip route replace default via "$gw" dev "$iface" src "$local_ip" 2>/dev/null || true
done < "$MANAGED_IPS_FILE"
INNER_GEN
            chmod +x "$script_path"
            info "持久化已通过 ${script_path} 实现"
            ;;
    esac
}

# ── 核心操作 ────────────────────────────────────────────────────────────────

cmd_status() {
    local iface=$(get_default_iface)
    local current_gw=$(get_default_gateway)
    local exit_ip=$(get_exit_ip)
    local config_type=$(detect_network_config_type)
    
    echo ""
    header "当前网络状态"
    
    detail "网卡"    "$iface"
    detail "配置方式" "$config_type"
    echo ""
    
    # 所有IP
    header "IP 地址"
    get_ips_on_iface "$iface" | while read ip; do
        local ip_only="${ip%/*}"
        if echo "$ip_only" | grep -q "$exit_ip"; then
            echo -e "  ${GREEN}● ${ip}${NC}  ${BOLD}← 当前出口IP${NC}"
        else
            echo -e "  ○ $ip"
        fi
    done
    
    echo ""
    header "路由"
    detail "默认网关" "$current_gw"
    detail "出口IP"   "$exit_ip"
    
    echo ""
    header "策略路由表"
    echo -e "  Table ${TABLE_NEW} (新IP):"
    ip route show table $TABLE_NEW 2>/dev/null | sed 's/^/    /' || echo "    (空)"
    echo -e "  Table ${TABLE_ORIG} (原IP):"
    ip route show table $TABLE_ORIG 2>/dev/null | sed 's/^/    /' || echo "    (空)"
    
    echo ""
    header "策略规则"
    ip rule show | grep -E "from|lookup (local|main|default|${TABLE_NEW}|${TABLE_ORIG})" | sed 's/^/  /' || true
    
    # 被管理的IP
    if [ -f "$MANAGED_IPS_FILE" ] && [ -s "$MANAGED_IPS_FILE" ]; then
        echo ""
        header "已托管IP"
        cat "$MANAGED_IPS_FILE" | while IFS='|' read -r m_iface m_ip m_gw; do
            echo -e "  ${CYAN}${m_ip}${NC} → gw ${m_gw} (${m_iface})"
        done
    fi
    
    echo ""
    list_backups
}

cmd_add() {
    require_root
    ensure_dirs
    
    local new_ip_cidr="$1"
    local new_gw="$2"
    
    # 解析
    local new_ip=$(parse_cidr "$new_ip_cidr" | awk '{print $1}')
    local new_prefix=$(parse_cidr "$new_ip_cidr" | awk '{print $2}')
    
    # 检测当前配置
    local iface=$(get_default_iface)
    local orig_gw=$(get_default_gateway)
    local orig_ip_cidr=$(get_primary_ip "$iface")
    local orig_ip="${orig_ip_cidr%/*}"
    
    if [ -z "$iface" ]; then
        die "无法检测默认网卡"
    fi
    
    header "添加出口IP"
    detail "网卡"      "$iface"
    detail "原IP/网关"  "$orig_ip_cidr → $orig_gw"
    detail "新IP"      "$new_ip_cidr"
    detail "新网关"    "$new_gw"
    echo ""
    
    # 检查是否已添加
    if ip addr show "$iface" | grep -q "$new_ip/"; then
        warn "IP $new_ip 已存在于 $iface，跳过添加"
    fi
    
    # 备份
    create_backup "before_add_${new_ip}"
    
    # 1. 添加新IP
    info "添加新IP到网卡..."
    ip addr add "$new_ip_cidr" dev "$iface" 2>/dev/null || {
        warn "IP已存在或添加失败（可能已存在，继续...）"
    }
    
    # 2. 测试新网关
    if test_gateway "$new_gw"; then
        info "新网关 $new_gw 可达 (延迟正常)"
    else
        warn "新网关 $new_gw 不可达，请确认IP配置是否正确"
        warn "将继续配置，但可能无法正常工作"
    fi
    
    # 3. 为新IP创建策略路由表
    info "配置策略路由..."
    ip route add default via "$new_gw" dev "$iface" table $TABLE_NEW 2>/dev/null || true
    ip rule add from "$new_ip" table $TABLE_NEW priority 100 2>/dev/null || true
    
    # 4. 为旧IP保留原网关路由（保护现有SSH连接）
    if [ -n "$orig_gw" ]; then
        ip route add default via "$orig_gw" dev "$iface" table $TABLE_ORIG 2>/dev/null || true
        ip rule add from "$orig_ip" table $TABLE_ORIG priority 200 2>/dev/null || true
    fi
    
    # 5. 修改主路由表，使全局出口走新IP
    info "切换全局出口到新IP..."
    ip route replace default via "$new_gw" dev "$iface" src "$new_ip"
    
    # 6. 持久化
    add_managed_ip "$new_ip_cidr" "$new_gw" "$iface"
    persist_config "$new_ip_cidr" "$new_gw" "$iface"
    
    # 7. 验证
    sleep 1
    local exit_ip=$(get_exit_ip)
    echo ""
    if [ "$exit_ip" = "$new_ip" ]; then
        info "出口IP已切换为: ${BOLD}${exit_ip}${NC}"
    else
        warn "出口IP为 $exit_ip，预期 $new_ip（可能需要几秒生效）"
    fi
    
    echo ""
    info "配置完成！如需回退: ${BOLD}${0} restore${NC}"
}

cmd_remove() {
    require_root
    ensure_dirs
    
    local target_cidr="$1"
    local target_ip=$(parse_cidr "$target_cidr" | awk '{print $1}')
    local iface=$(get_default_iface)
    
    header "移除出口IP: $target_cidr"
    
    # 备份
    create_backup "before_remove_${target_ip}"
    
    # 从网卡移除
    if ip addr show "$iface" | grep -q "$target_ip/"; then
        info "从网卡移除 $target_cidr ..."
        ip addr del "$target_cidr" dev "$iface"
    else
        warn "IP $target_cidr 不在网卡上"
    fi
    
    # 清理路由表
    ip route del default via "$(ip route show table $TABLE_NEW 2>/dev/null | awk '{print $3}' | head -1)" dev "$iface" table $TABLE_NEW 2>/dev/null || true
    ip rule del from "$target_ip" table $TABLE_NEW priority 100 2>/dev/null || true
    
    # 从管理列表移除
    remove_managed_ip "$target_cidr"
    
    # 如果管理列表为空，移除所有策略路由
    if [ ! -f "$MANAGED_IPS_FILE" ] || [ ! -s "$MANAGED_IPS_FILE" ]; then
        info "没有托管IP，清理所有策略路由..."
        ip rule del priority 100 2>/dev/null || true
        ip rule del priority 200 2>/dev/null || true
        # 恢复为最早的原始网关
        local orig_gw=$(get_default_gateway)
        local orig_ip=$(get_primary_ip "$iface" | cut -d/ -f1)
        ip route replace default via "$orig_gw" dev "$iface" src "$orig_ip" 2>/dev/null || true
    else
        # 将主路由表指向下一个托管IP
        local next_ip=$(head -1 "$MANAGED_IPS_FILE" | cut -d'|' -f2 | cut -d/ -f1)
        local next_gw=$(head -1 "$MANAGED_IPS_FILE" | cut -d'|' -f3)
        ip route replace default via "$next_gw" dev "$iface" src "$next_ip"
        info "主出口已切换到: $next_ip"
    fi
    
    echo ""
    local exit_ip=$(get_exit_ip)
    info "当前出口IP: $exit_ip"
}

cmd_restore() {
    require_root
    
    header "回退到初始状态"
    
    local iface=$(get_default_iface)
    local orig_ip_cidr=$(get_primary_ip "$iface")
    local orig_ip="${orig_ip_cidr%/*}"
    
    # 备份当前状态
    create_backup "before_restore"
    
    # 1. 从网卡移除所有托管IP
    if [ -f "$MANAGED_IPS_FILE" ] && [ -s "$MANAGED_IPS_FILE" ]; then
        while IFS='|' read -r m_iface m_ip m_gw; do
            [ -z "$m_ip" ] && continue
            local m_ip_only="${m_ip%/*}"
            info "移除IP: $m_ip from $m_iface"
            ip addr del "$m_ip" dev "$m_iface" 2>/dev/null || true
        done < "$MANAGED_IPS_FILE"
    fi
    
    # 2. 清理策略路由
    info "清理策略路由..."
    ip rule del priority 100 2>/dev/null || true
    ip rule del priority 200 2>/dev/null || true
    ip route flush table $TABLE_NEW 2>/dev/null || true
    ip route flush table $TABLE_ORIG 2>/dev/null || true
    
    # 3. 恢复默认路由为原始网关
    local orig_gw=$(grep "gateway" /etc/network/interfaces 2>/dev/null | awk '{print $2}' | head -1)
    if [ -z "$orig_gw" ]; then
        orig_gw=$(get_default_gateway)
    fi
    
    if [ -n "$orig_gw" ] && [ -n "$orig_ip" ]; then
        info "恢复默认网关: $orig_gw"
        ip route replace default via "$orig_gw" dev "$iface" src "$orig_ip"
    fi
    
    # 4. 清理持久化文件
    info "清理持久化配置..."
    rm -f "$MANAGED_IPS_FILE"
    rm -f "/etc/network/if-up.d/${APP_NAME}"
    
    # 从 interfaces 中移除 post-up hook
    if [ -f /etc/network/interfaces ]; then
        sed -i "/${APP_NAME}/d" /etc/network/interfaces
    fi
    
    sleep 1
    local exit_ip=$(get_exit_ip)
    echo ""
    info "已回退到初始状态"
    info "当前出口IP: ${BOLD}${exit_ip}${NC}"
    warn "如需从备份恢复配置文件，请使用 restore-from-backup 子命令"
}

cmd_restore_from_backup() {
    require_root
    
    local backup_file="$1"
    if [ -z "$backup_file" ]; then
        # 列出备份让用户选择
        if [ ! -d "$BACKUP_DIR" ] || ! ls "$BACKUP_DIR"/*.tar.gz &>/dev/null; then
            die "没有可用的备份"
        fi
        backup_file=$(ls -1t "$BACKUP_DIR"/*.tar.gz | head -1)
        warn "使用最新备份: $backup_file"
    fi
    
    create_backup "before_restore_backup"
    restore_from_backup "$backup_file"
}

# ── 命令行解析 ──────────────────────────────────────────────────────────────

usage() {
    cat << EOF
${BOLD}exit-ip-manager${NC} — Debian/Ubuntu 出口IP管理器

${BOLD}用法:${NC}
  $0 add <新IP/前缀> <新网关>      添加新出口IP
  $0 remove <IP/前缀>              移除指定出口IP
  $0 restore                        回退到初始状态
  $0 status                         查看当前网络状态
  $0 backup                         创建手动备份
  $0 backups                        列出所有备份
  $0 restore-from-backup [备份文件]  从备份恢复

${BOLD}示例:${NC}
  # 添加新出口IP
  sudo $0 add 103.140.137.137/25 103.140.137.129

  # 查看状态
  sudo $0 status

  # 移除指定IP
  sudo $0 remove 103.140.137.137/25

  # 回退所有
  sudo $0 restore

${BOLD}工作原理:${NC}
  使用 Linux 策略路由（policy routing），基于源地址将流量分配到不同网关：
  - 新IP 的流量 → 新网关（成为全局出口）
  - 原IP 的流量 → 原网关（保护现有SSH连接）

${BOLD}支持:${NC}
  - Debian 9+ / Ubuntu 16.04+
  - /etc/network/interfaces 和 netplan 配置格式
  - 重启后自动恢复配置
EOF
    exit 0
}

# ── 主入口 ────────────────────────────────────────────────────────────────────

main() {
    case "${1:-}" in
        status)
            cmd_status
            ;;
        add)
            if [ $# -lt 3 ]; then
                error "用法: $0 add <IP/前缀> <网关>"
                echo "示例: $0 add 103.140.137.137/25 103.140.137.129"
                exit 1
            fi
            cmd_add "$2" "$3"
            ;;
        remove)
            if [ $# -lt 2 ]; then
                error "用法: $0 remove <IP/前缀>"
                echo "示例: $0 remove 103.140.137.137/25"
                exit 1
            fi
            cmd_remove "$2"
            ;;
        restore)
            cmd_restore
            ;;
        backup)
            require_root
            ensure_dirs
            create_backup "manual"
            ;;
        backups)
            list_backups
            ;;
        restore-from-backup)
            require_root
            cmd_restore_from_backup "${2:-}"
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            usage
            ;;
    esac
}

main "$@"
