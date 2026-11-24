#!/bin/bash
# 把 SL-3000 eMMC（MT7981B，1GB RAM / 32MB NOR + 128GB eMMC）注入 ImmortalWrt 25.12。
#
# 采用 25.12 适配版 DTS（mt7981b.dtsi + root=PARTLABEL=rootfs + eMMC block-device），
# 不是 24.10 的 mt7981.dtsi 版本。
#
# 网口：MT7531 switch
#   port@0 lan1 / port@1 lan2 / port@2 lan3 / port@3 wan / port@6 cpu
#   → 02_network: lan1 lan2 lan3 + wan
#
# 无线：factory 分区 eeprom_factory_0 校准；首启双频 AP（SL3000-2.4G / SL3000-5G），
#   再由 99-wifi-boost 做 CN / HE160 / HE40 / 802.11k v r。
set -euo pipefail

TSRC='.github/sl3000/dts'
DTS='target/linux/mediatek/dts/mt7981b-sl-3000-emmc.dts'
MK='target/linux/mediatek/image/filogic.mk'
NW='target/linux/mediatek/filogic/base-files/etc/board.d/02_network'
MAC='target/linux/mediatek/filogic/base-files/etc/hotplug.d/ieee80211/11_fix_wifi_mac'
PS='target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh'

[ -f "$MK" ] || { echo "::error::当前目录不是 ImmortalWrt 源码树（缺 $MK）"; exit 1; }
[ -f "$TSRC/mt7981b-sl-3000-emmc.dts" ] || { echo "::error::缺 SL3000 DTS 源文件"; exit 1; }
mkdir -p target/linux/mediatek/dts
cp -f "$TSRC/mt7981b-sl-3000-emmc.dts" "$DTS"
echo "✔ SL3000 DTS 已落位"

# ---------------------------------------------------------------------------
# 1) filogic.mk：追加 sl_3000-emmc
# ---------------------------------------------------------------------------
python3 - <<'PYEOF'
import io
p='target/linux/mediatek/image/filogic.mk'
s=io.open(p,encoding='utf-8',newline='').read()
MARK='# === sl3000-emmc device ==='
if MARK in s:
    print('filogic.mk: sl3000-emmc 已存在，跳过')
else:
    block=r'''
# === sl3000-emmc device ===
# SL-3000 eMMC（MT7981B）：eMMC 128GB，root=PARTLABEL=rootfs；MT7531 lan1-3 + wan
define Device/sl_3000-emmc
  DEVICE_VENDOR := SL
  DEVICE_MODEL := 3000 eMMC
  DEVICE_DTS := mt7981b-sl-3000-emmc
  DEVICE_DTS_DIR := ../dts
  SUPPORTED_DEVICES := sl,3000-emmc
  DEVICE_PACKAGES := e2fsprogs f2fsck mkf2fs kmod-usb3 kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware luci-app-store luci-i18n-base-zh-cn
  KERNEL := kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
  KERNEL_INITRAMFS := kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += sl_3000-emmc
'''
    s=s+block
    io.open(p,'w',encoding='utf-8',newline='').write(s)
    print('filogic.mk: 已追加 sl3000-emmc')
final=io.open(p,encoding='utf-8',newline='').read()
assert 'define Device/sl_3000-emmc\n' in final
assert 'TARGET_DEVICES += sl_3000-emmc\n' in final
blk=final[final.index('define Device/sl_3000-emmc'):final.index('TARGET_DEVICES += sl_3000-emmc')]
for token in ('kmod-mt7915e','kmod-mt7981-firmware','mt7981-wo-firmware','luci-app-store','luci-i18n-base-zh-cn'):
    assert token in blk, 'DEVICE_PACKAGES 缺 '+token
assert 'IMAGE/sysupgrade.bin' in blk
print('✔ filogic.mk 校验通过')
PYEOF

# ---------------------------------------------------------------------------
# 2) 02_network：LAN/WAN + MAC
# ---------------------------------------------------------------------------
python3 - <<'PYEOF'
import io
p='target/linux/mediatek/filogic/base-files/etc/board.d/02_network'
s=io.open(p,encoding='utf-8',newline='').read()
MARK='\t# === sl3000-emmc network ===\n'
if MARK not in s:
    # interfaces: insert into first case after mediatek_setup_interfaces()
    f=s.index('mediatek_setup_interfaces()')
    pos=s.index('\tcase $board in\n',f)
    block=MARK+'''\tsl,3000-emmc)
\t\tucidef_set_interfaces_lan_wan "lan1 lan2 lan3" wan
\t\t;;
'''
    s=s[:pos+len('\tcase $board in\n')]+block+s[pos+len('\tcase $board in\n'):]
    # mac: insert into first case after mediatek_setup_macs()
    f=s.index('mediatek_setup_macs()')
    pos=s.index('\tcase $board in\n',f)
    macblock='\t# === sl3000-emmc mac ===\n'+'''\tsl,3000-emmc)
\t\tlan_mac=$(mmc_get_mac_binary factory 0x04)
\t\twan_mac=$(macaddr_add $lan_mac -2)
\t\tlabel_mac=$wan_mac
\t\t;;
'''
    s=s[:pos+len('\tcase $board in\n')]+macblock+s[pos+len('\tcase $board in\n'):]
    io.open(p,'w',encoding='utf-8',newline='').write(s)
    print('02_network: 已插入 SL3000 网口与 MAC')
final=io.open(p,encoding='utf-8',newline='').read()
assert 'ucidef_set_interfaces_lan_wan "lan1 lan2 lan3" wan' in final
assert 'mmc_get_mac_binary factory 0x04' in final
print('✔ 02_network 校验通过')
PYEOF

# ---------------------------------------------------------------------------
# 3) 11_fix_wifi_mac：双频 MAC 从 eMMC factory 0x04 派生
# ---------------------------------------------------------------------------
python3 - <<'PYEOF'
import io
p='target/linux/mediatek/filogic/base-files/etc/hotplug.d/ieee80211/11_fix_wifi_mac'
s=io.open(p,encoding='utf-8',newline='').read()
MARK='\t# === sl3000-emmc wifi mac ===\n'
if MARK not in s:
    anchor='case "$board" in\n'
    assert anchor in s
    block=MARK+'''\tsl,3000-emmc)
\t\taddr=$(mmc_get_mac_binary factory 0x04)
\t\t[ "$PHYNBR" = "0" ] && macaddr_add $addr 1 > /sys${DEVPATH}/macaddress
\t\t[ "$PHYNBR" = "1" ] && macaddr_add $addr 2 > /sys${DEVPATH}/macaddress
\t\t;;
'''
    s=s.replace(anchor,anchor+block,1)
    io.open(p,'w',encoding='utf-8',newline='').write(s)
    print('11_fix_wifi_mac: 已插入 SL3000 规则')
final=io.open(p,encoding='utf-8',newline='').read()
assert 'sl,3000-emmc' in final
print('✔ 11_fix_wifi_mac 校验通过')
PYEOF

# ---------------------------------------------------------------------------
# 4) platform.sh：把 sl,3000-emmc 加入 eMMC 升级/复制配置组
# ---------------------------------------------------------------------------
python3 - <<'PYEOF'
import io
p='target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh'
s=io.open(p,encoding='utf-8',newline='').read()
anchor='\thuasifei,wh3000-pro-emmc|\\\n'
assert s.count(anchor) >= 1
if '\tsl,3000-emmc|\\\n' not in s:
    s=s.replace(anchor,anchor+'\tsl,3000-emmc|\\\n')
    io.open(p,'w',encoding='utf-8',newline='').write(s)
    print('platform.sh: 已加入 SL3000 eMMC 路由')
final=io.open(p,encoding='utf-8',newline='').read()
assert final.count('\tsl,3000-emmc|') >= 1
print('✔ platform.sh 校验通过')
PYEOF

# ---------------------------------------------------------------------------
# 5) 双频无线默认配置
# ---------------------------------------------------------------------------
mkdir -p files/etc/config
cat > files/etc/config/wireless <<'EOF'

config wifi-device 'radio0'
	option type 'mac80211'
	option path 'platform/soc/18000000.wifi'
	option band '2g'
	option channel 'auto'
	option htmode 'HE40'
	option country 'CN'
	option ieee80211d '1'
	option cell_density '0'
	option disabled '0'

config wifi-iface 'default_radio0'
	option device 'radio0'
	option network 'lan'
	option mode 'ap'
	option ssid 'SL3000-2.4G'
	option encryption 'none'

config wifi-device 'radio1'
	option type 'mac80211'
	option path 'platform/soc/18000000.wifi+1'
	option band '5g'
	option channel 'auto'
	option htmode 'HE160'
	option country 'CN'
	option ieee80211d '1'
	option cell_density '0'
	option disabled '0'

config wifi-iface 'default_radio1'
	option device 'radio1'
	option network 'lan'
	option mode 'ap'
	option ssid 'SL3000-5G'
	option encryption 'none'
EOF
chmod 644 files/etc/config/wireless
echo "✔ 双频无线配置已落位（SL3000-2.4G / SL3000-5G）"

# ---------------------------------------------------------------------------
# 6) 硬校验
# ---------------------------------------------------------------------------
grep -q 'compatible = "sl,3000-emmc"' "$DTS" || { echo "::error::DTS compatible 不对"; exit 1; }
grep -q 'root=PARTLABEL=rootfs' "$DTS" || { echo "::error::DTS 缺 eMMC rootfs 参数"; exit 1; }
grep -q 'compatible = "block-device"' "$DTS" || { echo "::error::DTS 缺 eMMC block-device"; exit 1; }
grep -q 'block-partition-factory' "$DTS" || { echo "::error::DTS 缺 factory 分区"; exit 1; }
grep -q 'eeprom_factory_0' "$DTS" || { echo "::error::DTS 缺 WiFi 校准"; exit 1; }
grep -q 'label = "lan3"' "$DTS" && grep -q 'label = "wan"' "$DTS" || { echo "::error::DTS 端口标签不全"; exit 1; }
grep -q 'reset-gpios = <&pio 39' "$DTS" || { echo "::error::DTS switch reset GPIO 不对"; exit 1; }

grep -q 'sl,3000-emmc' "$NW" || { echo "::error::02_network 缺 SL3000"; exit 1; }
grep -q 'ucidef_set_interfaces_lan_wan "lan1 lan2 lan3" wan' "$NW" || { echo "::error::SL3000 网口映射不对"; exit 1; }
grep -q 'sl,3000-emmc' "$MAC" || { echo "::error::WiFi MAC 规则缺失"; exit 1; }
grep -q 'sl,3000-emmc' "$PS" || { echo "::error::platform.sh 缺 SL3000 eMMC 路由"; exit 1; }

test -f files/etc/config/wireless || { echo "::error::无线配置缺失"; exit 1; }
grep -q "option ssid 'SL3000-2.4G'" files/etc/config/wireless || { echo "::error::缺 2.4G AP"; exit 1; }
grep -q "option ssid 'SL3000-5G'" files/etc/config/wireless || { echo "::error::缺 5G AP"; exit 1; }
grep -q "option disabled '0'" files/etc/config/wireless || { echo "::error::无线仍 disabled"; exit 1; }

echo "✔ SL3000 注入完成（eMMC / lan1-3+wan / 双频 WiFi / iStore+中文）"
