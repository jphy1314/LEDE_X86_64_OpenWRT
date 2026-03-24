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

# 【保留你的正确修改】：错峰到凌晨 3 点，完美避开 4 点的跑分压榨！
: "${TRIM_SCHEDULE:="0 3 * * *"}"
: "${SSD_READ_AHEAD_KB:="2048"}"
: "${HDD_READ_AHEAD_KB:="128"}"

trap 'catch_error $? $LINENO' ERR
catch_error() {
    local exit_code="$1"
    local line_no="$2"
    echo "::error file=${BASH_SOURCE[0]},line=${line_no}::❌ 致命错误于第 ${line_no} 行! 退出码: ${exit_code}"
    exit "$exit_code"
}
log() { echo -e "\033[36m[INFO]\033[0m $1"; }

[[ -f "scripts/feeds" ]] || { echo "❌ 必须在 OpenWrt 源码根目录执行"; exit 1; }
mkdir -p "${FILES_DIR}/etc/"{uci-defaults,init.d,hotplug.d/block,hotplug.d/mount,config}
mkdir -p "${FILES_DIR}/usr/bin"

# 补充：确保固件包含 util-linux
if [ -f .config ]; then
    if ! grep -q "CONFIG_PACKAGE_util-linux=y" .config; then
        echo "CONFIG_PACKAGE_util-linux=y" >> .config
        log "✅ 已在 .config 中添加 util-linux 包"
    fi
fi

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

    for sec in \$(uci -q show fstab | grep '=mount' | sed -n 's/^fstab\.\([^=]*\)=.*/\1/p'); do
        target=\$(uci -q get fstab."\$sec".target || echo "")
        case "\$target" in /|/rom|/overlay|/boot|/mnt/loop*) continue ;; esac

        opts=\$(uci -q get fstab."\$sec".options || echo "defaults")
        if ! echo "\$opts" | grep -q "noatime"; then
            new_opts=\$(echo ",\$opts," | sed 's/,relatime,/,/g; s/,strictatime,/,/g; s/,defaults,/,/g')
            new_opts=\$(echo "\$new_opts" | sed 's/,,*/,/g; s/^,//; s/,$//')
            if [ -n "\$new_opts" ]; then
                uci set fstab."\$sec".options="noatime,nodiratime,\$new_opts"
            else
                uci set fstab."\$sec".options="noatime,nodiratime"
            fi
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
# 阶段 2: Procd 网卡硬件加速服务
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
# 阶段 3: 物理块设备级拦截器 (解决 I/O 调度和预读无法生效的顽疾)
# ==============================================================================
cat << EOF > "${FILES_DIR}/etc/hotplug.d/block/99-optimize-io"
#!/bin/sh
SSD_READ_AHEAD_KB="${SSD_READ_AHEAD_KB}"
HDD_READ_AHEAD_KB="${HDD_READ_AHEAD_KB}"
EOF

cat << 'EOF' >> "${FILES_DIR}/etc/hotplug.d/block/99-optimize-io"
[ "$ACTION" = "add" ] || exit 0
[ -z "$DEVNAME" ] && exit 0

# 仅拦截物理基础设备 (如 sdb, nvme0n1)，跳过逻辑分区 (sdb1)
if [ ! -f "/sys/block/$DEVNAME/queue/scheduler" ]; then
    exit 0
fi

REMOVABLE=$(cat "/sys/block/$DEVNAME/removable" 2>/dev/null || echo 0)
ROTATIONAL=$(cat "/sys/block/$DEVNAME/queue/rotational" 2>/dev/null || echo 1)

# 1. 预读缓存
if [ "$REMOVABLE" = "1" ]; then
    echo 128 > "/sys/block/$DEVNAME/queue/read_ahead_kb" 2>/dev/null || true
elif [ "$ROTATIONAL" = "0" ]; then
    echo "$SSD_READ_AHEAD_KB" > "/sys/block/$DEVNAME/queue/read_ahead_kb" 2>/dev/null || true
else
    echo "$HDD_READ_AHEAD_KB" > "/sys/block/$DEVNAME/queue/read_ahead_kb" 2>/dev/null || true
fi

# 2. I/O 调度器
if [ "$REMOVABLE" = "1" ] || [ "$ROTATIONAL" = "0" ]; then
    echo "none" > "/sys/block/$DEVNAME/queue/scheduler" 2>/dev/null || \
    echo "noop" > "/sys/block/$DEVNAME/queue/scheduler" 2>/dev/null || true
else
    echo "mq-deadline" > "/sys/block/$DEVNAME/queue/scheduler" 2>/dev/null || \
    echo "bfq" > "/sys/block/$DEVNAME/queue/scheduler" 2>/dev/null || true
fi
EOF
chmod 0755 "${FILES_DIR}/etc/hotplug.d/block/99-optimize-io"
log "✅ 物理层块设备 I/O 调优拦截器注入完成"

# ==============================================================================
# 阶段 4: 逻辑挂载点级拦截器 (暴力 Remount，彻底斩断 LuCI 污染)
# ==============================================================================
cat << 'EOF' > "${FILES_DIR}/etc/hotplug.d/mount/99-optimize-mount"
#!/bin/sh
[ "$ACTION" = "add" ] || exit 0
[ -z "$MOUNTPOINT" ] && exit 0
[ -z "$DEVICE" ] && exit 0

# 1. 极致暴力的运行时 Remount：无视原来是什么挂载参数，利用 remount 的增量特性直接强加 noatime！
# 这种写法绝对不会触发内核 Ext4 的 data=ordered 拒绝，也完全不需要复杂的字符串解析。
/bin/mount -o remount,noatime,nodiratime "$MOUNTPOINT" 2>/dev/null || true

# 2. LuCI 配置反向修复：如果用户是在界面操作导致的挂载，立刻清洗 fstab 防止重启后复发！
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
                    NEW_OPTS=$(echo ",$OPTS," | sed 's/,relatime,/,/g; s/,strictatime,/,/g; s/,defaults,/,/g')
                    NEW_OPTS=$(echo "$NEW_OPTS" | sed 's/,,*/,/g; s/^,//; s/,$//')
                    if [ -n "$NEW_OPTS" ]; then
                        FINAL_UCI_OPTS="noatime,nodiratime,$NEW_OPTS"
                    else
                        FINAL_UCI_OPTS="noatime,nodiratime"
                    fi
                    uci set fstab."$SEC".options="$FINAL_UCI_OPTS"
                    uci commit fstab
                fi
                ;;
        esac
    fi
fi
EOF
chmod 0755 "${FILES_DIR}/etc/hotplug.d/mount/99-optimize-mount"
log "✅ 挂载点逻辑拦截器 (Remount + UCI 修复) 注入完成"

# ==============================================================================
# 阶段 5: SSD 定时 TRIM (利用字母 Z 强制排序，反杀洗白)
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

cat << EOF > "${FILES_DIR}/etc/uci-defaults/99-zzz-diy-cron"
#!/bin/sh
mkdir -p /etc/crontabs
touch /etc/crontabs/root
sed -i '/auto-fstrim/d' /etc/crontabs/root 2>/dev/null || true
echo "${TRIM_SCHEDULE} /usr/bin/auto-fstrim" >> /etc/crontabs/root
/etc/init.d/cron restart
exit 0
EOF
chmod 0755 "${FILES_DIR}/etc/uci-defaults/99-zzz-diy-cron"
log "✅ 独立 auto-fstrim 引擎及动态 Cron 任务注入完成"

log "🎉 DIY Part 2 脚本（极致解耦终极重构版）执行完成"
