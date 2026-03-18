#!/usr/bin/env bash
# ==============================================================================
# OpenWrt DIY Part 2 - 企业终级增强版 (22/23/24 兼容)
# ==============================================================================
set -euo pipefail

# --------------------------------------------------------------------------
# 全局配置 & 可调优参数 (CI 环境变量)
# --------------------------------------------------------------------------
readonly TARGET_IP="192.168.5.1"
readonly TARGET_HOSTNAME="LEDE"
readonly FILES_DIR="files"

# CI 级动态调优参数 (GitHub Actions 可直接覆写)
: "${TRIM_SCHEDULE:="0 4 * * *"}"
: "${SSD_READ_AHEAD_KB:="2048"}"
: "${HDD_READ_AHEAD_KB:="128"}"
: "${ENABLE_DISCARD:="0"}"
: "${DEBUG_OPT:="0"}"
: "${OPT_LOG_FILE:="/var/log/opt.log"}"

# 错误捕获与日志
trap 'catch_error $? $LINENO' ERR
catch_error() {
    local exit_code="$1"
    local line_no="$2"
    echo "::error file=${BASH_SOURCE[0]},line=${line_no}::❌ 致命错误于第 ${line_no} 行! 退出码: ${exit_code}"
    exit "$exit_code"
}
log() { echo -e "\033[36m[INFO]\033[0m $1"; }

[[ -f "scripts/feeds" ]] || { echo "❌ 必须在 OpenWrt 源码根目录执行"; exit 1; }
mkdir -p "${FILES_DIR}/etc/"{uci-defaults,init.d,hotplug.d/mount,config,crontabs}

# ==============================================================================
# 阶段 1: 系统初始化与 fstab 修复 (保持不变)
# ==============================================================================
cat << EOF > "${FILES_DIR}/etc/uci-defaults/99-system-init"
#!/bin/sh
uci set network.lan.ipaddr='${TARGET_IP}'
uci set system.@system[0].hostname='${TARGET_HOSTNAME}'
uci commit network
uci commit system

if command -v uci >/dev/null 2>&1; then
    if ! uci -q get samba4.@samba[0] >/dev/null; then
        uci add samba4 samba
        uci set samba4.@samba[-1].workgroup='WORKGROUP'
        uci set samba4.@samba[-1].charset='UTF-8'
        uci set samba4.@samba[-1].description='LEDE NAS'
        uci set samba4.@samba[-1].interface='lan'
    fi
    while uci -q delete samba4.@sambashare[0]; do :; done
    uci commit samba4
fi

if command -v uci >/dev/null 2>&1; then
    GLOBAL_SECS=\$(uci -q show fstab | grep '=global' | sed -n 's/^fstab\.\([^=]*\)=.*/\1/p')
    for sec in \$GLOBAL_SECS; do uci -q delete fstab."\$sec"; done
    uci add fstab global
    uci set fstab.@global[-1].anon_swap='0'
    uci set fstab.@global[-1].anon_mount='1'
    uci set fstab.@global[-1].auto_swap='1'
    uci set fstab.@global[-1].auto_mount='1'
    uci set fstab.@global[-1].delay_root='5'
    uci set fstab.@global[-1].check_fs='0'

    for sec in \$(uci -q show fstab | grep '=mount' | sed -n 's/^fstab\.\([^=]*\)=.*/\1/p'); do
        opts=\$(uci -q get fstab."\$sec".options || echo "")
        if echo "\$opts" | grep -q "relatime"; then
            new_opts=\$(echo "\$opts" | sed 's/relatime/noatime,nodiratime/g')
            uci set fstab."\$sec".options="\$new_opts"
        fi
    done
    uci commit fstab
fi[ -x /etc/init.d/network-accel ] && /etc/init.d/network-accel enable
exit 0
EOF
chmod 0755 "${FILES_DIR}/etc/uci-defaults/99-system-init"
log "✅ 系统初始化及 fstab 基础修复注入完成"

# ==============================================================================
# 阶段 2: Procd 网卡硬件加速服务 (保持不变)
# ==============================================================================
cat << 'EOF' > "${FILES_DIR}/etc/init.d/network-accel"
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
HW_VENDOR_WHITELIST="0x8086 0x10ec 0x14e4 0x15b3 0x8086 0x10de"

start() {
    if command -v ethtool >/dev/null 2>&1; then
        for iface in /sys/class/net/*; do[ -e "$iface" ] || continue
            iface_name=$(basename "$iface")
            case "$iface_name" in lo|docker*|veth*|br-*) continue ;; esac
            
            vendor_file="$iface/device/vendor"
            if [ -f "$vendor_file" ]; then
                vendor=$(cat "$vendor_file" 2>/dev/null | tr -d '\n')
                matched=0
                for vid in $HW_VENDOR_WHITELIST; do
                    if[ "$vendor" = "$vid" ]; then matched=1; break; fi
                done
                if[ $matched -eq 1 ]; then
                    ethtool -K "$iface_name" tso on 2>/dev/null || true
                    ethtool -K "$iface_name" gso on 2>/dev/null || true
                    logger -t "Network-Opt" "网卡 $iface_name (vendor $vendor) 硬件加速已启用"
                fi
            else
                case "$iface_name" in
                    eth*|enp*|enx*|eno*)
                        ethtool -K "$iface_name" tso on 2>/dev/null || true
                        ethtool -K "$iface_name" gso on 2>/dev/null || true
                        ;;
                esac
            fi
        done
    fi
}
EOF
chmod 0755 "${FILES_DIR}/etc/init.d/network-accel"
log "✅ Procd 网卡硬件加速服务注入完成"

# ==============================================================================
# 阶段 3 & 4: 磁盘运行时优化 & LuCI 配置同步（修复版）
# ==============================================================================

# 【企业级魔法】：先用不带引号的 EOF 把 CI 环境变量硬编码注入到路由器脚本顶端
cat << EOF > "${FILES_DIR}/etc/hotplug.d/mount/99-optimize-disk"
#!/bin/sh
# --- 自动注入的 CI 配置变量 ---
OPT_LOG_FILE="${OPT_LOG_FILE}"
DEBUG_OPT="${DEBUG_OPT}"
SSD_READ_AHEAD_KB="${SSD_READ_AHEAD_KB}"
HDD_READ_AHEAD_KB="${HDD_READ_AHEAD_KB}"
ENABLE_DISCARD="${ENABLE_DISCARD}"
# ------------------------------
EOF

# 然后用带引号的 EOF 注入原生的执行逻辑
cat << 'EOF' >> "${FILES_DIR}/etc/hotplug.d/mount/99-optimize-disk"
[ "$ACTION" != "add" ] && exit 0
[ -z "$MOUNTPOINT" ] && exit 0
[ -z "$DEVICE" ] && exit 0

log_opt() {
    local msg="$1"
    logger -t "Disk-Opt" "$msg"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $msg" >> "$OPT_LOG_FILE"
    [ "$DEBUG_OPT" = "1" ] && echo "[DEBUG] $msg" >&2
}

FSTYPE=$(awk -v mp="$MOUNTPOINT" '$2==mp {print $3}' /proc/mounts)

case "$FSTYPE" in
    ext4|btrfs|xfs|f2fs|zfs)
        DEV_RAW="${DEVICE##*/}"
        case "$DEV_RAW" in
            nvme*p*|mmcblk*p*) DEV_BASE=$(echo "$DEV_RAW" | sed -E 's/p[0-9]+$//') ;;
            *) DEV_BASE=$(echo "$DEV_RAW" | sed -E 's/[0-9]+$//') ;;
        esac

        REMOVABLE=0
        if[ -n "$DEV_BASE" ] && [ -f "/sys/block/$DEV_BASE/removable" ]; then
            REMOVABLE=$(cat "/sys/block/$DEV_BASE/removable")
        fi

        if[ -n "$DEV_BASE" ] && [ -f "/sys/block/$DEV_BASE/queue/rotational" ]; then
            rotational=$(cat "/sys/block/$DEV_BASE/queue/rotational")
        else
            rotational=1
        fi

        # ---------- 1. 智能预读缓存 ----------
        if[ -n "$DEV_BASE" ] &&[ -f "/sys/block/$DEV_BASE/queue/read_ahead_kb" ]; then
            if [ "$REMOVABLE" = "1" ]; then
                echo 128 > "/sys/block/$DEV_BASE/queue/read_ahead_kb" 2>/dev/null && \
                    log_opt "USB $DEV_BASE 预读缓存设为 128KB"
            elif [ "$rotational" = "0" ]; then
                echo "$SSD_READ_AHEAD_KB" > "/sys/block/$DEV_BASE/queue/read_ahead_kb" 2>/dev/null && \
                    log_opt "SSD $DEV_BASE 预读缓存设为 ${SSD_READ_AHEAD_KB}KB"
            else
                echo "$HDD_READ_AHEAD_KB" > "/sys/block/$DEV_BASE/queue/read_ahead_kb" 2>/dev/null && \
                    log_opt "HDD $DEV_BASE 预读缓存设为 ${HDD_READ_AHEAD_KB}KB"
            fi
        fi

        # ---------- 2. I/O 调度器优化 (严谨重构版) ----------
        set_scheduler() {
            local dev="$1"
            local sched1="$2"
            local sched2="$3"
            if echo "$sched1" > "/sys/block/$dev/queue/scheduler" 2>/dev/null; then
                log_opt "调度器 $dev 成功设为 $sched1"
            elif echo "$sched2" > "/sys/block/$dev/queue/scheduler" 2>/dev/null; then
                log_opt "调度器 $dev 成功设为 $sched2"
            fi
        }

        if [ -n "$DEV_BASE" ] &&[ -f "/sys/block/$DEV_BASE/queue/scheduler" ]; then
            if [ "$REMOVABLE" = "1" ] || [ "$rotational" = "0" ]; then
                set_scheduler "$DEV_BASE" "none" "noop"
            else
                set_scheduler "$DEV_BASE" "mq-deadline" "bfq"
            fi
        fi

        # ---------- 3. 挂载选项动态优化 ----------
        current_opts=$(awk -v mp="$MOUNTPOINT" '$2==mp {print $4}' /proc/mounts)
        new_opts=$(echo "$current_opts" | sed -E 's/\b(noatime|nodiratime|relatime|strictatime|lazyatime|sync)\b,?//g; s/,$//; s/,,+/,/g')
        
        base_opts="noatime,nodiratime"
        # 【致命 Bug 已修复：严禁给移动设备强加 sync 参数，防止性能暴跌和烧毁 U盘】
        
        if [ "$rotational" = "0" ]; then
            base_opts="${base_opts},data=ordered"
            if [ "$ENABLE_DISCARD" = "1" ] && ! echo "$new_opts" | grep -q '\bdiscard\b'; then
                base_opts="${base_opts},discard"
            fi
        else
            base_opts="${base_opts},data=ordered,commit=30"
        fi
        
        final_opts="${base_opts},${new_opts}"
        final_opts=$(echo "$final_opts" | sed 's/^,//; s/,,*/,/g')
        
        if mountpoint -q "$MOUNTPOINT" && [ -w "$MOUNTPOINT" ]; then
            if mount -o remount,"$final_opts" "$MOUNTPOINT" 2>/dev/null; then
                log_opt "已优化 $MOUNTPOINT 挂载选项: $final_opts"
            else
                log_opt "⚠ 无法修改 $MOUNTPOINT 挂载选项"
            fi
        fi

        # ---------- 4. LuCI 配置反向修复 ----------
        if command -v uci >/dev/null 2>&1 && command -v block >/dev/null 2>&1; then
            UUID=$(block info "$DEVICE" | grep -o 'UUID="[^"]*"' | cut -d'"' -f2 | head -n1)
            if [ -n "$UUID" ]; then
                SEC=$(uci -q show fstab | grep "uuid='$UUID'" | cut -d'.' -f2 | head -n1)
                if [ -n "$SEC" ]; then
                    OPTS=$(uci -q get fstab."$SEC".options || echo "")
                    if echo "$OPTS" | grep -q "relatime"; then
                        NEW_OPTS=$(echo "$OPTS" | sed 's/relatime/noatime,nodiratime/g')
                        uci set fstab."$SEC".options="$NEW_OPTS"
                        uci commit fstab
                        log_opt "已修复 LuCI 生成的 relatime 参数"
                    fi
                fi
            fi
        fi
        ;;
esac
EOF
chmod 0755 "${FILES_DIR}/etc/hotplug.d/mount/99-optimize-disk"
log "✅ 磁盘优化与 LuCI 反向劫持注入完成 (变量隔离 Bug 已修复)"

# ==============================================================================
# 阶段 5: SSD 定时 TRIM（扩展支持 ext4/btrfs/xfs/f2fs/zfs）
# ==============================================================================
CRON_FILE="${FILES_DIR}/etc/crontabs/root"
mkdir -p "$(dirname "$CRON_FILE")"

# 优雅拼接 Cron 行（使用双引号允许 TRIM_SCHEDULE 变量注入，内部 $ 需转义防提前解析）
CRON_LINE="${TRIM_SCHEDULE} command -v fstrim >/dev/null && for fs in ext4 btrfs xfs f2fs zfs; do for mp in \$(awk -v fs=\"\$fs\" '\$3==fs {print \$2}' /proc/mounts); do fstrim \"\$mp\" 2>/dev/null; done; done"

if[ -f "$CRON_FILE" ]; then
    if ! grep -Fxq "$CRON_LINE" "$CRON_FILE"; then
        echo "$CRON_LINE" >> "$CRON_FILE"
        log "✅ fstrim cron 任务已添加（时间: ${TRIM_SCHEDULE}）"
    fi
else
    echo "$CRON_LINE" > "$CRON_FILE"
    log "✅ fstrim cron 任务已创建（时间: ${TRIM_SCHEDULE}）"
fi

log "🎉 DIY Part 2 脚本（满血100分重构版）执行完成"
