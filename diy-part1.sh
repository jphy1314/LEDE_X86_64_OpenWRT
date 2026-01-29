#!/bin/bash
# Description: OpenWrt DIY script part 1 (Before Update feeds)

# 1. 移除可能存在的冲突源 (清理 Lean 源码中可能自带的旧 Passwall 引用)
sed -i '/passwall/d' feeds.conf.default
sed -i '/helloworld/d' feeds.conf.default

# 2. 添加 PassWall 源 (必须两个都加：packages 是依赖，passwall 是主程序)
echo 'src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main' >> feeds.conf.default
echo 'src-git passwall_luci https://github.com/Openwrt-Passwall/openwrt-passwall.git;main' >> feeds.conf.default
