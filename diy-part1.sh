#!/bin/bash
# Description: OpenWrt DIY script part 1 (Before Update feeds)

# 1. 关键步骤：先删除所有包含 passwall 的旧行 (防止重复和格式错误)
sed -i '/passwall/d' feeds.conf.default
sed -i '/helloworld/d' feeds.conf.default

# 2. 重新添加正确的 PassWall 源 (xiaorouji 源，包含 app 和 packages)
echo 'src-git passwall passwall https://github.com/Openwrt-Passwall/openwrt-passwall' >> feeds.conf.default
echo 'src-git passwall_packages passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages' >> feeds.conf.default

# 3. (可选) 如果你需要 SSR-Plus，可以使用下面这行，但通常 PassWall 足够了
# echo 'src-git helloworld https://github.com/fw876/helloworld' >> feeds.conf.default
