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

# 待清理的冲突源关键字 (防御未来上游合并引发的包冲突)
readonly SCRUB_LIST=(
    "passwall"
    "luci-app-passwall"
    "openclash"
    "luci-app-openclash"
    "helloworld"
    "homeproxy"
    "nikki"
    "mosdns"
    "luci-theme-argon"
    "argon" # 补全简写防御
)

# 待注入的自定义源 (已彻底移除末尾的 ;main 分支指定，采用默认分支)
readonly CUSTOM_FEEDS=(
    "src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git"
    "src-git passwall_luci https://github.com/Openwrt-Passwall/openwrt-passwall.git"
)

if [[ ! -f "${FEEDS_CONF}" ]]; then
    log_err "配置文件 '${FEEDS_CONF}' 不存在！请检查运行路径。"
fi

cp "${FEEDS_CONF}" "${FEEDS_CONF_BAK}"
log_info "========== 开始执行 DIY Part 1 (环境净化与源注入) =========="

# ---[ 1. 净化阶段：列级别的精确匹配 ] ---
for pattern in "${SCRUB_LIST[@]}"; do
    matched_feeds=$(awk '!/^#/ && NF>=2 {print $2}' "${FEEDS_CONF}" | grep -iE "(^|[-_])${pattern}([-_]|$)" || true)
    if [[ -n "${matched_feeds}" ]]; then
        for fn in ${matched_feeds}; do
            log_warn "匹配到关键字 '${pattern}' 的源: '${fn}'，执行精准移除..."
            awk -v target="${fn}" '{ if (!/^#/ && NF>=2 && $2 == target) next; print $0 }' "${FEEDS_CONF}" > "${FEEDS_CONF}.tmp"
            mv "${FEEDS_CONF}.tmp" "${FEEDS_CONF}"
        done
    fi
done

# ---[ 2. 注入阶段：防抖注入 ] ---
for feed_entry in "${CUSTOM_FEEDS[@]}"; do
    read -r _ feed_name _ <<< "${feed_entry}"
    if awk '!/^#/ && NF>=2 {print $2}' "${FEEDS_CONF}" | grep -q -x "${feed_name}"; then
        log_warn "自定义源 '${feed_name}' 已存在，跳过注入。"
    else
        log_info "成功注入自定义源: '${feed_name}'"
        echo "${feed_entry}" >> "${FEEDS_CONF}"
    fi
done

log_info "========== ${FEEDS_CONF} 修改对比 (Diff) =========="
diff -u "${FEEDS_CONF_BAK}" "${FEEDS_CONF}" || true
echo -e "\n"

log_info "正在校验 ${FEEDS_CONF} 完整性与唯一性..."
DUPLICATES=$(awk '!/^#/ && NF>=2 {a[$2]++} END {for(i in a) if(a[i]>1) print i}' "${FEEDS_CONF}")
if [[ -n "${DUPLICATES}" ]]; then
    log_err "致命错误：检测到 ${FEEDS_CONF} 中存在重复命名的源：\n${DUPLICATES}"
fi

# 非 DEBUG 模式下自动清理备份文件
[[ -z "${DEBUG:-}" ]] && rm -f "${FEEDS_CONF_BAK}"

log_info "========== DIY Part 1 执行完毕，配置校验通过 ✅ =========="
