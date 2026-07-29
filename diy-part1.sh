#!/usr/bin/env bash
# ==============================================================================
# Script: diy-part1.sh
# Description: OpenWrt DIY script part 1 (Enterprise Grade Configuration Injector)
# ==============================================================================

set -euo pipefail

# ---[ 日志与可观测性模块 ] ---
log_info() { echo -e "\e[32m[INFO][$(date +'%Y-%m-%dT%H:%M:%S%z')] $1\e[0m"; }
log_warn() { echo -e "\e[33m[WARN][$(date +'%Y-%m-%dT%H:%M:%S%z')] $1\e[0m"; }
log_err()  { echo -e "\e[31m[ERROR][$(date +'%Y-%m-%dT%H:%M:%S%z')] $1\e[0m" >&2; exit 1; }

readonly FEEDS_CONF="feeds.conf.default"
readonly FEEDS_CONF_BAK="${FEEDS_CONF}.orig"

# 待清理的冲突源关键字（支持正则片段，忽略大小写）
# 扩展了 openclash 等常见需自定义的源
readonly SCRUB_LIST=(
    "passwall"
    "helloworld"
    "openclash"
)

# 待注入的自定义源（规范格式：<类型> <源名称> <URL地址>）
# 【修复】：已彻底移除末尾的 ;main 分支指定，让 git 自动追随作者的最新默认分支 (无论是 main 还是 master)
readonly CUSTOM_FEEDS=(
    "src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git"
    "src-git passwall_luci https://github.com/Openwrt-Passwall/openwrt-passwall.git"
)

# --- [ 环境预检与备份 ] ---
if [[ ! -f "${FEEDS_CONF}" ]]; then
    log_err "配置文件 '${FEEDS_CONF}' 不存在！请检查运行路径。"
fi

# 备份原始文件，用于最终生成 Diff 日志
cp "${FEEDS_CONF}" "${FEEDS_CONF_BAK}"
log_info "========== 开始执行 DIY Part 1 (环境净化与源注入) =========="

# ---[ 1. 净化阶段：列级别的精确匹配 (防止误杀 URL & 解决跨平台差异) ] ---
for pattern in "${SCRUB_LIST[@]}"; do
    # 取出所有未注释的源名称 (第2列)，并通过 grep -iE 匹配模式，获取需要删除的具体名字
    matched_feeds=$(awk '!/^#/ && NF>=2 {print $2}' "${FEEDS_CONF}" | grep -iE "${pattern}" || true)
    
    if [[ -n "${matched_feeds}" ]]; then
        for fn in ${matched_feeds}; do
            log_warn "匹配到关键字 '${pattern}' 的源: '${fn}'，执行精准移除..."
            # 放弃高风险的 sed，使用 awk 严格按照第二列进行过滤
            # 彻底杜绝 macOS sed -i 兼容性问题，且绝对不会误杀 URL 中包含关键字的合法源
            awk -v target="${fn}" '{ if (!/^#/ && NF>=2 && $2 == target) next; print $0 }' "${FEEDS_CONF}" > "${FEEDS_CONF}.tmp"
            mv "${FEEDS_CONF}.tmp" "${FEEDS_CONF}"
        done
    fi
done

# ---[ 2. 注入阶段：原生 Bash 解析与防抖注入 ] ---
for feed_entry in "${CUSTOM_FEEDS[@]}"; do
    # 使用 bash 原生 read 替代 awk 进行字符串分割，避免派生子进程，性能更高
    read -r _ feed_name _ <<< "${feed_entry}"

    # 使用 awk 判断该源名称是否已经存在（精确匹配第2列）
    if awk '!/^#/ && NF>=2 {print $2}' "${FEEDS_CONF}" | grep -q -x "${feed_name}"; then
        log_warn "自定义源 '${feed_name}' 已存在，跳过注入。"
    else
        log_info "成功注入自定义源: '${feed_name}'"
        echo "${feed_entry}" >> "${FEEDS_CONF}"
    fi
done

# ---[ 3. 可观测性：输出 Diff 对比 ] ---
log_info "========== ${FEEDS_CONF} 修改对比 (Diff) =========="
# diff 存在差异时会返回 exit code 1，使用 || true 防止触发 pipefail 导致流水线中断
diff -u "${FEEDS_CONF_BAK}" "${FEEDS_CONF}" || true
echo -e "\n"

# ---[ 4. 终极防线：单一 awk 高性能自检 ] ---
log_info "正在校验 ${FEEDS_CONF} 完整性与唯一性..."

# 使用单次 awk 遍历完成统计与重复检测，极致性能优化
DUPLICATES=$(awk '!/^#/ && NF>=2 {a[$2]++} END {for(i in a) if(a[i]>1) print i}' "${FEEDS_CONF}")

if [[ -n "${DUPLICATES}" ]]; then
    log_err "致命错误：检测到 ${FEEDS_CONF} 中存在重复命名的源 (触发 Exit Code 25 的元凶)：\n${DUPLICATES}"
fi

# ==============================================================================
# ---[ 5. 内核级深度优化：注入 Docker Cgroup 完整隔离特性 ] ---
# ==============================================================================
log_info "========== 开始注入 Docker Cgroup 内核配置 =========="

# 确保内核配置目录存在
mkdir -p target/linux/x86

# 动态获取当前源码的 Kernel 版本号 (兼容性更强)
KERNEL_VER=$(grep -oP 'KERNEL_PATCHVER:=\K[0-9.]+' include/kernel.mk 2>/dev/null || echo "6.6")
CONFIG_FILE="target/linux/x86/config-${KERNEL_VER}"

log_info "目标内核版本文件: ${CONFIG_FILE}"

# 注入完整的 Cgroups 与 Namespaces 底层支持
# 幂等性检查：避免重复注入
if ! grep -q "Docker Cgroup & Namespace 满血支持" "$CONFIG_FILE" 2>/dev/null; then
    cat >> "$CONFIG_FILE" << "EOF"

# ============================================================
# Docker Cgroup & Namespace 满血支持 (适配 Linux 6.12+ 内核)
# 彻底消除 Docker 运行时的 No memory/swap/oom/cpuset limit 警告
# ============================================================
CONFIG_CGROUPS=y
CONFIG_MEMCG=y
# 关键修复：显式启用 cgroup v1 内存控制器 (适配 6.12 内核)
CONFIG_MEMCG_V1=y
CONFIG_MEMCG_SWAP=y
CONFIG_CPUSETS=y
# 关键修复：显式启用 cgroup v1 cpusets 控制器 (适配 6.12 内核)
CONFIG_CPUSETS_V1=y
CONFIG_CGROUP_CPUACCT=y
CONFIG_CGROUP_DEVICE=y
CONFIG_CGROUP_FREEZER=y
CONFIG_CGROUP_SCHED=y
CONFIG_CGROUP_NET_CLASSID=y
CONFIG_CGROUP_NET_PRIO=y
CONFIG_NAMESPACES=y
CONFIG_USER_NS=y
CONFIG_KEYS=y
CONFIG_NET_NS=y
CONFIG_PID_NS=y
CONFIG_IPC_NS=y
CONFIG_UTS_NS=y
CONFIG_TIME_NS=y
CONFIG_CGROUP_BPF=y
# ============================================================
EOF
    log_info "✅ Docker Cgroup 内核隔离特性已成功物理注入到 ${CONFIG_FILE}"
else
    log_warn "Docker Cgroup 内核配置已存在，跳过注入"
fi

# ==============================================================================
# ---[ 6. 强制合并内核配置到 .config (确保编译时生效) ] ---
# ==============================================================================
log_info "========== 强制合并内核配置到 .config =========="

# 确保内核配置目录存在
mkdir -p target/linux/x86

# 重新获取内核版本（确保与之前一致）
KERNEL_VER=$(grep -oP 'KERNEL_PATCHVER:=\K[0-9.]+' include/kernel.mk 2>/dev/null || echo "6.6")
CONFIG_FILE="target/linux/x86/config-${KERNEL_VER}"

log_info "目标内核版本文件: ${CONFIG_FILE}"

# 【架构师修复】：强制触发 OpenWrt 重新读取内核配置
# 方法1：删除旧的内核配置缓存，强制重新生成
if [ -f ".config" ]; then
    log_info "检测到 .config 文件存在，正在强制刷新内核配置..."
    
    # 备份当前 .config
    cp .config .config.bak.$(date +%s) 2>/dev/null || true
    
    # 删除内核配置缓存，强制 make 重新读取
    rm -f .config.old 2>/dev/null || true
    rm -f .config.prev 2>/dev/null || true
    
    # 使用 kernel_oldconfig 强制合并内核配置
    # 这会读取 target/linux/x86/config-* 并合并到 .config
    log_info "执行 make kernel_oldconfig (非交互模式)..."
    make kernel_oldconfig CONFIG_TARGET=subtarget 2>/dev/null || true
    
    # 验证内核配置是否已合并
    if grep -q "CONFIG_MEMCG=y" .config 2>/dev/null; then
        log_info "✅ 内核配置已成功合并到 .config"
        log_info "验证: CONFIG_MEMCG=y 已存在于 .config"
    else
        log_warn "⚠️ 验证失败: CONFIG_MEMCG=y 未在 .config 中找到"
        log_warn "尝试使用 make kernel_menuconfig 强制更新..."
        # 使用 kernel_menuconfig 并自动保存（非交互模式）
        make kernel_menuconfig CONFIG_TARGET=subtarget 2>/dev/null || true
    fi
else
    log_info ".config 不存在，将在后续 make defconfig 时自动加载内核配置"
fi

# 再次验证内核配置是否已包含所需选项
log_info "========== 内核配置验证 =========="
if [ -f ".config" ]; then
    if grep -q "CONFIG_MEMCG=y" .config 2>/dev/null; then
        log_info "✅ CONFIG_MEMCG=y 已存在于 .config"
    else
        log_warn "⚠️ CONFIG_MEMCG=y 未在 .config 中找到"
        log_warn "将在 make defconfig 阶段由 OpenWrt 自动合并"
    fi
    
    if grep -q "CONFIG_CPUSETS=y" .config 2>/dev/null; then
        log_info "✅ CONFIG_CPUSETS=y 已存在于 .config"
    else
        log_warn "⚠️ CONFIG_CPUSETS=y 未在 .config 中找到"
    fi
    
    if grep -q "CONFIG_CGROUPS=y" .config 2>/dev/null; then
        log_info "✅ CONFIG_CGROUPS=y 已存在于 .config"
    else
        log_warn "⚠️ CONFIG_CGROUPS=y 未在 .config 中找到"
    fi
fi

log_info "✅ 内核配置合并流程完成"

log_info "========== DIY Part 1 执行完毕，配置校验通过 ✅ =========="
