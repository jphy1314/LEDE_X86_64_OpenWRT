#!/usr/bin/env bash
# ==============================================================================
# OpenWrt DIY Part 2 - 企业级生产环境最终基准版
# ==============================================================================
# 核心设计目标：
#
# 1. 协议级服务共存 (VPN Coexistence)：
#    - 预置 IPSec (包含 ESP 协议) 与 WireGuard 防火墙规则，实现协议共存。
#
# 2. 健壮的 UCI 持久化：
#    - 所有需要运行于路由器端的 UCI 操作统一注入 uci-defaults。
#    - GitHub Actions 编译阶段不会直接执行路由器专用命令。
#
# 3. 存储挂载分层架构：
#    - fstab：
#      只负责已经明确配置的固定设备。
#
#    - 15-automount：
#      负责普通可移动存储设备的即插即用自动挂载。
#
#    - 系统盘保护：
#      自动识别 /boot、/rom、/overlay 所属设备，
#      并保护对应系统分区以及 GPT/BIOS 保留分区，
#      防止被普通自动挂载逻辑当成 U 盘处理。
#
#    - 93-optimize-io：
#      只负责块设备 read_ahead 参数。
#
#    - 94-optimize-mount：
#      只负责挂载完成后的 noatime/nodiratime 优化。
#
# 4. 非破坏性 Smart Fstab：
#    - 禁止 fstools 对“匿名设备”执行自动挂载。
#    - 已经明确写入 fstab 的设备仍由 fstab 管理。
#    - 普通 USB 移动存储由 15-automount 独立负责。
#
# 5. 全路径兼容：
#    - 挂载点处理尽量避免依赖简单空格分割。
#
# 6. 存储生命周期维护：
#    - 自动识别 SSD/HDD。
#    - 动态设置 read_ahead。
#    - 定时执行 fstrim。
#
# 7. 智能网卡硬件加速：
#    - 自动识别 Intel/Mellanox 等网卡驱动。
#    - Realtek/其它网卡采用保守的安全 Offload 策略。
#
# 8. 严格保持系统盘安全：
#    - 不修改 fstools 核心程序。
#    - 不修改 /lib/preinit/79_move_config。
#    - 不对 /boot、/rom、/overlay 执行性能 remount。
#    - 不让普通自动挂载程序处理固件自己的系统分区。
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

log_i() {
    echo -e "\033[36m[INFO]\033[0m $1"
}

# --------------------------------------------------------------------------
# 预检：必须在 OpenWrt 源码根目录执行
# --------------------------------------------------------------------------

[[ -f scripts/feeds ]] || {
    echo "❌ 错误: 必须在 OpenWrt 源码根目录执行此脚本"
    exit 1
}

# --------------------------------------------------------------------------
# 创建标准目录结构
#
# files 目录中的内容会在编译阶段直接打入固件。
# --------------------------------------------------------------------------

mkdir -p "${FILES_DIR}/etc/"{uci-defaults,init.d,hotplug.d/block,hotplug.d/mount,config}
mkdir -p "${FILES_DIR}/usr/bin"

# ==============================================================================
# 阶段 0: 注入第三方独立插件 (直接拉取到 package 目录避免 index 解析错误)
# ==============================================================================

log_i "🔥 正在下载 Argon 主题及配置插件..."

# 1. 暴力清除系统自带的旧版 argon (防止冲突)
rm -rf feeds/luci/themes/luci-theme-argon
rm -rf feeds/luci/applications/luci-app-argon-config

# 2. 直接拉取最新版 Jerrykuku Argon 到 package 目录
git clone --depth=1 https://github.com/jerrykuku/luci-theme-argon.git package/luci-theme-argon
git clone --depth=1 https://github.com/jerrykuku/luci-app-argon-config.git package/luci-app-argon-config

log_i "✅ Argon 主题及插件注入完成"

# ⬆️⬆️⬆️ 插入结束 ⬆️⬆️⬆️

# ==============================================================================
# 阶段 1: 系统初始化 (静态配置注入)
# ==============================================================================

cat <<EOF > "${FILES_DIR}/etc/uci-defaults/90-system-init"
#!/bin/sh

TARGET_IP='${TARGET_IP}'
TARGET_HOSTNAME='${TARGET_HOSTNAME}'
EOF

cat <<'EOF' >> "${FILES_DIR}/etc/uci-defaults/90-system-init"

# 增加 -q 静默执行，避免上游配置结构发生轻微变化时产生无意义输出
uci -q set network.lan.ipaddr="$TARGET_IP"
uci -q set system.@system[0].hostname="$TARGET_HOSTNAME"

uci -q commit network
uci -q commit system

# Samba4 自动修复逻辑
# 确保基础配置存在，并保留后续用户自定义共享配置。
if command -v uci >/dev/null 2>&1; then

    if ! uci -q get samba4.@samba[0] >/dev/null 2>&1; then
        uci add samba4 samba
        uci set samba4.@samba[-1].workgroup='WORKGROUP'
        uci set samba4.@samba[-1].charset='UTF-8'
        uci set samba4.@samba[-1].interface='lan'
    fi

    # 清除默认模板共享，避免默认共享与用户自定义共享冲突。
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
# 阶段 2: VPN 防火墙预置 (IPSec 与 WireGuard 共存)
# ==============================================================================

log_i "🔥 正在注入 VPN 端口放行规则，保障开机即用..."

cat <<'EOF' > "${FILES_DIR}/etc/uci-defaults/91-vpn-firewall"
#!/bin/sh

# 动态注入防火墙规则，保障 IPSec 与 WireGuard 正常工作。
if command -v uci >/dev/null 2>&1; then

    # --------------------------------------------------------------------------
    # IPSec IKE & NAT-T
    # --------------------------------------------------------------------------

    uci -q delete firewall.ipsec_allow

    uci set firewall.ipsec_allow=rule
    uci set firewall.ipsec_allow.name='Allow-IPsec'
    uci set firewall.ipsec_allow.src='wan'
    uci set firewall.ipsec_allow.dest_port='500 4500'
    uci set firewall.ipsec_allow.proto='udp'
    uci set firewall.ipsec_allow.target='ACCEPT'

    # --------------------------------------------------------------------------
    # IPSec ESP
    # --------------------------------------------------------------------------

    uci -q delete firewall.ipsec_esp

    uci set firewall.ipsec_esp=rule
    uci set firewall.ipsec_esp.name='Allow-IPsec-ESP'
    uci set firewall.ipsec_esp.src='wan'
    uci set firewall.ipsec_esp.proto='esp'
    uci set firewall.ipsec_esp.target='ACCEPT'

    # --------------------------------------------------------------------------
    # WireGuard
    # --------------------------------------------------------------------------

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
# 阶段 3: init.d 挂载提速 Hook
#
# 只负责已经完成挂载后的性能优化。
# 不负责设备探测。
# 不负责设备自动挂载。
# 不处理系统核心挂载点。
# ==============================================================================

cat <<'EOF' > "${FILES_DIR}/etc/init.d/mount-optimize"
#!/bin/sh /etc/rc.common

START=92

start() {

    command -v mount >/dev/null 2>&1 || return 0

    while read -r dev mp fs _; do

        # 只处理真实块设备。
        case "$dev" in
            /dev/*)
                ;;
            *)
                continue
                ;;
        esac

        # 只处理常见物理文件系统。
        case "$fs" in
            ext4|btrfs|xfs|f2fs|vfat|exfat|ntfs*|fuseblk)
                ;;
            *)
                continue
                ;;
        esac

        # 系统核心挂载点不进行 remount。
        case "$mp" in
            /|/rom|/overlay|/boot)
                continue
                ;;
        esac

        # 只增加访问时间相关优化。
        mount -o remount,noatime,nodiratime "$mp" 2>/dev/null || true

    done < /proc/mounts
}
EOF

chmod 0755 "${FILES_DIR}/etc/init.d/mount-optimize"

log_i "✅ 阶段 3: 挂载完成后的性能优化 Hook 注入完成"

# ==============================================================================
# 阶段 4: 智能网卡硬件加速服务
#
# 只负责网卡 Offload。
# 不修改网络拓扑、不修改 MTU、不修改队列长度。
# ==============================================================================

cat <<'EOF' > "${FILES_DIR}/etc/init.d/network-accel"
#!/bin/sh /etc/rc.common

START=85

start() {

    command -v ethtool >/dev/null 2>&1 || return 0

    for i in /sys/class/net/*; do

        iface=$(basename "$i")

        case "$iface" in
            lo|br-*|docker*|veth*|ifb*|tun*|tap*|wg*)
                continue
                ;;
        esac

        driver=$(ethtool -i "$iface" 2>/dev/null | awk '/driver/{print $2}')

        # Intel/Mellanox 网卡采用完整 Offload。
        if echo "$driver" | grep -qE "e1000e|igb|ixgbe|mlx|intel"; then

            logger -t NIC-ACCEL \
                "Enable Full Offload (TSO, GSO, GRO) for Intel/Mellanox NIC: $iface"

            ethtool -K "$iface" tso on gso on gro on 2>/dev/null || true

        else

            # 其它网卡采用保守策略，降低潜在兼容性问题。
            logger -t NIC-ACCEL \
                "Enable Safe Offload (SG, GRO) for Realtek/Virtual NIC: $iface"

            ethtool -K "$iface" sg on gro on tso off gso off 2>/dev/null || true

        fi

    done
}
EOF

chmod 0755 "${FILES_DIR}/etc/init.d/network-accel"

log_i "✅ 阶段 4: 智能网卡硬件加速策略注入完成"

# ==============================================================================
# 阶段 5: Block IO 物理层优化
#
# 架构职责：
#   只修改 read_ahead_kb。
#
# 不负责：
#   - 自动挂载
#   - 文件系统探测
#   - fstab
#   - mount 参数
# ==============================================================================

cat <<EOF > "${FILES_DIR}/etc/hotplug.d/block/93-optimize-io"
#!/bin/sh

SSD_READ_AHEAD_KB="${SSD_READ_AHEAD_KB}"
HDD_READ_AHEAD_KB="${HDD_READ_AHEAD_KB}"
EOF

cat <<'EOF' >> "${FILES_DIR}/etc/hotplug.d/block/93-optimize-io"

[ "$ACTION" = "add" ] || exit 0
[ -z "$DEVNAME" ] && exit 0

# 提取主设备名。
# 兼容 NVMe、mmcblk、sdX、vdX、hdX、xvdX 等设备。
case "$DEVNAME" in
    nvme*)
        dev="${DEVNAME%%p*}"
        ;;
    mmcblk*)
        dev="${DEVNAME%%p*}"
        ;;
    sd*)
        dev="${DEVNAME%%[0-9]*}"
        ;;
    vd*)
        dev="${DEVNAME%%[0-9]*}"
        ;;
    hd*)
        dev="${DEVNAME%%[0-9]*}"
        ;;
    xvd*)
        dev="${DEVNAME%%[0-9]*}"
        ;;
    *)
        exit 0
        ;;
esac

BASE="/sys/block/$dev"

[ -d "$BASE" ] || exit 0

# rotational:
#   0 = 非旋转介质（SSD/NVMe）
#   1 = 旋转介质（HDD）
ROT=$(cat "$BASE/queue/rotational" 2>/dev/null || echo 1)

if [ -f "$BASE/queue/read_ahead_kb" ]; then

    if [ "$ROT" = "0" ]; then
        echo "$SSD_READ_AHEAD_KB" \
            > "$BASE/queue/read_ahead_kb" 2>/dev/null || true
    else
        echo "$HDD_READ_AHEAD_KB" \
            > "$BASE/queue/read_ahead_kb" 2>/dev/null || true
    fi

fi
EOF

chmod 0755 "${FILES_DIR}/etc/hotplug.d/block/93-optimize-io"

log_i "✅ 阶段 5: Block IO read_ahead 优化注入完成"

# ==============================================================================
# 阶段 6: mount 热插拔优化
#
# 架构职责：
#   只处理“已经完成挂载”的文件系统。
#
# 它不参与：
#   - block 设备探测
#   - 自动挂载
#   - fstab
#
# 系统核心挂载点始终跳过。
# ==============================================================================

cat <<'EOF' > "${FILES_DIR}/etc/hotplug.d/mount/94-optimize-mount"
#!/bin/sh

[ "$ACTION" = "add" ] || exit 0
[ -z "$MOUNTPOINT" ] && exit 0

# 系统核心挂载点不处理。
case "$MOUNTPOINT" in
    /|/rom|/overlay|/boot)
        exit 0
        ;;
esac

# 确认挂载点已经真正出现在 /proc/mounts。
if ! grep -q " $MOUNTPOINT " /proc/mounts 2>/dev/null; then
    exit 0
fi

# 只修改访问时间相关参数。
mount -o remount,noatime,nodiratime \
    "$MOUNTPOINT" 2>/dev/null || true

exit 0
EOF

chmod 0755 "${FILES_DIR}/etc/hotplug.d/mount/94-optimize-mount"

log_i "✅ 阶段 6: 挂载完成后的 noatime/nodiratime 优化注入完成"

# ==============================================================================
# 阶段 7: TRIM 引擎及静态 Cron 注入
# ==============================================================================

cat <<'EOF' > "${FILES_DIR}/usr/bin/auto-fstrim"
#!/bin/sh

command -v fstrim >/dev/null 2>&1 || exit 0

# 仅对真实块设备以及支持 TRIM 的文件系统执行回收。
while read -r dev mp fs _; do

    case "$dev" in
        /dev/*)
            ;;
        *)
            continue
            ;;
    esac

    case "$fs" in
        ext4|btrfs|xfs|f2fs)
            ;;
        *)
            continue
            ;;
    esac

    fstrim "$mp" 2>/dev/null || true

done < /proc/mounts

exit 0
EOF

chmod 0755 "${FILES_DIR}/usr/bin/auto-fstrim"

cat <<EOF > "${FILES_DIR}/etc/uci-defaults/99-zz-cron-trim"
#!/bin/sh

mkdir -p /etc/crontabs
touch /etc/crontabs/root

# 清理旧版本自动 TRIM 任务，避免重复执行。
sed -i '/auto-fstrim/d' /etc/crontabs/root 2>/dev/null || true

echo "${TRIM_SCHEDULE} /usr/bin/auto-fstrim" \
    >> /etc/crontabs/root

# 首次启动后立即重新加载 Cron。
/etc/init.d/cron restart 2>/dev/null || true

exit 0
EOF

chmod 0755 "${FILES_DIR}/etc/uci-defaults/99-zz-cron-trim"

log_i "✅ 阶段 7: TRIM 引擎及 Cron 注入完成"

# ==============================================================================
# 阶段 8: 解决 IPSec 启动冲突
#
# 禁止原生 strongSwan 服务与 luci-app-ipsec-vpnd 同时管理 charon。
# ==============================================================================

log_i "🔥 正在注入 IPSec 启动防冲突补丁..."

cat <<'EOF' > "${FILES_DIR}/etc/uci-defaults/92-disable-native-ipsec"
#!/bin/sh

# ============================================================================
# IPSec 服务架构：
#
#   luci-app-ipsec-vpnd
#          ↓
#     ipsec-vpnd
#          ↓
#       charon
#
# 禁止原生 /etc/init.d/ipsec 与 ipsec-vpnd 同时运行。
# ============================================================================

# 1. 禁止原生 strongSwan 自动启动。
if [ -x "/etc/init.d/ipsec" ]; then

    /etc/init.d/ipsec disable 2>/dev/null || true

    # 如果首次启动时原生 ipsec 已经运行，则立即停止。
    /etc/init.d/ipsec stop 2>/dev/null || true

fi

# 2. 让 ipsec-vpnd 成为唯一管理入口。
if [ -x "/etc/init.d/ipsec-vpnd" ]; then

    /etc/init.d/ipsec-vpnd enable 2>/dev/null || true

    # 原生 ipsec 停止后重新建立正确的 charon 实例。
    /etc/init.d/ipsec-vpnd restart 2>/dev/null || true

fi

exit 0
EOF

chmod 0755 "${FILES_DIR}/etc/uci-defaults/92-disable-native-ipsec"

log_i "✅ 阶段 8: IPSec 启动防冲突补丁注入完成"

# ==============================================================================
# 阶段 9: 最终存储自动挂载架构
#
# ============================================================================
# 设计原则：
#
#   fstab
#      ↓
#   已知固定设备
#
#   15-automount
#      ↓
#   普通可移动存储
#
#   系统盘保护
#      ↓
#   排除 /boot /rom /overlay 以及 GPT/BIOS 保留分区
#
#   93-optimize-io
#      ↓
#   read_ahead
#
#   94-optimize-mount
#      ↓
#   noatime/nodiratime
#
# 重要：
#   不再使用 anon_mount=1 让 blockd 与 15-automount 同时管理匿名设备。
#
#   anon_mount=0 并不意味着“关闭 USB 自动挂载”。
#
#   普通 USB 自动挂载由本阶段重新定义的 15-automount 独立负责。
# ==============================================================================

log_i "🔥 正在部署最终存储自动挂载架构..."

# ------------------------------------------------------------------------------
# 9.1 Smart Fstab
#
# fstab 只负责“明确配置过的设备”。
# 普通匿名设备交给 15-automount。
# ------------------------------------------------------------------------------

cat <<'EOF' > "${FILES_DIR}/etc/uci-defaults/93-optimize-fstools"
#!/bin/sh

command -v uci >/dev/null 2>&1 || exit 0

# --------------------------------------------------------------------------
# 禁止 blockd/fstools 对匿名设备进行自动挂载。
#
# 这样可以避免：
#
#   /dev/sda128
#   系统保留分区
#   未配置的系统设备
#
# 被 blockd 当成普通文件系统进行处理。
#
# 注意：
# 普通 USB 自动挂载并没有关闭，因为它由 15-automount 独立负责。
# --------------------------------------------------------------------------

uci -q set fstab.@global[0].anon_mount='0'

# --------------------------------------------------------------------------
# 保留 fstab 对明确配置设备的管理能力。
# --------------------------------------------------------------------------

uci -q set fstab.@global[0].auto_mount='1'

# --------------------------------------------------------------------------
# 只修改当前明确配置的数据盘。
#
# 不遍历 /boot、/rom、/overlay 等系统挂载点。
# 不使用 @mount[N] 硬编码索引。
# --------------------------------------------------------------------------

if command -v config_load >/dev/null 2>&1; then

    config_load fstab 2>/dev/null

    set_data_mount() {

        local cfg="$1"
        local target
        local uuid

        config_get target "$cfg" target
        config_get uuid "$cfg" uuid

        case "$target" in

            /mnt/sdb1)

                [ "$uuid" = "c09e2735-a6a5-443f-9733-de75c1001542" ] \
                    || return 0

                uci -q set "fstab.$cfg.enabled=1"
                uci -q set "fstab.$cfg.options=rw,noatime,nodiratime"

                ;;

        esac
    }

    config_foreach set_data_mount mount

fi

uci -q commit fstab

exit 0
EOF

chmod 0755 "${FILES_DIR}/etc/uci-defaults/93-optimize-fstools"

# ------------------------------------------------------------------------------
# 9.2 最终版 15-automount
#
# 普通 USB / SATA 可移动存储仍然保持“即插即用自动挂载”。
#
# 与原版相比：
#
#   原版：
#       通过 block info 排除 kernel/squashfs 等文件系统，
#       但在设备刚出现、block info 尚未稳定时存在竞态。
#
#   新版：
#       直接根据系统当前真实挂载关系识别保护设备，
#       再额外保护其 GPT/BIOS 保留分区。
#
# 因此：
#
#   /boot       → 不自动挂载
#   /rom        → 不自动挂载
#   /overlay    → 不自动挂载
#   sda128      → 不自动挂载
#   普通 USB    → 继续自动挂载
#   普通 SATA   → 继续自动挂载
# ------------------------------------------------------------------------------

cat <<'EOF' > "${FILES_DIR}/etc/hotplug.d/block/15-automount"
#!/bin/sh

# ==============================================================================
# 普通可移动存储自动挂载
#
# 架构职责：
#   只负责普通块设备的即插即用自动挂载。
#
# 系统核心设备由 protect_system_device() 主动排除。
# ==============================================================================

[ "$ACTION" = "add" ] || exit 0
[ -z "$DEVNAME" ] && exit 0

# --------------------------------------------------------------------------
# 只处理真正的分区设备。
#
# 当前目标：
#   sdXN
#   nvmeXpY
#   mmcblkNpY
#
# loop、dm、md 等设备不参与普通 USB 自动挂载。
# --------------------------------------------------------------------------

case "$DEVNAME" in

    sd[[:alnum:]]*)
        ;;

    nvme[0-9]*p[0-9]*)
        ;;

    mmcblk[0-9]*p[0-9]*)
        ;;

    *)
        exit 0
        ;;

esac

# ==============================================================================
# 系统盘保护
# ==============================================================================

protect_system_device() {

    local dev="$1"
    local protected
    local disk
    local part

    # --------------------------------------------------------------------------
    # 保护当前已经明确挂载到系统核心路径的设备。
    #
    # 直接从 /proc/mounts 获取：
    #
    #   /boot
    #   /rom
    #   /overlay
    #
    # 所属设备。
    # --------------------------------------------------------------------------

    for protected in /boot /rom /overlay; do

        while read -r protected_dev protected_mp protected_fs rest; do

            [ "$protected_mp" = "$protected" ] || continue

            case "$protected_dev" in

                /dev/*)

                    protected_name="${protected_dev#/dev/}"

                    [ "$dev" = "$protected_name" ] && return 0

                    ;;

            esac

        done < /proc/mounts

    done

    # --------------------------------------------------------------------------
    # 保护 GPT/BIOS 保留分区。
    #
    # 典型 x86_64 GPT 系统可能出现：
    #
    #   sda128
    #   nvme0n1p128
    #
    # 这些分区没有正常文件系统，不应该进入普通自动挂载流程。
    # --------------------------------------------------------------------------

    case "$dev" in

        sd[[:alnum:]]*128)
            return 0
            ;;

        nvme[0-9]*p128)
            return 0
            ;;

        mmcblk[0-9]*p128)
            return 0
            ;;

    esac

    # --------------------------------------------------------------------------
    # 保护已经属于 /boot、/rom、/overlay 所在磁盘的系统分区。
    #
    # 这里只保护“已经作为系统核心挂载设备出现的同一分区”，
    # 不直接封锁整块磁盘，避免误伤同一磁盘上的普通数据分区。
    # --------------------------------------------------------------------------

    return 1
}

# 如果属于系统核心设备，则直接退出。
if protect_system_device "$DEVNAME"; then
    exit 0
fi

# ==============================================================================
# 文件系统类型检查
#
# 普通 U 盘只要系统具备相应文件系统驱动即可继续自动挂载。
# ==============================================================================

FS_TYPE=""

if command -v blkid >/dev/null 2>&1; then
    FS_TYPE="$(blkid -o value -s TYPE "/dev/$DEVNAME" 2>/dev/null || true)"
fi

# 如果无法识别文件系统，不进行强制挂载。
[ -n "$FS_TYPE" ] || exit 0

case "$FS_TYPE" in

    ext2|ext3|ext4|f2fs|btrfs|xfs|vfat|exfat|ntfs|ntfs3|fuseblk)
        ;;

    *)
        exit 0
        ;;

esac

# ==============================================================================
# 避免重复挂载
# ==============================================================================

if grep -q "^/dev/$DEVNAME " /proc/mounts 2>/dev/null; then
    exit 0
fi

# ==============================================================================
# 自动创建挂载点
#
# 保持原有行为：
#
#   /dev/sdb1 → /mnt/sdb1
#   /dev/sdc1 → /mnt/sdc1
#   /dev/nvme1n1p1 → /mnt/nvme1n1p1
# ==============================================================================

MNT="/mnt/$DEVNAME"

mkdir -p "$MNT" 2>/dev/null || exit 0
chmod 777 "$MNT" 2>/dev/null || true

# ==============================================================================
# 自动挂载
#
# 使用 noatime。
#
# 不在这里执行 nodiratime、TRIM 等其它优化，
# 这些工作分别由 94-optimize-mount 和 auto-fstrim 完成。
# ==============================================================================

mount -o rw,noatime "/dev/$DEVNAME" "$MNT" 2>/dev/null || {
    rmdir "$MNT" 2>/dev/null || true
    exit 0
}

exit 0
EOF

chmod 0755 "${FILES_DIR}/etc/hotplug.d/block/15-automount"

# ------------------------------------------------------------------------------
# 9.3 保留 10-mount，但不再让 blockd 负责匿名自动挂载
#
# block hotplug 仍然交给 block 处理。
# 实际普通可移动设备挂载由 15-automount 完成。
# ------------------------------------------------------------------------------

cat <<'EOF' > "${FILES_DIR}/etc/hotplug.d/block/10-mount"
[ "$ACTION" = "add" -o "$ACTION" = "remove" ] && /sbin/block hotplug
EOF

chmod 0644 "${FILES_DIR}/etc/hotplug.d/block/10-mount"

log_i "✅ 阶段 9: Smart Fstab + 系统盘保护 + 普通 USB 自动挂载架构部署完成"

# ==============================================================================
# 阶段 10: 最终安全检查
#
# 这里只检查我们自己生成的文件，不执行任何 OpenWrt 路由器端命令。
# ==============================================================================

log_i "🔍 正在执行 DIY Part 2 静态文件检查..."

for required_file in \
    "${FILES_DIR}/etc/uci-defaults/90-system-init" \
    "${FILES_DIR}/etc/uci-defaults/91-vpn-firewall" \
    "${FILES_DIR}/etc/uci-defaults/92-disable-native-ipsec" \
    "${FILES_DIR}/etc/uci-defaults/93-optimize-fstools" \
    "${FILES_DIR}/etc/uci-defaults/99-zz-cron-trim" \
    "${FILES_DIR}/etc/init.d/mount-optimize" \
    "${FILES_DIR}/etc/init.d/network-accel" \
    "${FILES_DIR}/etc/hotplug.d/block/10-mount" \
    "${FILES_DIR}/etc/hotplug.d/block/15-automount" \
    "${FILES_DIR}/etc/hotplug.d/block/93-optimize-io" \
    "${FILES_DIR}/etc/hotplug.d/mount/94-optimize-mount" \
    "${FILES_DIR}/usr/bin/auto-fstrim"
do

    [ -f "$required_file" ] || {
        echo "❌ 缺少文件: $required_file"
        exit 1
    }

done

log_i "✅ 所有核心注入文件检查通过"

# ==============================================================================
# 完成
# ==============================================================================

log_i "🎉 DIY Part 2 最终基准版生成完成！"
log_i "📦 存储架构：fstab 管理已知设备 + 15-automount 管理普通可移动设备"
log_i "🛡️ 系统盘保护：/boot /rom /overlay + GPT/BIOS 保留分区"
log_i "⚙️ IO 架构：93-optimize-io 负责 read_ahead，94-optimize-mount 负责 noatime"
log_i "💾 TRIM：由 auto-fstrim + Cron 独立负责"
log_i "🔒 fstools：关闭匿名自动挂载，避免 blockd 与 15-automount 发生职责冲突"
