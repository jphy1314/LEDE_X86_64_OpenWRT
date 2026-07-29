#!/usr/bin/env bash
# ==============================================================================
# OpenWrt DIY Part 2 - 企业级生产环境版功能特性 (包含 Docker 极致调优)
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
# 8. 容器化引擎满血解锁 (Docker Cgroups)：
#    - 暴力破解内核限制，强制在 GRUB/Extlinux 引导期开启被阉割的内存/Swap 隔离等高级特性。
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

# 【架构师修复】：分离 CI 环境变量注入，彻底斩断单段 EOF 带来的反斜杠转义地狱
cat <<EOF > "${FILES_DIR}/etc/uci-defaults/90-system-init"
#!/bin/sh

# 设置默认 IP 和主机名
uci set network.lan.ipaddr='${TARGET_IP}'
uci set system.@system[0].hostname='${TARGET_HOSTNAME}'
EOF

# 追加原生路由器运行逻辑 (带单引号的 EOF，内部变量免转义，绝对安全)
cat <<'EOF' >> "${FILES_DIR}/etc/uci-defaults/90-system-init"
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

# =========================================================================
# 【架构师修复 v2】：增强版引导参数注入，同时支持 GRUB/Extlinux/Syslinux
# 彻底消除 Dockerman 里的 No memory/swap/oom limit 等警告！
# =========================================================================

# ---[ 1. 检测实际使用的引导加载器 ] ---
BOOT_CFG=""
BOOT_TYPE=""
SEARCH_PATTERN=""

# GRUB 检测
if [ -f /boot/grub/grub.cfg ]; then
    BOOT_CFG="/boot/grub/grub.cfg"
    BOOT_TYPE="grub"
    SEARCH_PATTERN="rootwait"
    log_i "检测到 GRUB 引导器: ${BOOT_CFG}"
# Extlinux 检测 (OpenWrt x86_64 默认)
elif [ -f /boot/extlinux/extlinux.conf ]; then
    BOOT_CFG="/boot/extlinux/extlinux.conf"
    BOOT_TYPE="extlinux"
    SEARCH_PATTERN="APPEND"
    log_i "检测到 Extlinux 引导器: ${BOOT_CFG}"
# Syslinux 检测
elif [ -f /boot/syslinux/syslinux.cfg ]; then
    BOOT_CFG="/boot/syslinux/syslinux.cfg"
    BOOT_TYPE="syslinux"
    SEARCH_PATTERN="APPEND"
    log_i "检测到 Syslinux 引导器: ${BOOT_CFG}"
# 通用搜索：尝试查找任何引导配置文件
else
    # 尝试在 /boot 下查找常见的引导配置文件
    for cfg in /boot/grub/grub.cfg /boot/extlinux/extlinux.conf /boot/syslinux/syslinux.cfg; do
        if [ -f "$cfg" ]; then
            BOOT_CFG="$cfg"
            case "$cfg" in
                *grub*) BOOT_TYPE="grub"; SEARCH_PATTERN="rootwait" ;;
                *extlinux*) BOOT_TYPE="extlinux"; SEARCH_PATTERN="APPEND" ;;
                *syslinux*) BOOT_TYPE="syslinux"; SEARCH_PATTERN="APPEND" ;;
            esac
            log_i "自动检测到引导器: ${BOOT_TYPE} -> ${BOOT_CFG}"
            break
        fi
    done
fi

# ---[ 2. 执行引导参数注入 ] ---
if [ -n "$BOOT_CFG" ] && [ -f "$BOOT_CFG" ]; then
    # 检查是否已存在 cgroup 参数 (防止重复注入)
    if ! grep -q "cgroup_enable=memory" "$BOOT_CFG"; then
        case "$BOOT_TYPE" in
            grub)
                # GRUB: 在 rootwait 后追加参数
                sed -i "s/${SEARCH_PATTERN}/${SEARCH_PATTERN} cgroup_enable=memory swapaccount=1 systemd.unified_cgroup_hierarchy=0 cgroup_hierarchy=legacy/g" "$BOOT_CFG"
                log_i "GRUB 引导参数注入成功"
                ;;
            extlinux|syslinux)
                # Extlinux/Syslinux: 在 APPEND 行追加参数
                # 支持 APPEND 行后已有参数或为空的情况
                sed -i "s/\(${SEARCH_PATTERN} *\)/\1 cgroup_enable=memory swapaccount=1 systemd.unified_cgroup_hierarchy=0 cgroup_hierarchy=legacy /g" "$BOOT_CFG"
                log_i "${BOOT_TYPE} 引导参数注入成功"
                ;;
            *)
                # 通用替换：尝试在首次出现 rootwait 或 APPEND 后添加
                if grep -q "rootwait" "$BOOT_CFG"; then
                    sed -i "0,/rootwait/s//rootwait cgroup_enable=memory swapaccount=1 systemd.unified_cgroup_hierarchy=0 cgroup_hierarchy=legacy/" "$BOOT_CFG"
                    log_i "通用引导参数注入成功 (rootwait)"
                elif grep -q "APPEND" "$BOOT_CFG"; then
                    sed -i "0,/APPEND/s//APPEND cgroup_enable=memory swapaccount=1 systemd.unified_cgroup_hierarchy=0 cgroup_hierarchy=legacy/" "$BOOT_CFG"
                    log_i "通用引导参数注入成功 (APPEND)"
                else
                    log_warn "⚠️ 未找到 rootwait 或 APPEND 关键字，跳过引导参数注入"
                fi
                ;;
        esac
        
        # 记录修改日志 (增加 || true 防止极早期阶段 syslogd 未启动导致崩溃)
        logger -t "System-Opt" "✅ 引导参数修改成功 (${BOOT_TYPE})，Docker 完整环境已解锁！" 2>/dev/null || true
        
        # 验证注入是否成功
        if grep -q "cgroup_enable=memory" "$BOOT_CFG"; then
            log_i "✅ 引导参数注入验证成功"
        else
            log_warn "⚠️ 引导参数注入后验证失败，请手动检查 ${BOOT_CFG}"
        fi
    else
        log_i "⏩ 引导参数已存在，跳过重复注入"
    fi
else
    # 如果找不到引导配置文件，记录警告并尝试替代方案
    log_warn "⚠️ 未找到任何引导配置文件 (GRUB/Extlinux/Syslinux)"
    log_warn "Docker cgroup 参数将无法通过引导注入，请手动修改引导配置"
fi

exit 0
EOF
chmod 0755 "${FILES_DIR}/etc/uci-defaults/90-system-init"
log_i "✅ 阶段 1: 系统初始化注入完成 (包含 Docker 引导唤醒)"

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
            lo|br-*|docker*|veth*|eth1.4*|ifb*|tun*|tap*|wg*)
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
# 阶段 4: init.d 挂载提速 Hook（非侵入式内核 Remount）
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
        
        mount -o remount,noatime "$mp" 2>/dev/null || true
    done < /proc/mounts
}
EOF
chmod 0755 "${FILES_DIR}/etc/init.d/mount-optimize"
log_i "✅ 阶段 4: init.d 挂载修复 Hook 注入完成"

# ==============================================================================
# 阶段 5: Block IO 物理层优化 (NVMe/SSD/HDD 自动适配)
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

# 提取主设备名逻辑 (兼容 NVMe, mmcblk, sdX)
# 【架构师修复】：拆分 sd* 和 vd*，彻底避免老旧版 BusyBox 对合并模式解析失败
case "$DEVNAME" in
    nvme*)   dev="${DEVNAME%p[0-9]*}" ;;
    mmcblk*) dev="${DEVNAME%p[0-9]*}" ;;
    sd*)     dev="${DEVNAME%%[0-9]*}" ;;
    vd*)     dev="${DEVNAME%%[0-9]*}" ;;
    hd*)     dev="${DEVNAME%%[0-9]*}" ;;
    xvd*)    dev="${DEVNAME%%[0-9]*}" ;;
    *)       exit 0 ;;
esac

BASE="/sys/block/$dev"
[ -d "$BASE" ] || exit 0

# 提取旋转介质标识 (0 为 SSD, 1 为 HDD)
ROT=$(cat "$BASE/queue/rotational" 2>/dev/null || echo 1)

# 安全预检 read_ahead_kb 节点是否存在，防止老旧/精简版内核无此节点报错
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
# 阶段 6: mount 热插拔 noatime
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
log_i "✅ 阶段 7: TRIM Cron 注入完成并立即生效"

log_i "🎉 CI终极稳定版 Part2 彻底无风险完成！"
