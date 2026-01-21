#!/bin/bash
# Description: OpenWrt DIY script part 1 (Before Update feeds)

# 1. 添加 PassWall 源 (使用 xiaorouji 源，目前最稳定)
# 注意：使用 >> 追加，不要用 > 覆盖！
echo 'src-git passwall https://github.com/Openwrt-Passwall/openwrt-passwall' >> feeds.conf.default
echo 'src-git passwall_packages passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages' >> feeds.conf.default

# 2. 如果你想用 helloworld (SSR-Plus)，可以解开下面注释，但建议 passwall 和 ssr-plus 二选一
# echo 'src-git helloworld https://github.com/fw876/helloworld' >> feeds.conf.default
