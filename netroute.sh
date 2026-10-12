#!/bin/bash
# netroute.sh
# Author: nmrt0316
# GitHub: https://github.com/nmrt0316/netroute

CONF="/etc/public-return-route.conf"
SCRIPT_PATH=$(readlink -f "$0")
SERVICE_FILE="/etc/systemd/system/public-return-route.service"

if [ "$EUID" -ne 0 ]; then
    echo "请使用 sudo 或 root 权限运行。"
    exit 1
fi

command -v iptables >/dev/null 2>&1 || { echo "❌ 请先安装 iptables：apt install iptables"; exit 1; }

validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    for octet in $ip; do
        [ "$((10#$octet))" -ge 0 ] && [ "$((10#$octet))" -le 255 ] || return 1
    done
    return 0
}

validate_ports() {
    local ports="$1"
    [ -z "$ports" ] && return 1
    ports=$(echo "$ports" | tr ',' ' ' | tr -s ' ')
    for p in $ports; do
        [[ "$p" =~ ^[0-9]+$ ]] || return 1
        [ "$((10#$p))" -ge 1 ] && [ "$((10#$p))" -le 65535 ] || return 1
    done
    return 0
}

normalize_ports() {
    echo "$1" | tr ',' ' ' | tr -s ' ' | tr ' ' '\n' | grep -v '^$' | sort -n -u | paste -sd ','
}

auto_detect() {
    IFACE=$(ip route show default 2>/dev/null | awk '{print $5}' | head -n1)
    [ -z "$IFACE" ] && echo "❌ 未检测到默认网卡" && return 1

    DEBIAN_IP=$(ip -4 addr show dev "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1)
    [ -z "$DEBIAN_IP" ] && echo "❌ 未检测到 $IFACE 的 IPv4 地址" && return 1

    DEFAULT_GW=$(ip route show default 2>/dev/null | awk '{print $3}' | head -n1)
    [ -z "$DEFAULT_GW" ] && echo "❌ 未检测到默认网关" && return 1

    RETURN_GW=$(ip route show table 100 2>/dev/null | grep '^default' | awk '{print $3}' | head -n1)
    [ -n "$RETURN_GW" ] && RETURN_GW_CONFIGURED=true || RETURN_GW_CONFIGURED=false

    # 兼容 --set-mark 100 和 --set-xmark 0x64/0xffffffff 两种写法
    PORTS=$(iptables -t mangle -S PREROUTING 2>/dev/null \
        | grep -E "CONNMARK --set-(mark 100|xmark 0x64)" \
        | awk '{for(i=1;i<=NF;i++) if($i=="--dport") print $(i+1)}' \
        | sort -n -u | paste -sd ',')
    [ -n "$PORTS" ] && PORTS_CONFIGURED=true || PORTS_CONFIGURED=false
    return 0
}

apply_rules() {
    [ ! -f "$CONF" ] && return 1
    source "$CONF"
    TABLE="${TABLE:-100}"
    MARK="${MARK:-100}"
    PORT_LIST=$(echo "$PORTS" | tr ',' ' ' | tr -s ' ')

    while ip rule del fwmark "$MARK" table "$TABLE" 2>/dev/null; do :; done
    ip route flush table "$TABLE" 2>/dev/null || true
    while iptables -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null; do :; done
    for PORT in $PORT_LIST; do
        while iptables -t mangle -D PREROUTING -i "$IFACE" -d "$DEBIAN_IP" -p tcp --dport "$PORT" -j CONNMARK --set-mark "$MARK" 2>/dev/null; do :; done
    done

    ip route replace table "$TABLE" default via "$RETURN_GW" dev "$IFACE"
    LAN_NET=$(echo "$DEBIAN_IP" | cut -d. -f1-3).0/24
    ip route replace table "$TABLE" "$LAN_NET" dev "$IFACE" scope link

    ip rule add fwmark "$MARK" table "$TABLE" priority 90
    iptables -t mangle -I OUTPUT 1 -j CONNMARK --restore-mark
    for PORT in $PORT_LIST; do
        iptables -t mangle -A PREROUTING -i "$IFACE" -d "$DEBIAN_IP" -p tcp --dport "$PORT" -j CONNMARK --set-mark "$MARK"
    done
    ip route flush cache 2>/dev/null || true
}

clean_rules() {
    echo "正在清理所有回程路由规则..."
    [ -f "$CONF" ] && source "$CONF" 2>/dev/null
    MARK="${MARK:-100}"
    TABLE="${TABLE:-100}"
    PORT_LIST=$(echo "$PORTS" | tr ',' ' ' | tr -s ' ')

    while ip rule del fwmark "$MARK" table "$TABLE" 2>/dev/null; do :; done
    ip route flush table "$TABLE" 2>/dev/null || true
    while iptables -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null; do :; done

    if [ -n "$PORT_LIST" ] && [ -n "$IFACE" ] && [ -n "$DEBIAN_IP" ]; then
        for PORT in $PORT_LIST; do
            while iptables -t mangle -D PREROUTING -i "$IFACE" -d "$DEBIAN_IP" -p tcp --dport "$PORT" -j CONNMARK --set-mark "$MARK" 2>/dev/null; do :; done
        done
    fi

    iptables -t mangle -S PREROUTING 2>/dev/null | grep "CONNMARK" | while IFS= read -r line; do
        rule="${line#-A }"
        set -- $rule
        iptables -t mangle -D "$@" 2>/dev/null
    done
    ip route flush cache 2>/dev/null || true
    echo "✅ 已清理干净，网络恢复默认。"
}

save_conf() {
    cat > "$CONF" << CONF_EOF
IFACE="$IFACE"
DEBIAN_IP="$DEBIAN_IP"
DEFAULT_GW="$DEFAULT_GW"
RETURN_GW="$RETURN_GW"
PORTS="$PORTS"
TABLE="100"
MARK="100"
CONF_EOF
}

auto_apply() {
    save_conf
    apply_rules

    cat > "$SERVICE_FILE" << SERVICE_EOF
[Unit]
Description=Public Return Route
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SCRIPT_PATH --apply
ExecStop=$SCRIPT_PATH --clean

[Install]
WantedBy=multi-user.target
SERVICE_EOF
    systemctl daemon-reload
    systemctl enable public-return-route.service >/dev/null 2>&1
}

if [ "$1" = "--apply" ]; then
    source "$CONF" 2>/dev/null
    TABLE="${TABLE:-100}"
    MARK="${MARK:-100}"
    [ -z "$IFACE" ] && exit 0
    apply_rules
    exit 0
fi
if [ "$1" = "--clean" ]; then
    source "$CONF" 2>/dev/null
    TABLE="${TABLE:-100}"
    MARK="${MARK:-100}"
    [ -z "$IFACE" ] && exit 0
    clean_rules
    exit 0
fi

if [ ! -f "$CONF" ]; then
    clear
    echo "=================================================="
    echo "        回程路由配置向导 - 首次运行"
    echo "=================================================="
    echo ""
    echo "正在检测网络环境..."
    if ! auto_detect; then
        echo ""
        echo "❌ 基础网络未配置好，脚本退出。"
        echo "请确保 ip route 能正常显示 default 路由。"
        exit 1
    fi
    echo "✅ 检测完成。"
    echo ""
    echo "  网卡      : $IFACE"
    echo "  本机 IP   : $DEBIAN_IP"
    echo "  默认网关  : $DEFAULT_GW"
    echo ""
    read -p "按回车键进入配置菜单..."
fi

while true; do
    clear
    source "$CONF" 2>/dev/null
    [ -z "$IFACE" ] && auto_detect
    TABLE="${TABLE:-100}"
    MARK="${MARK:-100}"

    if [ -n "$RETURN_GW" ]; then RETURN_GW_CONFIGURED=true; else RETURN_GW_CONFIGURED=false; fi
    if [ -n "$PORTS" ]; then PORTS_CONFIGURED=true; else PORTS_CONFIGURED=false; fi

    echo "=================================================="
    echo "        回程路由配置菜单"
    echo "=================================================="
    echo "系统信息："
    echo "  网卡      : $IFACE"
    echo "  本机 IP   : $DEBIAN_IP"
    echo "  默认网关  : $DEFAULT_GW"
    echo "--------------------------------------------------"
    echo "配置项："
    if [ "$RETURN_GW_CONFIGURED" = "true" ]; then
        echo "  回程网关  : $RETURN_GW   [已配置]"
    else
        echo "  回程网关  : 未配置"
    fi
    if [ "$RETURN_GW_CONFIGURED" != "true" ]; then
        echo "  回程端口  : ———          [需先配置回程网关]"
    elif [ "$PORTS_CONFIGURED" = "true" ]; then
        echo "  回程端口  : $PORTS   [已配置]"
    else
        echo "  回程端口  : 未配置"
    fi
    echo "--------------------------------------------------"
    echo "  1. 设置回程网关"
    echo "  2. 设置回程端口"
    echo "  3. 查看详细配置与状态"
    echo "  4. 清理并恢复默认"
    echo "  0. 退出"
    echo "=================================================="
    read -p "请选择 [0-4]: " choice

    case $choice in
        1)
            if [ "$RETURN_GW_CONFIGURED" = "true" ]; then
                while true; do
                    read -p "请输入新的回程网关 (当前: $RETURN_GW，回车保持): " input
                    [ -z "$input" ] && break
                    if validate_ip "$input"; then
                        RETURN_GW="$input"
                        RETURN_GW_CONFIGURED=true
                        echo "✅ 已更新为 $RETURN_GW"
                        sleep 1
                        break
                    else
                        echo "❌ 格式不对，请输入合法的 IPv4 地址。"
                    fi
                done
            else
                echo ""
                echo "检测到 table 100 中没有回程路由，即从未配置过回程网关。"
                read -p "是否现在配置回程网关？[Y/n]: " confirm
                if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
                    while true; do
                        read -p "请输入回程网关 IP（例如 192.168.1.1）: " input
                        if validate_ip "$input"; then
                            RETURN_GW="$input"
                            RETURN_GW_CONFIGURED=true
                            echo "✅ 已设置回程网关为 $RETURN_GW"
                            sleep 1
                            break
                        else
                            echo "❌ 格式不对，请输入合法的 IPv4 地址。"
                        fi
                    done
                fi
            fi
            if [ "$RETURN_GW_CONFIGURED" = "true" ] && [ "$PORTS_CONFIGURED" = "true" ]; then
                auto_apply
                echo "✅ 配置已生效，重启后也会自动恢复。"
                sleep 2
            fi
            ;;
        2)
            if [ "$RETURN_GW_CONFIGURED" != "true" ]; then
                echo ""
                echo "⚠️  请先配置回程网关（选 1），再配置回程端口。"
                sleep 2
                continue
            fi

            if [ "$PORTS_CONFIGURED" != "true" ]; then
                echo ""
                echo "检测到 iptables 中没有回程端口规则，即从未配置过端口。"
                read -p "是否现在配置回程端口？[Y/n]: " confirm
                if [[ "$confirm" =~ ^[Nn]$ ]]; then
                    continue
                fi
                while true; do
                    read -p "请输入端口列表（逗号分隔，例如 80,443）: " input
                    if validate_ports "$input"; then
                        PORTS=$(normalize_ports "$input")
                        PORTS_CONFIGURED=true
                        echo "✅ 已设置回程端口为 $PORTS"
                        sleep 1
                        break
                    else
                        echo "❌ 格式不对，只能是 1-65535 的数字，逗号分隔。"
                    fi
                done
                save_conf
                auto_apply
                echo "✅ 配置已生效，重启后也会自动恢复。"
                sleep 2
                continue
            fi

            while true; do
                clear
                echo "=================================================="
                echo "        回程端口管理"
                echo "=================================================="
                echo "  当前端口  : $PORTS"
                echo "--------------------------------------------------"
                echo "  1. 添加端口"
                echo "  2. 删除端口"
                echo "  3. 重置端口列表（完全替换）"
                echo "  0. 返回上级菜单"
                echo "=================================================="
                read -p "请选择 [0-3]: " port_choice

                case $port_choice in
                    1)
                        read -p "请输入要添加的端口（逗号分隔，例如 8080,9090）: " add_input
                        if validate_ports "$add_input"; then
                            add_list=$(echo "$add_input" | tr ',' ' ' | tr -s ' ')
                            old_list=$(echo "$PORTS" | tr ',' ' ')
                            PORTS=$(normalize_ports "$old_list $add_list")
                            save_conf
                            auto_apply
                            echo "✅ 已添加，当前端口：$PORTS"
                            sleep 2
                        else
                            echo "❌ 端口格式不对。"
                            sleep 2
                        fi
                        ;;
                    2)
                        read -p "请输入要删除的端口（逗号分隔，例如 80）: " del_input
                        del_list=$(echo "$del_input" | tr ',' ' ' | tr -s ' ')
                        new_list=""
                        old_list=$(echo "$PORTS" | tr ',' ' ')
                        for p in $old_list; do
                            skip=false
                            for d in $del_list; do
                                [ "$p" = "$d" ] && skip=true && break
                            done
                            if [ "$skip" = "false" ]; then
                                new_list="$new_list $p"
                            fi
                        done
                        if [ -z "$(echo "$new_list" | tr -d ' ')" ]; then
                            echo "⚠️  删除后端口列表为空。如需清空，请选 3 重置。"
                            sleep 2
                        else
                            PORTS=$(normalize_ports "$new_list")
                            save_conf
                            auto_apply
                            echo "✅ 已删除，当前端口：$PORTS"
                            sleep 2
                        fi
                        ;;
                    3)
                        read -p "请输入全新的端口列表（逗号分隔）: " new_input
                        if validate_ports "$new_input"; then
                            PORTS=$(normalize_ports "$new_input")
                            save_conf
                            auto_apply
                            echo "✅ 已重置为：$PORTS"
                            sleep 2
                        else
                            echo "❌ 端口格式不对。"
                            sleep 2
                        fi
                        ;;
                    0)
                        break
                        ;;
                    *)
                        echo "无效输入。"
                        sleep 1
                        ;;
                esac
            done
            ;;
        3)
            echo ""
            echo "--- 策略路由 (ip rule) ---"
            ip rule show
            echo ""
            echo "--- table 100 路由表 ---"
            ip route show table 100 2>/dev/null || echo "(空)"
            echo ""
            echo "--- iptables mangle 规则 ---"
            iptables -t mangle -S 2>/dev/null
            echo ""
            read -p "按回车键返回菜单..."
            ;;
        4)
            read -p "确认清理所有回程路由规则，并恢复默认网络吗？[y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                clean_rules
                if [ -f "$SERVICE_FILE" ]; then
                    systemctl disable --now public-return-route.service >/dev/null 2>&1
                    rm -f "$SERVICE_FILE"
                    systemctl daemon-reload
                fi
                rm -f "$CONF"
                unset IFACE DEBIAN_IP DEFAULT_GW RETURN_GW PORTS
                unset RETURN_GW_CONFIGURED PORTS_CONFIGURED
                echo ""
                read -p "按回车键返回菜单..."
            fi
            ;;
        0)
            echo "退出菜单。"
            exit 0
            ;;
        *)
            echo "无效输入。"
            sleep 1
            ;;
    esac
done