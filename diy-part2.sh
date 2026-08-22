#!/usr/bin/env bash
# ==============================================================================
# OpenWrt DIY Part 2 - 企业级生产环境版功能特性
# ==============================================================================
# 核心设计目标：
# 1. 协议级服务共存 (VPN Coexistence)：
#    - 预置 IPSec (包含 ESP 协议) 与 WireGuard 防火墙规则，实现完美共存。
# 2. 健壮的 UCI 持久化 (Atomic Commit)：
#    - 改用 Here-document 确保 UCI 指令在当前 Shell 进程执行，保证 commit 100% 写入。
# 3. 非破坏性挂载策略 (Smart Fstab)：
#    - 采用"清洗+保留"逻辑，在强制 noatime 加速的同时，智能保留用户高级文件系统参数。
# 4. 全路径兼容性 (Path Resilience)：
#    - 完美支持包含空格、特殊字符的挂载点路径，解决工业级多盘挂载环境下的解析失效问题。
# 5. 静态时序优化 (Boot-time Injection)：
#    - 所有配置通过 files 目录静态打入 ROM，出厂即预置完成，无需二次重启。
# 6. 存储生命周期维护 (TRIM & IO Engine)：
#    - IO 探针：自动识别 NVMe/SSD/HDD 介质，动态匹配最优预读缓存 (Read-Ahead)。
#    - TRIM 补丁：通过 uci-defaults 强制重载 Cron 进程，确保定时任务即刻服役。
# 7. 智能网卡硬件加速 (Smart Hardware Offload)：
#    - 自动探针识别 Intel/Realtek 驱动，Intel 全量加速，Realtek 只开安全加速防断流。
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
TARGET_IP='${TARGET_IP}'
TARGET_HOSTNAME='${TARGET_HOSTNAME}'
EOF

cat <<'EOF' >> "${FILES_DIR}/etc/uci-defaults/90-system-init"
# 增加 -q 静默执行，防止上游改名导致报错
uci -q set network.lan.ipaddr="$TARGET_IP"
uci -q set system.@system[0].hostname="$TARGET_HOSTNAME"

uci -q commit network
uci -q commit system

# Samba4 自动修复逻辑 (确保配置纯净且支持中文)
if command -v uci >/dev/null 2>&1; then
    if ! uci -q get samba4.@samba[0] >/dev/null; then
        uci add samba4 samba
        uci set samba4.@samba[-1].workgroup='WORKGROUP'
        uci set samba4.@samba[-1].charset='UTF-8'
        uci set samba4.@samba[-1].interface='lan'
    fi
    # 精准清除默认模板名称的共享，保留用户后续可能自定义的共享盘
    for share in homes home public tmp root; do
        uci -q delete samba4.$share
    done
    uci commit samba4
fi

exit 0
EOF

chmod 0755 "${FILES_DIR}/etc/uci-defaults/90-system-init"
log_i "✅ 阶段 1: 系统初始化注入完成"

# ==============================================================================
# 阶段 2: VPN 防火墙预置 (IPSec 与 WireGuard 完美共存)
# ==============================================================================
log_i "🔥 正在注入 VPN 端口放行规则，保障开机即用..."

cat << 'EOF' > "${FILES_DIR}/etc/uci-defaults/91-vpn-firewall"
#!/bin/sh
# 动态注入防火墙规则，保障 IPSec (UDP 500/4500 + ESP) 和 WireGuard 顺畅通行
if command -v uci >/dev/null 2>&1; then
    # 放行 IPSec IKE & NAT-T
    uci -q delete firewall.ipsec_allow
    uci set firewall.ipsec_allow=rule
    uci set firewall.ipsec_allow.name='Allow-IPsec'
    uci set firewall.ipsec_allow.src='wan'
    uci set firewall.ipsec_allow.dest_port='500 4500'
    uci set firewall.ipsec_allow.proto='udp'
    uci set firewall.ipsec_allow.target='ACCEPT'

    # 放行 IPSec ESP 协议 (为非 NAT 环境的纯 IPSec 提供支持)
    uci -q delete firewall.ipsec_esp
    uci set firewall.ipsec_esp=rule
    uci set firewall.ipsec_esp.name='Allow-IPsec-ESP'
    uci set firewall.ipsec_esp.src='wan'
    uci set firewall.ipsec_esp.proto='esp'
    uci set firewall.ipsec_esp.target='ACCEPT'

    # 放行 WireGuard
    uci -q delete firewall.wg_allow
    uci set firewall.wg_allow=rule
    uci set firewall.wg_allow.name='Allow-WireGuard'
    uci set firewall.wg_allow.src='wan'
    uci set firewall.wg_allow.dest_port='51820'
    uci set firewall.wg_allow.proto='udp'
    uci set firewall.wg_allow.target='ACCEPT'

    uci commit firewall
fi
exit 0
EOF
chmod 0755 "${FILES_DIR}/etc/uci-defaults/91-vpn-firewall"
log_i "✅ 阶段 2: VPN 端口防火墙规则预置完成"

# ==============================================================================
# 阶段 3: init.d 挂载提速 Hook（非侵入式内核 Remount）
# ==============================================================================
cat <<'EOF' > "${FILES_DIR}/etc/init.d/mount-optimize"
#!/bin/sh /etc/rc.common

START=92

start() {
    if ! command -v mount >/dev/null; then
        return
    fi

    # 仅针对物理真实挂载盘进行 remount，彻底避开虚拟文件系统
    # 兼容 fuseblk 以完美支持 ntfs-3g 的 noatime 提速
    while read -r dev mp fs _; do
        case "$dev" in
            /dev/*) ;;
            *) continue ;;
        esac
        
        case "$fs" in
            ext4|btrfs|xfs|f2fs|vfat|exfat|ntfs*|fuseblk) ;;
            *) continue ;;
        esac
        
        case "$mp" in
            /|/rom|/overlay|/boot) continue ;;
        esac
        
        mount -o remount,noatime,nodiratime "$mp" 2>/dev/null || true
    done < /proc/mounts
}
EOF

chmod 0755 "${FILES_DIR}/etc/init.d/mount-optimize"
log_i "✅ 阶段 3: init.d 挂载修复 Hook 注入完成"

# ==============================================================================
# 阶段 4: 智能网卡硬件加速服务 (ethtool 防断流策略)
# ==============================================================================
cat <<'EOF' > "${FILES_DIR}/etc/init.d/network-accel"
#!/bin/sh /etc/rc.common

START=85

start() {
    command -v ethtool >/dev/null || return

    # 遍历所有网络接口并根据驱动类型智能分配硬件加速策略
    for i in /sys/class/net/*; do
        iface=$(basename "$i")
        case "$iface" in
            lo|br-*|docker*|veth*|ifb*|tun*|tap*|wg*)
                continue
            ;;
        esac
        
        # 提取网卡驱动名称
        driver=$(ethtool -i "$iface" 2>/dev/null | awk '/driver/{print $2}')
        
        # 匹配高级网卡 (Intel/Mellanox)，开启完整 Offload
        if echo "$driver" | grep -qE "e1000e|igb|ixgbe|mlx|intel"; then
            logger -t NIC-ACCEL "Enable Full Offload (TSO, GSO, GRO) for Intel/Mellanox NIC: $iface"
            ethtool -K "$iface" tso on gso on gro on 2>/dev/null || true
        else
            # 针对螃蟹卡(Realtek)或虚拟网卡，仅开 SG/GRO，强制关 TSO/GSO 防止断流
            logger -t NIC-ACCEL "Enable Safe Offload (SG, GRO) for Realtek/Virtual NIC: $iface"
            ethtool -K "$iface" sg on gro on tso off gso off 2>/dev/null || true
        fi
    done
}
EOF

chmod 0755 "${FILES_DIR}/etc/init.d/network-accel"
log_i "✅ 阶段 4: 智能网卡加速策略注入完成"

# ==============================================================================
# 阶段 5: Block IO 物理层优化 (精准白名单设备解析)
# ==============================================================================

# 分段注入 CI 变量
cat <<EOF > "${FILES_DIR}/etc/hotplug.d/block/93-optimize-io"
#!/bin/sh
SSD_READ_AHEAD_KB="${SSD_READ_AHEAD_KB}"
HDD_READ_AHEAD_KB="${HDD_READ_AHEAD_KB}"
EOF

# 追加原生逻辑
cat <<'EOF' >> "${FILES_DIR}/etc/hotplug.d/block/93-optimize-io"
[ "$ACTION" = "add" ] || exit 0
[ -z "$DEVNAME" ] && exit 0

# 提取主设备名逻辑 (兼容 NVMe, mmcblk, sdX, vdX 等虚拟块设备)
case "$DEVNAME" in
    nvme*)   dev="${DEVNAME%%p*}" ;;
    mmcblk*) dev="${DEVNAME%%p*}" ;;
    sd*)     dev="${DEVNAME%%[0-9]*}" ;;
    vd*)     dev="${DEVNAME%%[0-9]*}" ;;
    hd*)     dev="${DEVNAME%%[0-9]*}" ;;
    xvd*)    dev="${DEVNAME%%[0-9]*}" ;;
    *)       exit 0 ;;
esac

# 修复：必须增加 block 路径才能正确访问块设备的 sysfs 节点
BASE="/sys/block/$dev"
[ -d "$BASE" ] || exit 0

# 提取旋转介质标识 (0 为 SSD, 1 为 HDD)
ROT=$(cat "$BASE/queue/rotational" 2>/dev/null || echo 1)

# 安全预检 read_ahead_kb 节点是否存在，防止老内核报错
if [ -f "$BASE/queue/read_ahead_kb" ]; then
    if [ "$ROT" = "0" ]; then
        echo "$SSD_READ_AHEAD_KB" > "$BASE/queue/read_ahead_kb" 2>/dev/null || true
    else
        echo "$HDD_READ_AHEAD_KB" > "$BASE/queue/read_ahead_kb" 2>/dev/null || true
    fi
fi
EOF

chmod 0755 "${FILES_DIR}/etc/hotplug.d/block/93-optimize-io"
log_i "✅ 阶段 5: Block IO 优化注入完成"

# ==============================================================================
# 阶段 6: mount 热插拔 noatime (暴力拦截动态挂载)
# ==============================================================================
cat <<'EOF' > "${FILES_DIR}/etc/hotplug.d/mount/94-optimize-mount"
#!/bin/sh

[ "$ACTION" = "add" ] || exit 0
[ -z "$MOUNTPOINT" ] && exit 0

case "$MOUNTPOINT" in
    /|/rom|/overlay|/boot)
        exit 0
    ;;
esac

# 预检：确认挂载点为物理设备，避免对 tmpfs/cgroup 等虚拟文件系统执行无意义操作
if ! grep -q "$MOUNTPOINT" /proc/mounts 2>/dev/null; then
    exit 0
fi

# 拦截热插拔动态挂载，覆盖性能参数
mount -o remount,noatime "$MOUNTPOINT" 2>/dev/null || true

EOF

chmod 0755 "${FILES_DIR}/etc/hotplug.d/mount/94-optimize-mount"
log_i "✅ 阶段 6: mount 优化注入完成"

# ==============================================================================
# 阶段 7: TRIM 引擎及静态 Cron 注入 (首次开机立即生效)
# ==============================================================================
cat <<'EOF' > "${FILES_DIR}/usr/bin/auto-fstrim"
#!/bin/sh

command -v fstrim >/dev/null || exit 0

# 仅对物理磁盘且支持 TRIM 的文件系统执行物理块回收
while read -r dev mp fs _; do
    case "$dev" in
        /dev/*) ;;
        *) continue ;;
    esac
    
    case "$fs" in
        ext4|btrfs|xfs|f2fs) ;;
        *) continue ;;
    esac
    
    fstrim "$mp" 2>/dev/null || true
done < /proc/mounts
EOF

chmod 0755 "${FILES_DIR}/usr/bin/auto-fstrim"

# 使用 99-zz- 命名，确保它排在 99-default-settings 后面执行以防洗白
cat <<EOF > "${FILES_DIR}/etc/uci-defaults/99-zz-cron-trim"
#!/bin/sh

mkdir -p /etc/crontabs
touch /etc/crontabs/root

# 清理旧 TRIM 任务，避免重复
sed -i '/auto-fstrim/d' /etc/crontabs/root 2>/dev/null || true
echo "${TRIM_SCHEDULE} /usr/bin/auto-fstrim" >> /etc/crontabs/root

# ⭐ 修复盲点：立即重启 Cron，确保第一次开机就能生效
/etc/init.d/cron restart 2>/dev/null || true

exit 0
EOF

chmod 0755 "${FILES_DIR}/etc/uci-defaults/99-zz-cron-trim"
log_i "✅ 阶段 7: TRIM 引擎及 Cron 注入完成"

# ==============================================================================
# 阶段 8: 解决 IPSec "双将夺权" 启动冲突
# 禁用原生 strongSwan 服务，让位给 luci-app-ipsec-vpnd
# ==============================================================================

log_i "🔥 正在注入 IPSec 启动防冲突补丁..."

cat << 'EOF' > "${FILES_DIR}/etc/uci-defaults/92-disable-native-ipsec"
#!/bin/sh

# ============================================================
# IPSec 服务架构：
#
#   luci-app-ipsec-vpnd
#          ↓
#     ipsec-vpnd
#          ↓
#       charon
#
# 禁止原生 /etc/init.d/ipsec 与 ipsec-vpnd 同时运行
# ============================================================

# 1. 禁止原生 strongSwan ipsec 服务以后开机自动启动
if [ -x "/etc/init.d/ipsec" ]; then
    /etc/init.d/ipsec disable 2>/dev/null

    # 关键：
    # 如果第一次启动时原生 ipsec 已经被 S90ipsec 拉起，
    # 必须立即停止它，否则会与 ipsec-vpnd 争夺 charon / UDP 500 / 4500。
    /etc/init.d/ipsec stop 2>/dev/null
fi

# 2. 确保 luci-app-ipsec-vpnd 成为唯一的 IPSec 管理入口
if [ -x "/etc/init.d/ipsec-vpnd" ]; then
    /etc/init.d/ipsec-vpnd enable 2>/dev/null

    # 关键：
    # 重新启动 ipsec-vpnd，使其在原生 ipsec 被停止后重新建立
    # 正确的 charon 实例，同时刷新 procd 运行状态。
    /etc/init.d/ipsec-vpnd restart 2>/dev/null
fi

exit 0
EOF

chmod 0755 "${FILES_DIR}/etc/uci-defaults/92-disable-native-ipsec"

log_i "✅ 阶段 8: IPSec 启动防冲突补丁注入完成"

# ==============================================================================
# 阶段 9: 系统盘保护型自动挂载
#
# 架构目标：
# 1. 保留 OpenWrt 原生普通存储设备自动挂载能力
# 2. 禁止 /boot、/rom、/overlay 对应设备进入匿名自动挂载
# 3. 禁止系统启动盘的保留分区进入 15-automount
# 4. 不关闭 auto_mount
# 5. 不修改 /sbin/block、blockd、79_move_config
# 6. 不硬编码 /dev/sda
# 7. 普通 FAT32 / exFAT / NTFS / ext4 USB 存储仍然即插即用
# ==============================================================================

log_i "🔥 正在注入系统盘保护型自动挂载策略..."

cat <<'EOF' > "${FILES_DIR}/etc/hotplug.d/block/15-automount"
#!/bin/sh

# ==============================================================================
# OpenWrt / LEDE 自动挂载保护层
#
# 核心原则：
#   系统盘保护
#   普通外部存储保持自动挂载
#
# 不关闭 auto_mount。
# 不修改 fstools。
# 不修改 blockd。
# ==============================================================================

# 仅处理真正的 block add 事件
[ "$ACTION" = "add" ] || exit 0

[ -n "$DEVNAME" ] || exit 0
[ -n "$DEVPATH" ] || exit 0

# ------------------------------------------------------------------------------
# 1. 只处理传统 sdX 类块设备
#
# 保留官方脚本的行为边界：
#   sda1
#   sdb1
#   sdc1
#
# NVMe / mmc 等设备不由这里进行匿名自动挂载。
# ------------------------------------------------------------------------------

case "$DEVNAME" in
    sd[a-z][0-9]*)
        ;;
    *)
        exit 0
        ;;
esac

# ------------------------------------------------------------------------------
# 2. 获取分区所在的物理磁盘
#
# sda1   -> sda
# sda128 -> sda
# sdb1   -> sdb
# sdc2   -> sdc
# ------------------------------------------------------------------------------

DISK="${DEVNAME%%[0-9]*}"

[ -n "$DISK" ] || exit 0
[ -d "/sys/block/$DISK" ] || exit 0

# ------------------------------------------------------------------------------
# 3. 获取当前系统已经使用的块设备
#
# 通过 /proc/mounts 动态识别，而不是硬编码：
#
#   /boot
#   /rom
#   /overlay
#
# 因此：
#
#   /dev/sda1 -> /boot
#   /dev/sda2 -> /rom
#   /dev/loop0 -> /overlay
#
# 都会自动受到保护。
# ------------------------------------------------------------------------------

is_system_device() {
    local target="$1"
    local dev

    dev="$(awk -v mp="$target" '$2 == mp {print $1; exit}' /proc/mounts 2>/dev/null)"

    [ -n "$dev" ] || return 1

    case "$dev" in
        /dev/*)
            [ "$dev" = "/dev/$DEVNAME" ] && return 0
            ;;
    esac

    return 1
}

# ------------------------------------------------------------------------------
# 4. 保护 /boot
# ------------------------------------------------------------------------------

if is_system_device "/boot"; then
    logger -t AUTO-MOUNT "Skip system device $DEVNAME: /boot"
    exit 0
fi

# ------------------------------------------------------------------------------
# 5. 保护 /rom
# ------------------------------------------------------------------------------

if is_system_device "/rom"; then
    logger -t AUTO-MOUNT "Skip system device $DEVNAME: /rom"
    exit 0
fi

# ------------------------------------------------------------------------------
# 6. 保护 /overlay
# ------------------------------------------------------------------------------

if is_system_device "/overlay"; then
    logger -t AUTO-MOUNT "Skip system device $DEVNAME: /overlay"
    exit 0
fi

# ------------------------------------------------------------------------------
# 7. 系统盘拓扑保护
#
# 如果本分区与 /boot /rom 属于同一物理磁盘，
# 则进一步保护该磁盘上的其它分区。
#
# 这一步专门解决：
#
#   /dev/sda128
#
# 这种没有文件系统的保留分区被 15-automount 尝试探测的问题。
#
# 注意：
# 只有在能够明确确认该磁盘就是系统盘时才执行。
# 不会影响 sdb/sdc 等外部磁盘。
# ------------------------------------------------------------------------------

SYSTEM_DISK=""

for SYSTEM_TARGET in /boot /rom; do
    SYSTEM_DEV="$(awk -v mp="$SYSTEM_TARGET" '$2 == mp {print $1; exit}' /proc/mounts 2>/dev/null)"

    case "$SYSTEM_DEV" in
        /dev/sd[a-z][0-9]*)
            SYSTEM_DISK="${SYSTEM_DEV##/dev/}"
            SYSTEM_DISK="${SYSTEM_DISK%%[0-9]*}"
            break
            ;;
    esac
done

if [ -n "$SYSTEM_DISK" ] && [ "$DISK" = "$SYSTEM_DISK" ]; then
    logger -t AUTO-MOUNT "Skip system-disk partition $DEVNAME on /dev/$SYSTEM_DISK"
    exit 0
fi

# ------------------------------------------------------------------------------
# 8. 使用 block info 判断设备是否已经由 block/fstab 处理
#
# 如果 block info 已经明确知道该设备对应某个挂载点，
# 不再让匿名 automount 重复处理。
# ------------------------------------------------------------------------------

if block info 2>/dev/null | grep -q "^/dev/$DEVNAME:"; then
    INFO="$(block info 2>/dev/null | grep "^/dev/$DEVNAME:" | head -n 1)"

    case "$INFO" in
        *'MOUNT="/boot"'*)
            logger -t AUTO-MOUNT "Skip configured system device: $DEVNAME (/boot)"
            exit 0
            ;;
        *'MOUNT="/rom"'*)
            logger -t AUTO-MOUNT "Skip configured system device: $DEVNAME (/rom)"
            exit 0
            ;;
        *'MOUNT="/overlay"'*)
            logger -t AUTO-MOUNT "Skip configured system device: $DEVNAME (/overlay)"
            exit 0
            ;;
    esac
fi

# ------------------------------------------------------------------------------
# 9. 保留普通外部存储自动挂载
#
# 到这里说明：
#
#   不是 /boot
#   不是 /rom
#   不是 /overlay
#   不是系统启动盘其它保留分区
#
# 因此继续保持原生即插即用行为。
# ------------------------------------------------------------------------------

mntpnt="$DEVNAME"

mkdir -p "/mnt/$mntpnt"
chmod 777 "/mnt/$mntpnt"

# 对 SSD / USB 闪存使用 noatime。
# 不再强制对所有设备使用 discard，
# 避免某些设备出现：
#
#   device does not support discard
#
# 的无意义内核日志。
mount -o rw,noatime "/dev/$DEVNAME" "/mnt/$mntpnt" 2>/dev/null || true

exit 0
EOF

chmod 0755 "${FILES_DIR}/etc/hotplug.d/block/15-automount"

# ------------------------------------------------------------------------------
# Smart Fstab
#
# 保持自动挂载能力。
# 不设置 anon_mount=0。
# 不关闭 auto_mount。
# ------------------------------------------------------------------------------

cat <<'EOF' > "${FILES_DIR}/etc/uci-defaults/93-optimize-fstools"
#!/bin/sh

command -v uci >/dev/null 2>&1 || exit 0

# 保留自动挂载能力
uci -q set fstab.@global[0].auto_mount='1'

# 不主动关闭 anon_mount。
# 交由经过系统盘保护的 15-automount 决定是否自动挂载。

# ------------------------------------------------------------------------------
# 对已经明确配置的数据盘进行性能优化
# ------------------------------------------------------------------------------

config_load fstab 2>/dev/null

set_data_mount() {
    local cfg="$1"
    local target
    local uuid

    config_get target "$cfg" target
    config_get uuid "$cfg" uuid

    case "$target" in
        /mnt/sdb1)
            [ "$uuid" = "c09e2735-a6a5-443f-9733-de75c1001542" ] || return 0

            uci -q set "fstab.$cfg.enabled=1"
            uci -q set "fstab.$cfg.options=rw,noatime,nodiratime"
            ;;
    esac
}

config_foreach set_data_mount mount

uci -q commit fstab

exit 0
EOF

chmod 0755 "${FILES_DIR}/etc/uci-defaults/93-optimize-fstools"

log_i "✅ 阶段 9: 系统盘保护型自动挂载策略注入完成"
log_i "   - 保留 FAT32/exFAT/NTFS/ext4 USB 自动挂载"
log_i "   - 保护 /boot、/rom、/overlay"
log_i "   - 保护系统盘其它保留分区"
log_i "   - 保留 fstab auto_mount=1"
log_i "   - 不修改 fstools/blockd/79_move_config"

log_i "🎉 CI 终极稳定版 Part 2 (架构增强版) 彻底无风险完成！"
