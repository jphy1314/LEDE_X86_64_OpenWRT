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

: "${TRIM_SCHEDULE:="0 4 * * *"}"
: "${SSD_READ_AHEAD_KB:="2048"}"
: "${HDD_READ_AHEAD_KB:="128"}"
: "${ENABLE_DISCARD:="0"}"
: "${DEBUG_OPT:="0"}"
: "${OPT_LOG_FILE:="/var/log/opt.log"}"

trap 'catch_error $? $LINENO' ERR
catch_error() {
    local exit_code="$1"
    local line_no="$2"
    echo "::error file=${BASH_SOURCE[0]},line=${line_no}::❌ 致命错误于第 ${line_no} 行! 退出码: ${exit_code}"
    exit "$exit_code"
}
log() { echo -e "\033[36m[INFO]\033[0m $1"; }

[[ -f "scripts/feeds" ]] || { echo "❌ 必须在 OpenWrt 源码根目录执行"; exit 1; }
mkdir -p "${FILES_DIR}/etc/"{uci-defaults,init.d,hotplug.d/mount,config}
mkdir -p "${FILES_DIR}/usr/bin"

# ==============================================================================
# 阶段 1: 系统初始化修复 (Samba4 补齐与全局 Fstab 清理)
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

    # 纯 POSIX 方案安全移除旧的 relatime
    for sec in \$(uci -q show fstab | grep '=mount' | sed -n 's/^fstab\.\([^=]*\)=.*/\1/p'); do
        target=\$(uci -q get fstab."\$sec".target || echo "")
        # 【护盾】：绝对不碰系统引导盘和内部虚拟分区，保持系统纯净
        case "\$target" in / | /rom | /overlay | /boot | /mnt/loop*) continue ;; esac

        opts=\$(uci -q get fstab."\$sec".options || echo "defaults")
        if ! echo "\$opts" | grep -q "noatime"; then
            new_opts=\$(echo ",\$opts," | sed 's/,relatime,/,/g; s/,strictatime,/,/g; s/,defaults,/,/g')
            new_opts=\$(echo "\$new_opts" | sed 's/,,*/,/g; s/^,//; s/,$//')
            uci set fstab."\$sec".options="noatime,nodiratime\${new_opts:+,}\${new_opts}"
        fi
    done
    uci commit fstab
fi
[ -x /etc/init.d/network-accel ] && /etc/init.d/network-accel enable
exit 0
EOF
chmod 0755 "${FILES_DIR}/etc/uci-defaults/99-system-init"
log "✅ 系统初始化基础修复注入完成"

# ==============================================================================
# 阶段 2: 注入 fstab 同步拦截器 (保护系统盘，精准劫持)
# ==============================================================================
FSTAB_INIT="package/system/fstools/files/fstab.init"
if [ -f "$FSTAB_INIT" ]; then
    log "🔥 正在注入 fstab 同步拦截器..."

    TMP_SANITIZE=$(mktemp)
    cat << 'FUNC_EOF' > "$TMP_SANITIZE"
sanitize_fstab() {
    if command -v uci >/dev/null 2>&1; then
        local changed=0
        for sec in $(uci -q show fstab | grep "=mount" | sed -n "s/^fstab\.\([^=]*\)=.*/\1/p"); do
            local target=$(uci -q get fstab."$sec".target || echo "")
            # 【护盾】：不碰系统盘
            case "$target" in / | /rom | /overlay | /boot | /mnt/loop*) continue ;; esac

            local opts=$(uci -q get fstab."$sec".options || echo "defaults")
            if ! echo "$opts" | grep -q "noatime"; then
                local new_opts=$(echo ",$opts," | sed "s/,relatime,/,/g; s/,strictatime,/,/g; s/,defaults,/,/g" | sed "s/,,*/,/g; s/^,//; s/,$//")
                uci set fstab."$sec".options="noatime,nodiratime${new_opts:+,}${new_opts}"
                changed=1
            fi
        done
        [ "$changed" = "1" ] && uci commit fstab
    fi
}
FUNC_EOF

    sed -i "/^START=/r $TMP_SANITIZE" "$FSTAB_INIT"
    rm -f "$TMP_SANITIZE"
    sed -i 's|/sbin/block mount|sanitize_fstab; /sbin/block mount|g' "$FSTAB_INIT"
    log "✅ fstab 同步拦截器注入完成"
fi

# ==============================================================================
# 阶段 3: Procd 网卡硬件加速服务
# ==============================================================================
cat << 'EOF' > "${FILES_DIR}/etc/init.d/network-accel"
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
HW_VENDOR_WHITELIST="0x8086 0x10ec 0x14e4 0x15b3 0x8086 0x10de"

start() {
    if command -v ethtool >/dev/null 2>&1; then
        for iface in /sys/class/net/*; do [ -e "$iface" ] || continue
            iface_name=$(basename "$iface")
            case "$iface_name" in lo|docker*|veth*|br-*) continue ;; esac

            vendor_file="$iface/device/vendor"
            if [ -f "$vendor_file" ]; then
                vendor=$(cat "$vendor_file" 2>/dev/null | tr -d '\n')
                matched=0
                for vid in $HW_VENDOR_WHITELIST; do
                    if [ "$vendor" = "$vid" ]; then matched=1; break; fi
                done
                if [ $matched -eq 1 ]; then
                    ethtool -K "$iface_name" tso on 2>/dev/null || true
                    ethtool -K "$iface_name" gso on 2>/dev/null || true
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
# 阶段 4: 物理磁盘硬件级运行时优化
# ==============================================================================
cat << EOF > "${FILES_DIR}/etc/hotplug.d/mount/99-optimize-disk"
#!/bin/sh
OPT_LOG_FILE="${OPT_LOG_FILE}"
DEBUG_OPT="${DEBUG_OPT}"
SSD_READ_AHEAD_KB="${SSD_READ_AHEAD_KB}"
HDD_READ_AHEAD_KB="${HDD_READ_AHEAD_KB}"
ENABLE_DISCARD="${ENABLE_DISCARD}"
EOF

cat << 'EOF' >> "${FILES_DIR}/etc/hotplug.d/mount/99-optimize-disk"
[ "$ACTION" != "add" ] && exit 0
[ -z "$MOUNTPOINT" ] && exit 0
[ -z "$DEVICE" ] && exit 0

mkdir -p "$(dirname "$OPT_LOG_FILE")" 2>/dev/null || true
log_opt() {
    local msg="$1"
    logger -t "Disk-Opt" "$msg"
    [ -w "$OPT_LOG_FILE" ] && echo "[$(date +'%Y-%m-%d %H:%M:%S')] $msg" >> "$OPT_LOG_FILE"
}

FSTYPE=$(awk -v mp="$MOUNTPOINT" '$2==mp {print $3}' /proc/mounts)

case "$FSTYPE" in
    ext4|btrfs|xfs|f2fs|zfs|ntfs|ntfs3|exfat|vfat)
        DEV_RAW="${DEVICE##*/}"
        case "$DEV_RAW" in
            nvme*p*|mmcblk*p*) DEV_BASE=$(echo "$DEV_RAW" | sed 's/p[0-9][0-9]*$//') ;;
            *) DEV_BASE=$(echo "$DEV_RAW" | sed 's/[0-9][0-9]*$//') ;;
        esac

        REMOVABLE=0
        [ -n "$DEV_BASE" ] && [ -f "/sys/block/$DEV_BASE/removable" ] && REMOVABLE=$(cat "/sys/block/$DEV_BASE/removable")
        
        rotational=1
        [ -n "$DEV_BASE" ] && [ -f "/sys/block/$DEV_BASE/queue/rotational" ] && rotational=$(cat "/sys/block/$DEV_BASE/queue/rotational")

        # 1. 预读缓存
        if [ -n "$DEV_BASE" ] && [ -f "/sys/block/$DEV_BASE/queue/read_ahead_kb" ]; then
            if [ "$REMOVABLE" = "1" ]; then
                echo 128 > "/sys/block/$DEV_BASE/queue/read_ahead_kb" 2>/dev/null && log_opt "USB $DEV_BASE 预读缓存设为 128KB"
            elif [ "$rotational" = "0" ]; then
                echo "$SSD_READ_AHEAD_KB" > "/sys/block/$DEV_BASE/queue/read_ahead_kb" 2>/dev/null && log_opt "SSD $DEV_BASE 预读缓存设为 ${SSD_READ_AHEAD_KB}KB"
            else
                echo "$HDD_READ_AHEAD_KB" > "/sys/block/$DEV_BASE/queue/read_ahead_kb" 2>/dev/null && log_opt "HDD $DEV_BASE 预读缓存设为 ${HDD_READ_AHEAD_KB}KB"
            fi
        fi

        # 2. IO调度器
        set_scheduler() {
            local dev="$1"; local sched1="$2"; local sched2="$3"
            if echo "$sched1" > "/sys/block/$dev/queue/scheduler" 2>/dev/null; then log_opt "调度器 $dev 设为 $sched1"
            elif echo "$sched2" > "/sys/block/$dev/queue/scheduler" 2>/dev/null; then log_opt "调度器 $dev 设为 $sched2"
            fi
        }
        if [ -n "$DEV_BASE" ] && [ -f "/sys/block/$DEV_BASE/queue/scheduler" ]; then
            if [ "$REMOVABLE" = "1" ] || [ "$rotational" = "0" ]; then
                set_scheduler "$DEV_BASE" "none" "noop"
            else
                set_scheduler "$DEV_BASE" "mq-deadline" "bfq"
            fi
        fi

        # 3. 挂载选项动态优化 (已移除 data=ordered 避免 remount 报错)
        current_opts=$(awk -v mp="$MOUNTPOINT" '$2==mp {print $4}' /proc/mounts)
        clean_opts=$(echo ",$current_opts," | sed 's/,noatime,/,/g; s/,nodiratime,/,/g; s/,relatime,/,/g; s/,strictatime,/,/g; s/,lazyatime,/,/g; s/,sync,/,/g')
        clean_opts=$(echo "$clean_opts" | sed 's/,,*/,/g; s/^,//; s/,$//')
        
        base_opts="noatime,nodiratime"
        
        if [ "$FSTYPE" = "ext4" ]; then
            if [ "$rotational" = "0" ]; then
                [ "$ENABLE_DISCARD" = "1" ] && ! echo ",$clean_opts," | grep -q ",discard," && base_opts="${base_opts},discard"
            else
                base_opts="${base_opts},commit=30"
            fi
        elif [ "$rotational" = "0" ] && [ "$ENABLE_DISCARD" = "1" ]; then
            if [ "$FSTYPE" = "btrfs" ] || [ "$FSTYPE" = "xfs" ] || [ "$FSTYPE" = "f2fs" ]; then
                ! echo ",$clean_opts," | grep -q ",discard," && base_opts="${base_opts},discard"
            fi
        fi
        
        final_opts="${base_opts}${clean_opts:+,}${clean_opts}"
        
        if mountpoint -q "$MOUNTPOINT" && [ -w "$MOUNTPOINT" ]; then
            if /bin/mount -o remount,"$final_opts" "$MOUNTPOINT" 2>/dev/null; then
                log_opt "已底层优化 $MOUNTPOINT 挂载选项: $final_opts ($FSTYPE)"
            fi
        fi

        # 4. LuCI 配置反向修复
        if command -v uci >/dev/null 2>&1 && command -v block >/dev/null 2>&1; then
            UUID=$(block info "$DEVICE" | grep -o 'UUID="[^"]*"' | cut -d'"' -f2 | head -n1)
            SEC=""
            [ -n "$UUID" ] && SEC=$(uci -q show fstab | grep "uuid='$UUID'" | cut -d'.' -f2 | head -n1)
            [ -z "$SEC" ] && SEC=$(uci -q show fstab | grep "device='$DEVICE'" | cut -d'.' -f2 | head -n1)

            if [ -n "$SEC" ]; then
                TARGET=$(uci -q get fstab."$SEC".target || echo "")
                case "$TARGET" in
                    /|/rom|/overlay|/boot|/mnt/loop*) ;;
                    *)
                        OPTS=$(uci -q get fstab."$SEC".options || echo "")
                        if ! echo "$OPTS" | grep -q "noatime"; then
                            NEW_OPTS=$(echo ",$OPTS," | sed 's/,relatime,/,/g; s/,strictatime,/,/g; s/,sync,/,/g; s/,defaults,/,/g')
                            NEW_OPTS=$(echo "$NEW_OPTS" | sed 's/,,*/,/g; s/^,//; s/,$//')
                            FINAL_UCI_OPTS="noatime,nodiratime${NEW_OPTS:+,}${NEW_OPTS}"
                            uci set fstab."$SEC".options="$FINAL_UCI_OPTS"
                            uci commit fstab
                            log_opt "已暴改 LuCI 生成的挂载参数: -> $FINAL_UCI_OPTS"
                        fi
                        ;;
                esac
            fi
        fi
        ;;
esac
EOF
chmod 0755 "${FILES_DIR}/etc/hotplug.d/mount/99-optimize-disk"
log "✅ 物理磁盘硬件级热插拔优化注入完成"

# ==============================================================================
# 阶段 5: SSD 定时 TRIM (利用 uci-defaults 开机注入，完美绕过编译期抹除)
# ==============================================================================
cat << 'EOF' > "${FILES_DIR}/usr/bin/auto-fstrim"
#!/bin/sh
command -v fstrim >/dev/null || exit 0
for fs in ext4 btrfs xfs f2fs zfs; do
    for mp in $(awk -v fs="$fs" '$3==fs {print $2}' /proc/mounts); do
        fstrim "$mp" 2>/dev/null
    done
done
EOF
chmod 0755 "${FILES_DIR}/usr/bin/auto-fstrim"

cat << EOF > "${FILES_DIR}/etc/uci-defaults/99-system-cron"
#!/bin/sh
CRON_FILE="/etc/crontabs/root"
mkdir -p "/etc/crontabs"
touch "\$CRON_FILE"
sed -i '/auto-fstrim/d' "\$CRON_FILE" 2>/dev/null || true
echo "${TRIM_SCHEDULE} /usr/bin/auto-fstrim" >> "\$CRON_FILE"
/etc/init.d/cron restart
exit 0
EOF
chmod 0755 "${FILES_DIR}/etc/uci-defaults/99-system-cron"
log "✅ 独立 auto-fstrim 引擎及动态 Cron 任务注入完成"

log "🎉 DIY Part 2 脚本（满血100分排错版）执行完成"
