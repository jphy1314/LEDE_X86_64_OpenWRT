#!/usr/bin/env bash
# ==============================================================================
# OpenWrt DIY Part 2 - 企业终级增强版 (22/23/24 兼容)
# 功能：
#   - 系统初始化 UCI 配置 (彻底修复 fstab 重叠)
#   - 网卡硬件加速 (物理网卡精准匹配)
#   - 磁盘运行时优化 (区分 SSD/HDD、NVMe/eMMC 兼容、智能预读、动态选项)
#   - 扩展型多文件系统 SSD TRIM
#   - 增强可观测性：独立日志文件、debug 开关
#   - 动态可调优参数（支持 CI 环境变量覆盖）
# ==============================================================================
set -euo pipefail

# --------------------------------------------------------------------------
# 全局配置 & 可调优参数 (CI 环境变量)
# --------------------------------------------------------------------------
readonly TARGET_IP="192.168.5.1"
readonly TARGET_HOSTNAME="LEDE"
readonly FILES_DIR="files"

: "${TRIM_SCHEDULE:="0 4 * * *"}"            # fstrim 定时任务时间
: "${SSD_READ_AHEAD_KB:="2048"}"              # SSD 预读缓存大小 (KB)
: "${HDD_READ_AHEAD_KB:="128"}"                # HDD 预读缓存大小 (KB)
: "${ENABLE_DISCARD:="0"}"                      # 是否在 SSD 挂载选项中加入 discard (0/1)
: "${DEBUG_OPT:="0"}"                           # 调试模式 (0/1)
: "${OPT_LOG_FILE:="/var/log/opt.log"}"         # 优化日志文件路径

# 错误捕获函数
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
# 预创建日志文件（确保权限）
touch "$OPT_LOG_FILE" 2>/dev/null || true

# ==============================================================================
# 阶段 1: 系统初始化与 fstab 修复
# ==============================================================================
cat << EOF > "${FILES_DIR}/etc/uci-defaults/99-system-init"
#!/bin/sh
# -------------------------------------------------------------------------
# 系统初始化脚本 (UCI 默认执行)
# -------------------------------------------------------------------------

uci set network.lan.ipaddr='${TARGET_IP}'
uci set system.@system[0].hostname='${TARGET_HOSTNAME}'
uci commit network
uci commit system

# 自动配置 Samba4（若存在）
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

# 修正 fstab 全局配置和挂载选项
if command -v uci >/dev/null 2>&1; then
    # 正确提取所有 global 节名（修正：过滤出纯净的节名）
    GLOBAL_SECS=\$(uci -q show fstab | grep '=global' | sed -n 's/^fstab\.\([^=]*\)=.*/\1/p')
    
    # 删除所有已有的 global 节，确保只有一个且索引为 0
    for sec in \$GLOBAL_SECS; do
        uci -q delete fstab."\$sec"
    done

    # 重新添加一个干净的 global 节
    uci add fstab global
    uci set fstab.@global[-1].anon_swap='0'
    uci set fstab.@global[-1].anon_mount='1'
    uci set fstab.@global[-1].auto_swap='1'
    uci set fstab.@global[-1].auto_mount='1'
    uci set fstab.@global[-1].delay_root='5'
    uci set fstab.@global[-1].check_fs='0'

    # 修正 mount 节中的 relatime 选项（仅当 options 存在且包含 relatime 时）
    for sec in \$(uci -q show fstab | grep '=mount' | sed -n 's/^fstab\.\([^=]*\)=.*/\1/p'); do
        opts=\$(uci -q get fstab."\$sec".options || echo "defaults")
        # 强行塞入 noatime，无视空值
        if ! echo "\$opts" | grep -q "noatime"; then
            new_opts=\$(echo "\$opts" | sed -E 's/\b(relatime|strictatime)\b,?//g')
            [ "\$new_opts" = "defaults" ] && new_opts=""
            uci set fstab."\$sec".options="noatime,nodiratime,\${new_opts}"
            uci set fstab."\$sec".options="\$(uci -q get fstab."\$sec".options | sed 's/,$//; s/^,//')"
        fi
    done

    uci commit fstab
fi

[ -x /etc/init.d/network-accel ] && /etc/init.d/network-accel enable
exit 0
EOF

chmod 0755 "${FILES_DIR}/etc/uci-defaults/99-system-init"
log "✅ 系统初始化及 fstab 基础修复注入完成"

# ==============================================================================
# 阶段 2: Procd 网卡硬件加速服务（增强版：vendor ID 匹配）
# ==============================================================================
cat << 'EOF' > "${FILES_DIR}/etc/init.d/network-accel"
#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1

# 可手动添加的厂商白名单（PCI vendor ID），以空格分隔
HW_VENDOR_WHITELIST="0x8086 0x10ec 0x14e4 0x15b3 0x8086 0x10de"

start() {
    if command -v ethtool >/dev/null 2>&1; then
        for iface in /sys/class/net/*; do
            [ -e "$iface" ] || continue
            iface_name=$(basename "$iface")
            # 跳过回环和虚拟接口
            case "$iface_name" in lo|docker*|veth*|br-*) continue ;; esac
            
            vendor_file="$iface/device/vendor"
            if [ -f "$vendor_file" ]; then
                vendor=$(cat "$vendor_file" 2>/dev/null | tr -d '\n')
                # 检查 vendor 是否在白名单中
                matched=0
                for vid in $HW_VENDOR_WHITELIST; do
                    if [ "$vendor" = "$vid" ]; then
                        matched=1
                        break
                    fi
                done
                if [ $matched -eq 1 ]; then
                    ethtool -K "$iface_name" tso on 2>/dev/null || true
                    ethtool -K "$iface_name" gso on 2>/dev/null || true
                    logger -t "Network-Opt" "网卡 $iface_name 硬件加速已启用"
                fi
            else
                # 无 vendor 文件的接口（如 USB 网卡），按名称启发式匹配
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
log "✅ Procd 网卡硬件加速服务（vendor 白名单版）注入完成"

# ==============================================================================
# 阶段 3 & 4: 磁盘运行时优化 & LuCI 配置同步（终极排错版）
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

# 日志函数
log_opt() {
    local msg="$1"
    logger -t "Disk-Opt" "$msg"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $msg" >> "$OPT_LOG_FILE"
    [ "$DEBUG_OPT" = "1" ] && echo "[DEBUG] $msg" >&2
}

# 扩展支持常见的外置文件系统
FSTYPE=$(awk -v mp="$MOUNTPOINT" '$2==mp {print $3}' /proc/mounts)

case "$FSTYPE" in
    ext4|btrfs|xfs|f2fs|zfs|ntfs|ntfs3|exfat|vfat)
        # 【修复1：精准提取块设备名，完美兼容 NVMe (nvme0n1p1) 与 eMMC (mmcblk0p1)】
        DEV_RAW="${DEVICE##*/}"
        case "$DEV_RAW" in
            nvme*p*|mmcblk*p*) DEV_BASE=$(echo "$DEV_RAW" | sed -E 's/p[0-9]+$//') ;;
            *) DEV_BASE=$(echo "$DEV_RAW" | sed -E 's/[0-9]+$//') ;;
        esac

        # 判断是否为可移动设备（USB）
        REMOVABLE=0
        [ -n "$DEV_BASE" ] && [ -f "/sys/block/$DEV_BASE/removable" ] && REMOVABLE=$(cat "/sys/block/$DEV_BASE/removable")
        
        # 获取 rotational 值（0=SSD,1=HDD）
        rotational=1
        [ -n "$DEV_BASE" ] && [ -f "/sys/block/$DEV_BASE/queue/rotational" ] && rotational=$(cat "/sys/block/$DEV_BASE/queue/rotational")

        # ---------- 1. 智能预读缓存（支持环境变量）----------
        if [ -n "$DEV_BASE" ] && [ -f "/sys/block/$DEV_BASE/queue/read_ahead_kb" ]; then
            if [ "$REMOVABLE" = "1" ]; then
                # USB 设备：降低预读，提升响应
                echo 128 > "/sys/block/$DEV_BASE/queue/read_ahead_kb" 2>/dev/null && log_opt "USB $DEV_BASE 预读缓存设为 128KB"
            elif [ "$rotational" = "0" ]; then
                echo "$SSD_READ_AHEAD_KB" > "/sys/block/$DEV_BASE/queue/read_ahead_kb" 2>/dev/null && log_opt "SSD $DEV_BASE 预读缓存设为 ${SSD_READ_AHEAD_KB}KB"
            else
                echo "$HDD_READ_AHEAD_KB" > "/sys/block/$DEV_BASE/queue/read_ahead_kb" 2>/dev/null && log_opt "HDD $DEV_BASE 预读缓存设为 ${HDD_READ_AHEAD_KB}KB"
            fi
        fi

        # ---------- 2. I/O 调度器优化 ----------
        set_scheduler() {
            local dev="$1"
            local sched1="$2"
            local sched2="$3"
            if echo "$sched1" > "/sys/block/$dev/queue/scheduler" 2>/dev/null; then
                log_opt "调度器 $dev 设为 $sched1"
            elif echo "$sched2" > "/sys/block/$dev/queue/scheduler" 2>/dev/null; then
                log_opt "调度器 $dev 设为 $sched2"
            fi
        }

        if [ -n "$DEV_BASE" ] && [ -f "/sys/block/$DEV_BASE/queue/scheduler" ]; then
            if [ "$REMOVABLE" = "1" ] || [ "$rotational" = "0" ]; then
                # USB 或 SSD: 使用 none 或 noop
                set_scheduler "$DEV_BASE" "none" "noop"
            else
                # HDD: 使用 mq-deadline 或 bfq
                set_scheduler "$DEV_BASE" "mq-deadline" "bfq"
            fi
        fi

        # ---------- 3. 挂载选项动态优化（破除报错陷阱）----------
        # 获取当前挂载选项
        current_opts=$(awk -v mp="$MOUNTPOINT" '$2==mp {print $4}' /proc/mounts)
        
        # 移除已有的 noatime/nodiratime/relatime 等时间相关选项，避免重复
        new_opts=$(echo "$current_opts" | sed -E 's/\b(noatime|nodiratime|relatime|strictatime|lazyatime|sync)\b,?//g; s/,$//; s/,,+/,/g')
        
        # 构建优化基础选项
        base_opts="noatime,nodiratime"
        
        # 【核心修复】：Ext4 专属参数必须被严格限制，否则 Btrfs/NTFS 会报错并拒绝挂载！
        if [ "$FSTYPE" = "ext4" ]; then
            if [ "$rotational" = "0" ]; then
                base_opts="${base_opts},data=ordered"
                [ "$ENABLE_DISCARD" = "1" ] && ! echo "$new_opts" | grep -q '\bdiscard\b' && base_opts="${base_opts},discard"
            else
                base_opts="${base_opts},data=ordered,commit=30"
            fi
        elif [ "$rotational" = "0" ] && [ "$ENABLE_DISCARD" = "1" ]; then
            # 其他支持 discard 的文件系统 (btrfs, xfs) 仅追加 discard
            if [ "$FSTYPE" = "btrfs" ] || [ "$FSTYPE" = "xfs" ] || [ "$FSTYPE" = "f2fs" ]; then
                ! echo "$new_opts" | grep -q '\bdiscard\b' && base_opts="${base_opts},discard"
            fi
        fi
        
        # 合并并去除可能的重复逗号
        final_opts="${base_opts},${new_opts}"
        final_opts=$(echo "$final_opts" | sed 's/^,//; s/,,*/,/g; s/,$//')
        
        if mountpoint -q "$MOUNTPOINT" && [ -w "$MOUNTPOINT" ]; then
            if mount -o remount,"$final_opts" "$MOUNTPOINT" 2>/dev/null; then
                log_opt "已优化 $MOUNTPOINT 挂载选项: $final_opts ($FSTYPE)"
            else
                log_opt "⚠ 无法修改 $MOUNTPOINT 挂载选项 (可能是文件系统不支持某些参数)"
            fi
        fi

        # ---------- 4. LuCI 配置反向修复（破除空值陷阱）----------
        if command -v uci >/dev/null 2>&1 && command -v block >/dev/null 2>&1; then
            # 同时兼容 UUID 和 DEVICE 的匹配方式
            UUID=$(block info "$DEVICE" | grep -o 'UUID="[^"]*"' | cut -d'"' -f2 | head -n1)
            SEC=""
            [ -n "$UUID" ] && SEC=$(uci -q show fstab | grep "uuid='$UUID'" | cut -d'.' -f2 | head -n1)
            [ -z "$SEC" ] && SEC=$(uci -q show fstab | grep "device='$DEVICE'" | cut -d'.' -f2 | head -n1)

            if [ -n "$SEC" ]; then
                OPTS=$(uci -q get fstab."$SEC".options || echo "")
                
                # 【核心修复】：不管它是空值、defaults 还是 relatime，只要没有 noatime，就强行塞进去！
                if ! echo "$OPTS" | grep -q "noatime"; then
                    NEW_OPTS=$(echo "$OPTS" | sed -E 's/\b(relatime|strictatime|sync)\b,?//g')
                    [ -z "$NEW_OPTS" ] || [ "$NEW_OPTS" = "defaults" ] && NEW_OPTS=""
                    
                    FINAL_UCI_OPTS="noatime,nodiratime,${NEW_OPTS}"
                    FINAL_UCI_OPTS=$(echo "$FINAL_UCI_OPTS" | sed 's/^,//; s/,,*/,/g; s/,$//')
                    
                    uci set fstab."$SEC".options="$FINAL_UCI_OPTS"
                    uci commit fstab
                    log_opt "已暴改 LuCI 生成的挂载参数: -> $FINAL_UCI_OPTS"
                fi
            fi
        fi
        ;;
esac
EOF

chmod 0755 "${FILES_DIR}/etc/hotplug.d/mount/99-optimize-disk"
log "✅ 磁盘优化与 LuCI 反向劫持（终极修障版）注入完成"

# ==============================================================================
# 阶段 5: SSD 定时 TRIM（扩展支持 ext4/btrfs/xfs/f2fs/zfs）
# ==============================================================================
CRON_FILE="${FILES_DIR}/etc/crontabs/root"
mkdir -p "$(dirname "$CRON_FILE")"

CRON_LINE="${TRIM_SCHEDULE} command -v fstrim >/dev/null && for fs in ext4 btrfs xfs f2fs zfs; do for mp in \$(awk -v fs=\"\$fs\" '\$3==fs {print \$2}' /proc/mounts); do fstrim \"\$mp\" 2>/dev/null; done; done"

if [ -f "$CRON_FILE" ]; then
    if ! grep -Fxq "$CRON_LINE" "$CRON_FILE"; then
        echo "$CRON_LINE" >> "$CRON_FILE"
    fi
else
    echo "$CRON_LINE" > "$CRON_FILE"
fi
log "✅ fstrim cron 任务配置完成"

log "🎉 DIY Part 2 脚本执行完成"
