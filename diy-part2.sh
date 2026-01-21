#!/bin/bash
# Description: OpenWrt DIY script part 2 (After Update feeds)

# 1. 修改默认 IP 为 192.168.5.1
sed -i 's/192.168.1.1/192.168.5.1/g' package/base-files/files/bin/config_generate

# 2. 修改主机名 (可选)
sed -i 's/OpenWrt/LEDE/g' package/base-files/files/bin/config_generate

# 3. 修复可能出现的 SmartDNS 冲突 (如果有)
# 这一步通常不需要，但如果你编译报错 po2lmo 错误，可以手动处理，目前 LEDE 已修复。
