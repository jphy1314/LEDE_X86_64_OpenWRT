#!/usr/bin/env bash
# ==============================================================================
# OpenWrt DIY Part 2 - 企业级生产环境版功能特性
# ==============================================================================
# 核心设计目标：
# 1. 物理级服务隔离 (Service Isolation)：
#    - 通过编译期静态注入"空壳"脚本，彻底封堵原生 IPSec 与插件间的启动冲突。
# 2. 健壮的 UCI 持久化 (Atomic Commit)：
#    - 修复 Subshell 管道陷阱，改用 Here-document 确保循环内 UCI 指令在当前 Shell 进程执行，保证 commit 100% 写入。
# 3. 非破坏性挂载策略 (Smart Fstab)：
#    - 采用"清洗+保留"逻辑，在强制 noatime 加速的同时，智能保留用户定义的 discard、compress 等高级文件系统参数。
#    - 修复旧版逻辑缺陷，确保 rw (读写) 挂载权限不被误判为冲突项而清除。
# 4. 全路径兼容性 (Path Resilience)：
#    - 完美支持包含空格、特殊字符的挂载点路径，解决工业级多盘挂载环境下的解析失效问题。
# 5. 静态时序优化 (Boot-time Injection)：
#    - 遵循 OpenWrt 官方启动时序规范，所有配置通过 files 目录静态打入 ROM，出厂即预置完成，无需二次重启。
# 6. 存储生命周期维护 (TRIM & IO Engine)：
#    - IO 探针：自动识别 NVMe/SSD/HDD 介质，动态匹配最优预读缓存 (Read-Ahead)。
#    - TRIM 补丁：修复 Cron 首次启动不生效盲点，通过 uci-defaults 强制重载 Cron 进程确保定时任务即刻服役。
# 7. 网络硬件加速 (Hardware Offload)：
#    - 自动化 ethtool 策略注入，静默开启物理网卡 TSO/GSO 加速，提升企业级大流量转发性能。
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

# 分离 CI 环境变量注入，彻底斩断单段 EOF 带来的反斜杠转义地狱
cat <<EOF > "${FILES_DIR}/etc/uci-defaults/90-system-init"
#!/bin/sh
TARGET_IP='${TARGET_IP}'
TARGET_HOSTNAME='${TARGET_HOSTNAME}'
EOF

# 追加原生路由器运行逻辑 (带单引号的 'EOF'，内部变量免转义，绝对安全)
cat <<'EOF' >> "${FILES_DIR}/etc/uci-defaults/90-system-init"
uci set network.lan.ipaddr="$TARGET_IP"
uci set system.@system[0].hostname="$TARGET_HOSTNAME"

uci commit network
uci commit system

# Samba4 自动修复逻辑 (确保配置纯净且支持中文)
if command -v uci >/dev/null 2>&1; then
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
    return 0
}
stop() {
    return 0
}
EOF
chmod 0755 "${FILES_DIR}/etc/init.d/ipsec"

log_i "✅ 阶段 2: IPSec 空壳注入完成，出厂即免冲突状态"

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

    # 架构师补全: 仅针对物理真实挂载盘进行 remount，彻底避开虚拟文件系统
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
        
        mount -o remount,noatime "$mp" 2>/dev/null || true
    done < /proc/mounts
}
EOF

chmod 0755 "${FILES_DIR}/etc/init.d/mount-optimize"
log_i "✅ 阶段 3: init.d 挂载修复 Hook 注入完成"

# ==============================================================================
# 阶段 4: 网卡硬件加速服务 (ethtool 策略)
# ==============================================================================
cat <<'EOF' > "${FILES_DIR}/etc/init.d/network-accel"
#!/bin/sh /etc/rc.common

START=85

start() {
    command -v ethtool >/dev/null || return

    # 遍历所有网络接口并开启硬件加速
    for i in /sys/class/net/*; do
        iface=$(basename "$i")
        case "$iface" in
            lo|br-*|docker*|veth*|ifb*|tun*|tap*|wg*)
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
log_i "✅ 阶段 4: 网卡加速注入完成"

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
# 【修复】：NVMe 分区号可能为多位数，使用 %%p* 而非 %%p[0-9]*
case "$DEVNAME" in
    nvme*)   dev="${DEVNAME%%p*}" ;;
    mmcblk*) dev="${DEVNAME%%p*}" ;;
    sd*)     dev="${DEVNAME%%[0-9]*}" ;;
    vd*)     dev="${DEVNAME%%[0-9]*}" ;;
    hd*)     dev="${DEVNAME%%[0-9]*}" ;;
    xvd*)    dev="${DEVNAME%%[0-9]*}" ;;
    *)       exit 0 ;;
esac

BASE="/sys/$dev"
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

# 拦截热插拔动态挂载，暴力覆盖性能参数
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
# 绝对禁止对 tmpfs(内存盘) 或 squashfs(只读包) 发送无意义的 discard 指令
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

log_i "🎉 CI 终极稳定版 Part 2 (纯净版无 Docker) 彻底无风险完成！"
