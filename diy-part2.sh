#!/usr/bin/env bash
# ==============================================================================
# OpenWrt DIY Part 2 - 企业级生产环境版 v4.7 中文注释完整版
# 设计目标：
# - 修复 Subshell 陷阱，确保 uci commit 100% 生效
# - 增强路径兼容性，使用 Here-document 完美支持带空格的挂载点
# - 非破坏性选项更新，保留用户自定义参数 (如 discard, compress, nosuid)
# - 零侵入式设计，Snapshot / 22 / 23 / 24 源码绝对兼容
# - 针对固件编译静态注入，符合 OpenWrt 启动时序规范，无需初始化重启
# - 修复 TRIM Cron 第一次开机不生效问题
# - 修复挂载选项清洗逻辑误杀 rw 问题
# ==============================================================================

set -euo pipefail

# --------------------------------------------------------------------------
# 全局配置 & CI 环境变量
# --------------------------------------------------------------------------
readonly TARGET_IP="192.168.5.1"
readonly TARGET_HOSTNAME="LEDE"
readonly FILES_DIR="files"

# 默认参数（支持从外部 CI 环境变量覆盖）
: "${TRIM_SCHEDULE:="0 3 * * *"}"
: "${SSD_READ_AHEAD_KB:="2048"}"
: "${HDD_READ_AHEAD_KB:="128"}"

# CI 错误捕捉：在构建日志中精确定位报错行号
trap 'echo "::error file=${BASH_SOURCE[0]},line=${LINENO}::❌ 构建失败，请检查脚本逻辑"; exit 1' ERR

log_i() { echo -e "\033[36m[INFO]\033[0m $1"; }

# 预检：必须在 OpenWrt 源码根目录执行
[[ -f scripts/feeds ]] || { echo "❌ 错误: 必须在 OpenWrt 源码根目录执行此脚本"; exit 1; }

# 创建标准的目录结构 (files 目录将被编译进 ROM)
mkdir -p "${FILES_DIR}/etc/"{uci-defaults,init.d,hotplug.d/block,hotplug.d/mount,config}
mkdir -p "${FILES_DIR}/usr/bin"

# ==============================================================================
# 阶段 1: 系统初始化 (静态配置注入)
# ==============================================================================
cat <<EOF > "${FILES_DIR}/etc/uci-defaults/90-system-init"
#!/bin/sh

# 设置默认 IP 和主机名
uci set network.lan.ipaddr='${TARGET_IP}'
uci set system.@system[0].hostname='${TARGET_HOSTNAME}'

uci commit network
uci commit system

# Samba4 自动修复逻辑 (确保配置纯净且支持中文)
if command -v uci >/dev/null 2>&1; then
    touch /etc/config/samba4
    if ! uci -q get samba4.@samba[0] >/dev/null; then
        uci add samba4 samba
        uci set samba4.@samba[-1].workgroup='WORKGROUP'
        uci set samba4.@samba[-1].charset='UTF-8'
        uci set samba4.@samba[-1].interface='lan'
    fi
    # 彻底清除默认的模版共享盘，防止垃圾挂载点残留
    while uci -q delete samba4.@sambashare[0]; do :; done
    uci commit samba4
fi

exit 0
EOF
chmod 0755 "${FILES_DIR}/etc/uci-defaults/90-system-init"
log_i "✅ 阶段 1: 系统初始化注入完成"

# ==============================================================================
# 阶段 2: IPSec VPN 双将夺权终极物理隔离 (Build-time Override)
# ==============================================================================
log_i "🔥 正在注入 IPSec 物理空壳，彻底拦截原生服务抢权..."

# 在编译期直接伪造一个空壳启动脚本，强行覆盖掉 StrongSwan 原生的 /etc/init.d/ipsec
cat << 'EOF' > "${FILES_DIR}/etc/init.d/ipsec"
#!/bin/sh /etc/rc.common
# =======================================================
# [企业级架构防冲突]: 彻底拦截原生 StrongSwan 的自启
# 让路给 luci-app-ipsec-vpnd 特派员，防止双将夺权！
# =======================================================
START=99

start() {
    # 物理级静默，不执行任何操作
    exit 0
}
stop() {
    exit 0
}
EOF
chmod 0755 "${FILES_DIR}/etc/init.d/ipsec"

log_i "✅ 阶段 2: IPSec 空壳注入完成，出厂即免冲突状态"

# ==============================================================================
# 阶段 3: 网卡硬件加速服务 (ethtool 策略)
# ==============================================================================
cat <<'EOF' > "${FILES_DIR}/etc/init.d/network-accel"
#!/bin/sh /etc/rc.common

START=85

start() {
    command -v ethtool >/dev/null || return

    # 遍历所有网络接口并开启硬件加速
    for i in /sys/class/net/*; do
        [ -e "$i" ] || continue
        iface=$(basename "$i")
        case "$iface" in
            lo|br-*|docker*|veth*|eth1.4*)
                continue
            ;;
        esac
        # 开启 TSO/GSO 加速，忽略不支持的报错
        ethtool -K "$iface" tso on 2>/dev/null || true
        ethtool -K "$iface" gso on 2>/dev/null || true
    done
}
EOF
chmod 0755 "${FILES_DIR}/etc/init.d/network-accel"
log_i "✅ 阶段 3: 网卡硬件加速注入完成"

# ==============================================================================
# 阶段 4: Block IO 物理层优化 (NVMe/SSD/HDD 自动适配)
# ==============================================================================
cat <<'EOF' > "${FILES_DIR}/etc/hotplug.d/block/93-optimize-io"
#!/bin/sh
SSD_RA=2048
HDD_RA=128

[ "$ACTION" = "add" ] || exit 0
[ -z "$DEVNAME" ] && exit 0

# 提取主设备名逻辑 (兼容 NVMe, mmcblk, sdX)
case "$DEVNAME" in
    nvme*)   dev="${DEVNAME%p*}" ;;
    mmcblk*) dev="${DEVNAME%p*}" ;;
    sd*)     dev="${DEVNAME%%[0-9]*}" ;;
    *)       dev="$DEVNAME" ;;
esac

BASE="/sys/block/$dev"
[ -d "$BASE" ] && [ -f "$BASE/queue/read_ahead_kb" ] || exit 0

# 根据旋转介质判断存储类型，设置预读缓存
ROT=$(cat "$BASE/queue/rotational" 2>/dev/null || echo 1)
[ "$ROT" = "0" ] && echo "$SSD_RA" > "$BASE/queue/read_ahead_kb" || echo "$HDD_RA" > "$BASE/queue/read_ahead_kb"
EOF
# 在构建时将变量同步进脚本
sed -i "s/SSD_RA=.*/SSD_RA=${SSD_READ_AHEAD_KB}/" "${FILES_DIR}/etc/hotplug.d/block/93-optimize-io"
sed -i "s/HDD_RA=.*/HDD_RA=${HDD_READ_AHEAD_KB}/" "${FILES_DIR}/etc/hotplug.d/block/93-optimize-io"
chmod 0755 "${FILES_DIR}/etc/hotplug.d/block/93-optimize-io"
log_i "✅ 阶段 4: Block IO 优化注入完成"

# ==============================================================================
# 阶段 5: TRIM 引擎及静态 Cron 注入 (首次开机立即生效)
# ==============================================================================
cat <<'EOF' > "${FILES_DIR}/usr/bin/auto-fstrim"
#!/bin/sh
command -v fstrim >/dev/null || exit 0
awk '$1 ~ /^\/dev\// && $3 ~ /^(ext4|btrfs|xfs|f2fs)$/ {print $2}' /proc/mounts | while read -r mp; do
    [ -d "$mp" ] && fstrim "$mp" 2>/dev/null
done
EOF
chmod 0755 "${FILES_DIR}/usr/bin/auto-fstrim"

cat <<EOF > "${FILES_DIR}/etc/uci-defaults/99-zz-cron-trim"
#!/bin/sh
mkdir -p /etc/crontabs
touch /etc/crontabs/root

# 清理旧 TRIM 任务，避免重复
sed -i '/auto-fstrim/d' /etc/crontabs/root 2>/dev/null || true
echo "${TRIM_SCHEDULE} /usr/bin/auto-fstrim" >> /etc/crontabs/root

# ⭐ 修复盲点：立即重启 Cron，确保第一次开机就能生效
/etc/init.d/cron restart || true

exit 0
EOF
chmod 0755 "${FILES_DIR}/etc/uci-defaults/99-zz-cron-trim"
log_i "✅ 阶段 5: TRIM Cron 注入完成并立即生效"

# ==============================================================================
# 阶段 6: 挂载策略引擎 (处理空格路径 + 保留用户自定义选项)
# ==============================================================================
cat <<'EOF' > "${FILES_DIR}/etc/init.d/mount-policy-engine"
#!/bin/sh /etc/rc.common

START=93

start() {
    [ -x /sbin/uci ] || return

    # 获取挂载点数据 (处理空格)
    MOUNT_DATA=$(awk '$1 ~ /^\/dev\// && $3 ~ /^(ext4|btrfs|xfs|f2fs|vfat|exfat|ntfs|fuseblk)$/ {print $2}' /proc/mounts)

    # 使用 Here-document 确保 while 循环在当前 Shell 进程运行，使 uci commit 生效
    while read -r mp; do
        [ -z "$mp" ] && continue
        case "$mp" in /|/rom|/overlay|/boot) continue ;; esac

        DEV=$(awk -v mp="$mp" '$2==mp {print $1}' /proc/mounts)
        [ -n "$DEV" ] || continue

        # 1. 物理层即时重挂载策略
        mount -o remount,rw,noatime "$mp" 2>/dev/null || true

        # 2. UCI 配置持久化逻辑 (非破坏性更新)
        # 清洗冲突项，保留用户自定义参数（如 discard, compress, nosuid）
        SEC=$(uci -q show fstab | grep -E "device=['\"]$DEV['\"]" | cut -d'.' -f2 | head -n1)
        if [ -z "$SEC" ]; then
            UUID=$(block info "$DEV" 2>/dev/null | grep -o 'UUID="[^"]*"' | cut -d'"' -f2)
            [ -n "$UUID" ] && SEC=$(uci -q show fstab | grep -E "uuid=['\"]$UUID['\"]" | cut -d'.' -f2 | head -n1)
        fi
        
        if [ -n "$SEC" ]; then
            RAW_OPTS=$(uci -q get fstab."$SEC".options || echo "defaults")
            # ⭐ 修复盲点：防止 rw 被误杀
            CLEANED=$(echo ",$RAW_OPTS," | sed -E 's/,(rw|ro|relatime|noatime|defaults),/,/g; s/,,+/,/g; s/^,//; s/,$//')
            FINAL_OPTS="rw,noatime${CLEANED:+,$CLEANED}"
            uci set fstab."$SEC".options="$FINAL_OPTS"
        fi
    done <<EOT
$MOUNT_DATA
EOT

    # 提交修改，确保重启后依然生效
    uci commit fstab
}
EOF
chmod 0755 "${FILES_DIR}/etc/init.d/mount-policy-engine"

# fstab 全局清理脚本
cat <<'EOF' > "${FILES_DIR}/etc/uci-defaults/96-fstab-clean"
#!/bin/sh
# ⭐ 全局清洗 fstab，避免残留旧节点
while uci -q delete fstab.@global[0]; do :; done
uci add fstab global
uci set fstab.@global[-1].anon_swap='0'
uci set fstab.@global[-1].anon_mount='1'
uci set fstab.@global[-1].auto_swap='1'
uci set fstab.@global[-1].auto_mount='1'
uci set fstab.@global[-1].delay_root='5'
uci set fstab.@global[-1].check_fs='0'
uci commit fstab
exit 0
EOF
chmod 0755 "${FILES_DIR}/etc/uci-defaults/96-fstab-clean"
log_i "✅ 阶段 6: 挂载策略引擎及 fstab 清洗注入完成"

# ==============================================================================
# 阶段 7: Hotplug 挂载策略钩子 (动态同步)
# ==============================================================================
cat <<'EOF' > "${FILES_DIR}/etc/hotplug.d/mount/95-policy-hotplug"
#!/bin/sh
# 仅在磁盘成功插入且挂载后触发策略应用
[ "$ACTION" = "add" ] || exit 0
[ -x /etc/init.d/mount-policy-engine ] || exit 0

/etc/init.d/mount-policy-engine start
EOF
chmod 0755 "${FILES_DIR}/etc/hotplug.d/mount/95-policy-hotplug"
log_i "✅ 阶段 7: Hotplug 挂载钩子注入完成"

log_i "🎉 Part 2 编译脚本完整版构建已就绪！"
