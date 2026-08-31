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
#    - fstab：只负责已经明确配置的固定设备。
#    - 15-automount：负责普通可移动存储设备的即插即用自动挂载。
#    - 系统盘保护：自动识别 /boot、/rom、/overlay 所属设备并隔离。
#
# 4. IPSec 完美修复：
#    - 源码级修复 luci-app-ipsec-vpnd 的 @service[0] 状态重载 Bug。
#    - 动态接管原生 ipsec 服务，解决双将夺权与端口冲突。
#
# 5. 存储生命周期与 IO 优化：
#    - 自动识别 SSD/HDD 并动态设置 read_ahead_kb。
#    - 独立 fstrim 垃圾回收机制。
#
# 6. 智能网卡硬件加速：
#    - 自动识别 Intel/Mellanox 等网卡开启全 Offload，其余网卡保守加速防断流。
#
# 7. gettext host 编译修复 & 消除 baresip 循环依赖：
#    - 修复 gettext-full host 编译时 BISON_LOCALEDIR 未定义问题。
#    - 清除 feeds 中 baresip 的 Kconfig 循环依赖死锁。
# ==============================================================================

set -euo pipefail

# --------------------------------------------------------------------------
# 全局配置 & CI 环境变量
# --------------------------------------------------------------------------
readonly TARGET_IP="192.168.5.1"
readonly TARGET_HOSTNAME="LEDE"
readonly FILES_DIR="files"

: "${TRIM_SCHEDULE:="0 3 * * *"}"
: "${SSD_READ_AHEAD_KB:="2048"}"
: "${HDD_READ_AHEAD_KB:="128"}"

log_i() { echo -e "\033[36m[INFO]\033[0m $1"; }
log_w() { echo -e "\033[33m[WARN]\033[0m $1"; }

# --------------------------------------------------------------------------
# 预检与目录初始化
# --------------------------------------------------------------------------
[[ -f scripts/feeds ]] || {
    echo "❌ 错误: 必须在 OpenWrt 源码根目录执行此脚本"
    exit 1
}

mkdir -p "${FILES_DIR}/etc/"{uci-defaults,init.d,hotplug.d/block,hotplug.d/mount,config}
mkdir -p "${FILES_DIR}/usr/bin"

# ==============================================================================
# 阶段 0: 注入第三方独立插件 (避免 index 解析错误)
# ==============================================================================
log_i "🔥 正在下载 Argon 主题及配置插件..."

rm -rf feeds/luci/themes/luci-theme-argon
rm -rf feeds/luci/applications/luci-app-argon-config
rm -rf package/luci-theme-argon
rm -rf package/luci-app-argon-config

git clone --depth=1 https://github.com/jerrykuku/luci-theme-argon.git package/luci-theme-argon
git clone --depth=1 https://github.com/jerrykuku/luci-app-argon-config.git package/luci-app-argon-config

log_i "✅ Argon 主题及插件注入完成"

# ==============================================================================
# 阶段 0.5: 修复 luci-app-ipsec-vpnd 源码级重载 Bug
# ==============================================================================
log_i "🔧 正在修复 luci-app-ipsec-vpnd 源码级状态查询 Bug..."

VPND_INIT_SRC=$(find package feeds -type f -path "*/luci-app-ipsec-vpnd/root/etc/init.d/ipsec-vpnd" 2>/dev/null | head -n 1 || true)

if [ -n "$VPND_INIT_SRC" ] && [ -f "$VPND_INIT_SRC" ]; then

    # 精准修复错误的 UCI 查询路径。
    sed -i 's#uci get ipsec-vpnd@service\[0\]\.enabled#uci get ipsec-vpnd.ipsec.enabled#g' "$VPND_INIT_SRC"

    if grep -q 'uci get ipsec-vpnd.ipsec.enabled' "$VPND_INIT_SRC"; then
        log_i "✅ 成功修复 ipsec-vpnd UCI section 查询"
        log_i "   修复: ipsec-vpnd@service[0].enabled → ipsec-vpnd.ipsec.enabled"
    else
        log_w "⚠️ ipsec-vpnd UCI 查询修复验证失败"
    fi
else
    log_w "⚠️ 未找到 ipsec-vpnd 初始化脚本源码，跳过源码级修复"
fi

# ==============================================================================
# 阶段 0.6: 修复 gettext-full host 编译 BISON_LOCALEDIR 未定义问题
# ==============================================================================
log_i "🔧 正在修复 gettext-full host 编译 BISON_LOCALEDIR 问题..."

GETTEXT_MK="package/libs/gettext-full/Makefile"

if [ -f "$GETTEXT_MK" ]; then

    # --------------------------------------------------------------------------
    # 检查是否已经存在 BISON_LOCALEDIR 定义
    # 使用纯文本匹配，避免误判等号、反斜杠及引号
    # --------------------------------------------------------------------------
    if grep -qF 'BISON_LOCALEDIR' "$GETTEXT_MK"; then

        log_i "ℹ️ gettext-full Makefile 已存在 BISON_LOCALEDIR，跳过重复修改"

    # --------------------------------------------------------------------------
    # 优先修改 gettext-full 原有 HOST_CPPFLAGS
    # 这是最直接、最可靠的 host 编译预处理宏传递方式
    # --------------------------------------------------------------------------
    elif grep -qE '^[[:space:]]*HOST_CPPFLAGS[[:space:]]*\+=' "$GETTEXT_MK"; then

        sed -i \
            '/^[[:space:]]*HOST_CPPFLAGS[[:space:]]*+=/ s#$# -DBISON_LOCALEDIR=\"$(STAGING_DIR_HOSTPKG)/share/locale\"#' \
            "$GETTEXT_MK"

        log_i "✅ 已向现有 HOST_CPPFLAGS 注入 BISON_LOCALEDIR"

    # --------------------------------------------------------------------------
    # 如果没有 HOST_CPPFLAGS，但存在 HOST_CFLAGS，则作为兼容方案
    # --------------------------------------------------------------------------
    elif grep -qE '^[[:space:]]*HOST_CFLAGS[[:space:]]*\+=' "$GETTEXT_MK"; then

        sed -i \
            '/^[[:space:]]*HOST_CFLAGS[[:space:]]*+=/ s#$# -DBISON_LOCALEDIR=\"$(STAGING_DIR_HOSTPKG)/share/locale\"#' \
            "$GETTEXT_MK"

        log_i "✅ 未找到 HOST_CPPFLAGS，已向 HOST_CFLAGS 注入 BISON_LOCALEDIR"

    # --------------------------------------------------------------------------
    # 最后兜底：直接创建 HOST_CPPFLAGS
    # --------------------------------------------------------------------------
    else

        cat <<'EOF' >> "$GETTEXT_MK"

# OpenWrt DIY: fix gettext-full host BISON_LOCALEDIR
HOST_CPPFLAGS += -DBISON_LOCALEDIR=\"$(STAGING_DIR_HOSTPKG)/share/locale\"
EOF

        log_i "✅ 已创建 HOST_CPPFLAGS 并注入 BISON_LOCALEDIR"

    fi

    # --------------------------------------------------------------------------
    # 最终验证
    # --------------------------------------------------------------------------
    if grep -qF 'BISON_LOCALEDIR' "$GETTEXT_MK"; then

        log_i "✅ gettext-full BISON_LOCALEDIR 修复验证通过"

        grep -n 'BISON_LOCALEDIR' "$GETTEXT_MK" | head -n 5 || true

    else

        log_w "⚠️ gettext-full BISON_LOCALEDIR 修复验证失败"

    fi

else

    log_w "⚠️ 未找到 $GETTEXT_MK，跳过 gettext-full 修复"

fi

# ==============================================================================
# 阶段 0.7: 消除 feeds 中 baresip 的 Kconfig 循环依赖死锁
# ==============================================================================
log_i "🔧 正在清理 baresip 循环依赖软件包..."

find feeds/ -type d -name "baresip" -exec rm -rf {} + 2>/dev/null || true
rm -rf package/feeds/packages/baresip 2>/dev/null || true

log_i "✅ baresip 冲突包已清除"

# ==============================================================================
# 阶段 1: 系统初始化 (静态配置注入)
# ==============================================================================
log_i "🔥 正在注入系统初始化配置..."

cat <<EOF > "${FILES_DIR}/etc/uci-defaults/90-system-init"
#!/bin/sh
TARGET_IP='${TARGET_IP}'
TARGET_HOSTNAME='${TARGET_HOSTNAME}'
EOF

cat <<'EOF' >> "${FILES_DIR}/etc/uci-defaults/90-system-init"
uci -q set network.lan.ipaddr="$TARGET_IP"
uci -q set system.@system[0].hostname="$TARGET_HOSTNAME"
uci -q commit network
uci -q commit system

if command -v uci >/dev/null 2>&1; then
    if ! uci -q get samba4.@samba[0] >/dev/null 2>&1; then
        uci add samba4 samba
        uci set samba4.@samba[-1].workgroup='WORKGROUP'
        uci set samba4.@samba[-1].charset='UTF-8'
        uci set samba4.@samba[-1].interface='lan'
    fi

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
log_i "🔥 正在注入 VPN 端口放行规则..."

cat <<'EOF' > "${FILES_DIR}/etc/uci-defaults/91-vpn-firewall"
#!/bin/sh

if command -v uci >/dev/null 2>&1; then

    # IPSec IKE & NAT-T
    uci -q delete firewall.ipsec_allow
    uci set firewall.ipsec_allow=rule
    uci set firewall.ipsec_allow.name='Allow-IPsec'
    uci set firewall.ipsec_allow.src='wan'
    uci set firewall.ipsec_allow.dest_port='500 4500'
    uci set firewall.ipsec_allow.proto='udp'
    uci set firewall.ipsec_allow.target='ACCEPT'

    # IPSec ESP
    uci -q delete firewall.ipsec_esp
    uci set firewall.ipsec_esp=rule
    uci set firewall.ipsec_esp.name='Allow-IPsec-ESP'
    uci set firewall.ipsec_esp.src='wan'
    uci set firewall.ipsec_esp.proto='esp'
    uci set firewall.ipsec_esp.target='ACCEPT'

    # WireGuard
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
log_i "✅ 阶段 2: VPN 防火墙规则预置完成"

# ==============================================================================
# 阶段 3: init.d 挂载提速 Hook
# ==============================================================================
log_i "🔥 正在注入挂载提速 Hook..."

cat <<'EOF' > "${FILES_DIR}/etc/init.d/mount-optimize"
#!/bin/sh /etc/rc.common
START=92

start() {
    command -v mount >/dev/null 2>&1 || return 0

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
log_i "✅ 阶段 3: 挂载提速 Hook 注入完成"

# ==============================================================================
# 阶段 4: 智能网卡硬件加速服务
# ==============================================================================
log_i "🔥 正在注入智能网卡硬件加速..."

cat <<'EOF' > "${FILES_DIR}/etc/init.d/network-accel"
#!/bin/sh /etc/rc.common
START=85

start() {

    command -v ethtool >/dev/null 2>&1 || return 0

    for i in /sys/class/net/*; do

        iface=$(basename "$i")

        case "$iface" in
            lo|br-*|docker*|veth*|ifb*|tun*|tap*|wg*) continue ;;
        esac

        driver=$(ethtool -i "$iface" 2>/dev/null | awk '/driver/{print $2}')

        if echo "$driver" | grep -qE "e1000e|igb|ixgbe|mlx|intel"; then

            logger -t NIC-ACCEL \
                "Enable Full Offload (TSO, GSO, GRO) for Intel/Mellanox NIC: $iface"

            ethtool -K "$iface" tso on gso on gro on 2>/dev/null || true

        else

            logger -t NIC-ACCEL \
                "Enable Safe Offload (SG, GRO) for Realtek/Virtual NIC: $iface"

            ethtool -K "$iface" sg on gro on tso off gso off 2>/dev/null || true

        fi

    done
}
EOF

chmod 0755 "${FILES_DIR}/etc/init.d/network-accel"
log_i "✅ 阶段 4: 网卡加速策略注入完成"

# ==============================================================================
# 阶段 5: Block IO 物理层优化
# ==============================================================================
log_i "🔥 正在注入 Block IO 优化..."

cat <<EOF > "${FILES_DIR}/etc/hotplug.d/block/93-optimize-io"
#!/bin/sh
SSD_READ_AHEAD_KB="${SSD_READ_AHEAD_KB}"
HDD_READ_AHEAD_KB="${HDD_READ_AHEAD_KB}"
EOF

cat <<'EOF' >> "${FILES_DIR}/etc/hotplug.d/block/93-optimize-io"

[ "$ACTION" = "add" ] || exit 0
[ -z "$DEVNAME" ] && exit 0

case "$DEVNAME" in
    nvme*|mmcblk*) dev="${DEVNAME%%p*}" ;;
    sd*|vd*|hd*|xvd*) dev="${DEVNAME%%[0-9]*}" ;;
    *) exit 0 ;;
esac

BASE="/sys/block/$dev"
[ -d "$BASE" ] || exit 0

ROT=$(cat "$BASE/queue/rotational" 2>/dev/null || echo 1)

if [ -f "$BASE/queue/read_ahead_kb" ]; then

    if [ "$ROT" = "0" ]; then
        echo "$SSD_READ_AHEAD_KB" > "$BASE/queue/read_ahead_kb" 2>/dev/null || true
    else
        echo "$HDD_READ_AHEAD_KB" > "$BASE/queue/read_ahead_kb" 2>/dev/null || true
    fi

fi
EOF

chmod 0755 "${FILES_DIR}/etc/hotplug.d/block/93-optimize-io"
log_i "✅ 阶段 5: Block IO read_ahead 优化注入完成"

# ==============================================================================
# 阶段 6: mount 热插拔优化
# ==============================================================================
log_i "🔥 正在注入 mount 热插拔优化..."

cat <<'EOF' > "${FILES_DIR}/etc/hotplug.d/mount/94-optimize-mount"
#!/bin/sh

[ "$ACTION" = "add" ] || exit 0
[ -z "$MOUNTPOINT" ] && exit 0

case "$MOUNTPOINT" in
    /|/rom|/overlay|/boot) exit 0 ;;
esac

if ! grep -q " $MOUNTPOINT " /proc/mounts 2>/dev/null; then
    exit 0
fi

mount -o remount,noatime,nodiratime "$MOUNTPOINT" 2>/dev/null || true

exit 0
EOF

chmod 0755 "${FILES_DIR}/etc/hotplug.d/mount/94-optimize-mount"
log_i "✅ 阶段 6: mount 热插拔优化完成"

# ==============================================================================
# 阶段 7: TRIM 引擎及静态 Cron 注入
# ==============================================================================
log_i "🔥 正在注入 TRIM 引擎及计划任务..."

cat <<'EOF' > "${FILES_DIR}/usr/bin/auto-fstrim"
#!/bin/sh

command -v fstrim >/dev/null 2>&1 || exit 0

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

exit 0
EOF

chmod 0755 "${FILES_DIR}/usr/bin/auto-fstrim"

cat <<EOF > "${FILES_DIR}/etc/uci-defaults/99-zz-cron-trim"
#!/bin/sh

mkdir -p /etc/crontabs
touch /etc/crontabs/root

sed -i '/auto-fstrim/d' /etc/crontabs/root 2>/dev/null || true
echo "${TRIM_SCHEDULE} /usr/bin/auto-fstrim" >> /etc/crontabs/root

/etc/init.d/cron restart 2>/dev/null || true

exit 0
EOF

chmod 0755 "${FILES_DIR}/etc/uci-defaults/99-zz-cron-trim"
log_i "✅ 阶段 7: TRIM 引擎及 Cron 注入完成"

# ==============================================================================
# 阶段 8: 解决 IPSec 启动冲突 (交接权杖)
# ==============================================================================
log_i "🔥 正在注入 IPSec 启动防冲突补丁..."

cat <<'EOF' > "${FILES_DIR}/etc/uci-defaults/92-disable-native-ipsec"
#!/bin/sh

# 1. 禁用原生 strongSwan 自动启动并释放端口
if [ -x "/etc/init.d/ipsec" ]; then
    /etc/init.d/ipsec disable 2>/dev/null || true
    /etc/init.d/ipsec stop 2>/dev/null || true
fi

# 2. 让 ipsec-vpnd 成为唯一管理入口
if [ -x "/etc/init.d/ipsec-vpnd" ]; then
    /etc/init.d/ipsec-vpnd enable 2>/dev/null || true
    /etc/init.d/ipsec-vpnd restart 2>/dev/null || true
fi

exit 0
EOF

chmod 0755 "${FILES_DIR}/etc/uci-defaults/92-disable-native-ipsec"
log_i "✅ 阶段 8: IPSec 启动防冲突补丁注入完成"

# ==============================================================================
# 阶段 9: 最终存储自动挂载架构
# ==============================================================================
log_i "🔥 正在部署最终存储自动挂载架构..."

cat <<'EOF' > "${FILES_DIR}/etc/uci-defaults/93-optimize-fstools"
#!/bin/sh

command -v uci >/dev/null 2>&1 || exit 0

# 禁止 blockd/fstools 对匿名设备进行自动挂载
uci -q set fstab.@global[0].anon_mount='0'

# 保留 fstab 对明确配置设备的管理能力
uci -q set fstab.@global[0].auto_mount='1'

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

                [ "$uuid" = "c09e2735-a6a5-443f-9733-de75c1001542" ] || return 0

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

cat <<'EOF' > "${FILES_DIR}/etc/hotplug.d/block/15-automount"
#!/bin/sh

[ "$ACTION" = "add" ] || exit 0
[ -z "$DEVNAME" ] && exit 0

case "$DEVNAME" in
    sd[[:alnum:]]*|nvme[0-9]*p[0-9]*|mmcblk[0-9]*p[0-9]*) ;;
    *) exit 0 ;;
esac

protect_system_device() {

    local dev="$1"
    local protected

    # 保护核心挂载点所属设备
    for protected in /boot /rom /overlay; do

        while read -r protected_dev protected_mp _ _ _; do

            [ "$protected_mp" = "$protected" ] || continue

            case "$protected_dev" in

                /dev/*)

                    protected_name="${protected_dev#/dev/}"

                    [ "$dev" = "$protected_name" ] && return 0

                    ;;

            esac

        done < /proc/mounts

    done

    # 保护 GPT/BIOS 保留分区
    case "$dev" in
        sd[[:alnum:]]*128|nvme[0-9]*p128|mmcblk[0-9]*p128)
            return 0
            ;;
    esac

    return 1
}

if protect_system_device "$DEVNAME"; then
    exit 0
fi

FS_TYPE=""

if command -v blkid >/dev/null 2>&1; then
    FS_TYPE="$(blkid -o value -s TYPE "/dev/$DEVNAME" 2>/dev/null || true)"
fi

[ -n "$FS_TYPE" ] || exit 0

case "$FS_TYPE" in
    ext2|ext3|ext4|f2fs|btrfs|xfs|vfat|exfat|ntfs|ntfs3|fuseblk) ;;
    *) exit 0 ;;
esac

if grep -q "^/dev/$DEVNAME " /proc/mounts 2>/dev/null; then
    exit 0
fi

MNT="/mnt/$DEVNAME"

mkdir -p "$MNT" 2>/dev/null || exit 0
chmod 777 "$MNT" 2>/dev/null || true

mount -o rw,noatime "/dev/$DEVNAME" "$MNT" 2>/dev/null || {

    rmdir "$MNT" 2>/dev/null || true

    exit 0
}

exit 0
EOF

chmod 0755 "${FILES_DIR}/etc/hotplug.d/block/15-automount"

cat <<'EOF' > "${FILES_DIR}/etc/hotplug.d/block/10-mount"
[ "$ACTION" = "add" -o "$ACTION" = "remove" ] && /sbin/block hotplug
EOF

chmod 0644 "${FILES_DIR}/etc/hotplug.d/block/10-mount"

log_i "✅ 阶段 9: Smart Fstab + 系统盘保护架构部署完成"

# ==============================================================================
# 阶段 10: 最终安全检查
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

# ==============================================================================
# 阶段 11: Shell 语法最终检查
# ==============================================================================
log_i "🔍 正在执行 DIY Part 2 Shell 语法检查..."

if command -v bash >/dev/null 2>&1; then
    bash -n "$0"
fi

log_i "✅ Shell 语法检查通过"

# ==============================================================================
# 完成
# ==============================================================================
log_i "🎉 DIY Part 2 最终基准版生成完成！"
log_i "📦 存储架构：fstab 管理已知设备 + 15-automount 管理普通可移动设备"
log_i "🛡️ 系统盘保护：/boot /rom /overlay + GPT/BIOS 保留分区"
log_i "🌐 VPN 共存：IPSec 源码级修复 (@service[0] 消除) + WireGuard"
log_i "🔧 基础工具：gettext BISON_LOCALEDIR 宏定义已注入 + baresip 循环依赖已消除"
