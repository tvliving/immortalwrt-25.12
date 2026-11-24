#!/bin/bash
# 把 5 款 Ruijie 机型注入 ImmortalWrt 25.12：
#   EW-6000GX PRO / RG-X60 New / RG-X30E Pro / RG-X30E / RG-BE72 Pro (DSA mod)
#
# 设计原则：
#   1. DTS 全部放在 .github/ruijie/dts/，构建时复制到 target/linux/mediatek/dts/，
#      不改上游已有 DTS，避免机型之间互相覆盖。
#   2. filogic.mk 只追加本批次 5 个 Device 块；每个块显式带 WiFi 驱动/固件、
#      iStore、简体中文基础包，避免 kconfig 静默丢掉 store。
#   3. 02_network 与 11_fix_wifi_mac 用独立 case 块插入，网口映射一眼可查：
#        EW-6000GX PRO : lan1-4 + eth1(WAN 2.5G)
#        RG-X60 New    : lan1-3 + eth1(WAN 2.5G)
#        X30E / Pro    : lan1-3 + wan
#        BE72 Pro DSA  : lan1-8 + wan
#   4. 每个 matrix job 通过 RU_DEVICE 只校验/写本机型的无线配置，
#      避免“一个 files/ 覆盖所有机型”的路径冲突。
set -euo pipefail

TSRC='.github/ruijie/dts'
MK='target/linux/mediatek/image/filogic.mk'
NW='target/linux/mediatek/filogic/base-files/etc/board.d/02_network'
MAC='target/linux/mediatek/filogic/base-files/etc/hotplug.d/ieee80211/11_fix_wifi_mac'

RU_DEVICE="${RU_DEVICE:?RU_DEVICE 未设置}"
RU_WIFI_MODE="${RU_WIFI_MODE:-path}"          # path | phy
RU_WIFI_2G="${RU_WIFI_2G:-platform/soc/18000000.wifi}"
RU_WIFI_5G="${RU_WIFI_5G:-platform/soc/18000000.wifi+1}"
RU_SSID_2G="${RU_SSID_2G:-ImmortalWrt-2.4G}"
RU_SSID_5G="${RU_SSID_5G:-ImmortalWrt-5G}"

[ -f "$MK" ] || { echo "::error::当前目录不是 ImmortalWrt 源码树（缺 $MK）"; exit 1; }
[ -d "$TSRC" ] || { echo "::error::缺少 $TSRC"; exit 1; }

case "$RU_DEVICE" in
  ruijie_rg-ew6000gx-pro|ruijie_rg-x60-new|ruijie_rg-x30e-pro|ruijie_rg-x30e|ruijie_rg-be72-pro-dsa-mod) ;;
  *) echo "::error::不支持的 RU_DEVICE=$RU_DEVICE"; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# 1) DTS 落位
# ---------------------------------------------------------------------------
cp -f "$TSRC"/*.dts "$TSRC"/*.dtsi target/linux/mediatek/dts/
for f in \
  mt7986a-ruijie-rg-ew6000gx-pro.dts mt7986a-ruijie-rg-ew6000gx-pro.dtsi \
  mt7986a-ruijie-rg-x60-new.dts mt7986a-ruijie-rg-x60-new.dtsi \
  mt7981b-ruijie-rg-x30e-pro.dts mt7981b-ruijie-rg-x30e.dts \
  mt7988d-ruijie-rg-be72-pro-base.dtsi mt7988d-ruijie-rg-be72-pro-dsa-mod.dts; do
  [ -f "target/linux/mediatek/dts/$f" ] || { echo "::error::DTS 落位失败: $f"; exit 1; }
done
echo "✔ 5 款机型 DTS 已落位"

# ---------------------------------------------------------------------------
# 2) filogic.mk 追加 5 个 Device 块
# ---------------------------------------------------------------------------
python3 - <<'PYEOF'
import io

p = 'target/linux/mediatek/image/filogic.mk'
s = io.open(p, encoding='utf-8', newline='').read()
MARK = '# === ruijie-5in1 devices ==='
if MARK in s:
    print('filogic.mk: ruijie-5in1 已存在，跳过')
else:
    BLOCKS = r'''
# === ruijie-5in1 devices ===
# EW-6000GX PRO（MT7986A）：switch lan1-4 + gmac1/eth1 2.5G WAN
define Device/ruijie_rg-ew6000gx-pro
  DEVICE_VENDOR := Ruijie
  DEVICE_MODEL := RG-EW6000GX PRO
  DEVICE_DTS := mt7986a-ruijie-rg-ew6000gx-pro
  DEVICE_DTS_DIR := ../dts
  SUPPORTED_DEVICES += ruijie,rg-ew6000gx-pro
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7986-firmware mt7986-wo-firmware kmod-phy-airoha-en8811h luci-app-store luci-i18n-base-zh-cn
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += ruijie_rg-ew6000gx-pro

# RG-X60 New（MT7986A）：switch lan1-3 + gmac1/eth1 2.5G WAN
define Device/ruijie_rg-x60-new
  DEVICE_VENDOR := Ruijie
  DEVICE_MODEL := RG-X60 New
  DEVICE_DTS := mt7986a-ruijie-rg-x60-new
  DEVICE_DTS_DIR := ../dts
  SUPPORTED_DEVICES += ruijie,rg-x60-new
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7986-firmware mt7986-wo-firmware kmod-phy-airoha-en8811h luci-app-store luci-i18n-base-zh-cn
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += ruijie_rg-x60-new

# RG-X30E Pro（MT7981B）：switch wan/lan1/lan2/lan3
define Device/ruijie_rg-x30e-pro
  DEVICE_VENDOR := Ruijie
  DEVICE_MODEL := RG-X30E Pro
  DEVICE_DTS := mt7981b-ruijie-rg-x30e-pro
  DEVICE_DTS_DIR := ../dts
  SUPPORTED_DEVICES := ruijie,rg-x30e-pro
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware luci-app-store luci-i18n-base-zh-cn
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 114176k
  KERNEL_IN_UBI := 1
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += ruijie_rg-x30e-pro

# RG-X30E（MT7981B）：switch lan1/lan2/lan3/wan
define Device/ruijie_rg-x30e
  DEVICE_VENDOR := Ruijie
  DEVICE_MODEL := RG-X30E
  DEVICE_DTS := mt7981b-ruijie-rg-x30e
  DEVICE_DTS_DIR := ../dts
  SUPPORTED_DEVICES := ruijie,rg-x30e
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware luci-app-store luci-i18n-base-zh-cn
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 114176k
  KERNEL_IN_UBI := 1
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += ruijie_rg-x30e

# RG-BE72 Pro（MT7988D + RTL8372N DSA，U-Boot mod 256M 布局）
define Device/ruijie_rg-be72-pro-dsa-mod
  DEVICE_VENDOR := Ruijie
  DEVICE_MODEL := RG-BE72 Pro
  DEVICE_VARIANT := DSA (U-Boot mod)
  DEVICE_DTS := mt7988d-ruijie-rg-be72-pro-dsa-mod
  DEVICE_DTS_DIR := ../dts
  SUPPORTED_DEVICES := ruijie,rg-be72-pro-dsa-mod
  KERNEL_IN_UBI := 1
  DEVICE_PACKAGES := mt7988-2p5g-phy-firmware kmod-mt7992-23-firmware kmod-mt7992-firmware mt7988-wo-firmware kmod-usb3 automount kmod-dsa-rtl837x luci-app-store luci-i18n-base-zh-cn
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += ruijie_rg-be72-pro-dsa-mod
'''
    s = s + BLOCKS
    io.open(p, 'w', encoding='utf-8', newline='').write(s)
    print('filogic.mk: 已追加 ruijie-5in1 设备块')

final = io.open(p, encoding='utf-8', newline='').read()
for dev in ('ruijie_rg-ew6000gx-pro', 'ruijie_rg-x60-new', 'ruijie_rg-x30e-pro',
            'ruijie_rg-x30e', 'ruijie_rg-be72-pro-dsa-mod'):
    assert 'define Device/' + dev + '\n' in final, '缺少 ' + dev
    assert 'TARGET_DEVICES += ' + dev + '\n' in final, 'TARGET_DEVICES 缺 ' + dev
print('✔ filogic.mk 校验通过（5 个机型）')
PYEOF

# ---------------------------------------------------------------------------
# 3) 02_network：独立 case 块，避免改动上游已有分组
# ---------------------------------------------------------------------------
python3 - <<'PYEOF'
import io

p = 'target/linux/mediatek/filogic/base-files/etc/board.d/02_network'
s = io.open(p, encoding='utf-8', newline='').read()
MARK = '\t# === ruijie-5in1 network ===\n'
if MARK in s:
    print('02_network: ruijie-5in1 已存在，跳过')
else:
    anchor = '\tcase $board in\n'
    pos = s.find(anchor)
    assert pos >= 0, '02_network case 锚点异常'
    block = MARK + '''\truijie,rg-ew6000gx-pro)
\t\tucidef_set_interfaces_lan_wan "lan1 lan2 lan3 lan4" "eth1"
\t\t;;
\truijie,rg-x60-new)
\t\tucidef_set_interfaces_lan_wan "lan1 lan2 lan3" eth1
\t\t;;
\truijie,rg-x30e|\\
\truijie,rg-x30e-pro)
\t\tucidef_set_interfaces_lan_wan "lan1 lan2 lan3" wan
\t\t;;
\truijie,rg-be72-pro-dsa-mod)
\t\tucidef_set_interfaces_lan_wan "lan1 lan2 lan3 lan4 lan5 lan6 lan7 lan8" wan
\t\t;;
'''
    s = s.replace(anchor, anchor + block, 1)
    io.open(p, 'w', encoding='utf-8', newline='').write(s)
    print('02_network: 已插入 ruijie-5in1 网口映射')

final = io.open(p, encoding='utf-8', newline='').read()
assert 'ruijie,rg-ew6000gx-pro' in final and 'ruijie,rg-be72-pro-dsa-mod' in final
print('✔ 02_network 校验通过')
PYEOF

# ---------------------------------------------------------------------------
# 4) 11_fix_wifi_mac：EW/X60 New/BE72 从 product_info 派生双频 MAC
# ---------------------------------------------------------------------------
python3 - <<'PYEOF'
import io

p = 'target/linux/mediatek/filogic/base-files/etc/hotplug.d/ieee80211/11_fix_wifi_mac'
s = io.open(p, encoding='utf-8', newline='').read()
MARK = '\t# === ruijie-5in1 wifi mac ===\n'
if MARK in s:
    print('11_fix_wifi_mac: ruijie-5in1 已存在，跳过')
else:
    anchor = 'case "$board" in\n'
    assert anchor in s, '11_fix_wifi_mac case 锚点异常'
    block = MARK + '''\truijie,rg-ew6000gx-pro|\\
\truijie,rg-x60-new|\\
\truijie,rg-be72-pro-dsa-mod)
\t\taddr=$(mtd_get_mac_ascii product_info ethaddr)
\t\t[ "$PHYNBR" = "0" ] && macaddr_add $addr 2 > /sys${DEVPATH}/macaddress
\t\t[ "$PHYNBR" = "1" ] && macaddr_add $addr 3 > /sys${DEVPATH}/macaddress
\t\t;;
'''
    s = s.replace(anchor, anchor + block, 1)
    io.open(p, 'w', encoding='utf-8', newline='').write(s)
    print('11_fix_wifi_mac: 已插入 ruijie-5in1 MAC 规则')

final = io.open(p, encoding='utf-8', newline='').read()
assert 'ruijie,rg-ew6000gx-pro' in final and 'ruijie,rg-be72-pro-dsa-mod' in final
print('✔ 11_fix_wifi_mac 校验通过')
PYEOF

# ---------------------------------------------------------------------------
# 5) 本机型无线默认配置（matrix job 只写自己这一份）
# ---------------------------------------------------------------------------
mkdir -p files/etc/config
if [ "$RU_WIFI_MODE" = "phy" ]; then
  DEV_2G="option phy '$RU_WIFI_2G'"
  DEV_5G="option phy '$RU_WIFI_5G'"
else
  DEV_2G="option path '$RU_WIFI_2G'"
  DEV_5G="option path '$RU_WIFI_5G'"
fi
cat > files/etc/config/wireless <<EOF

config wifi-device 'radio0'
	option type 'mac80211'
	$DEV_2G
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
	option ssid '$RU_SSID_2G'
	option encryption 'none'

config wifi-device 'radio1'
	option type 'mac80211'
	$DEV_5G
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
	option ssid '$RU_SSID_5G'
	option encryption 'none'
EOF
chmod 644 files/etc/config/wireless
echo "✔ 无线配置: $RU_DEVICE / $RU_WIFI_MODE / $RU_SSID_2G / $RU_SSID_5G"

# ---------------------------------------------------------------------------
# 6) 本机型硬校验：DTS 端口、网口映射、WiFi 校准、packages
# ---------------------------------------------------------------------------
python3 - "$RU_DEVICE" <<'PYEOF'
import io, sys
dev = sys.argv[1]
mk = io.open('target/linux/mediatek/image/filogic.mk', encoding='utf-8').read()
start = 'define Device/' + dev + '\n'
end = 'TARGET_DEVICES += ' + dev + '\n'
assert start in mk and end in mk, 'filogic.mk 缺设备块: ' + dev
blk = mk[mk.index(start):mk.index(end, mk.index(start))]
for token in ('luci-app-store', 'luci-i18n-base-zh-cn'):
    assert token in blk, dev + ' 缺 ' + token
if dev.startswith('ruijie_rg-x30e'):
    for token in ('kmod-mt7915e', 'kmod-mt7981-firmware', 'mt7981-wo-firmware'):
        assert token in blk, dev + ' 缺 ' + token
elif dev == 'ruijie_rg-be72-pro-dsa-mod':
    for token in ('kmod-mt7992-firmware', 'mt7988-wo-firmware', 'kmod-dsa-rtl837x'):
        assert token in blk, dev + ' 缺 ' + token
else:
    for token in ('kmod-mt7915e', 'kmod-mt7986-firmware', 'mt7986-wo-firmware'):
        assert token in blk, dev + ' 缺 ' + token
print('✔ DEVICE_PACKAGES 校验通过:', dev)
PYEOF

case "$RU_DEVICE" in
  ruijie_rg-ew6000gx-pro)
    DTS='target/linux/mediatek/dts/mt7986a-ruijie-rg-ew6000gx-pro.dts'
    grep -q 'compatible = "ruijie,rg-ew6000gx-pro"' "$DTS" || { echo "::error::EW compatible 不对"; exit 1; }
    grep -q 'label = "lan4"' "$DTS" || { echo "::error::EW 缺 lan4"; exit 1; }
    grep -q 'phy-handle = <&phy15>' "$DTS" || { echo "::error::EW 缺 2.5G WAN PHY"; exit 1; }
    grep -q 'reg = <0x680000 0x6b00000>' target/linux/mediatek/dts/mt7986a-ruijie-rg-ew6000gx-pro.dtsi || { echo "::error::EW UBI 分区不对"; exit 1; }
    grep -q 'eeprom_factory_0' target/linux/mediatek/dts/mt7986a-ruijie-rg-ew6000gx-pro.dtsi || { echo "::error::EW 缺 WiFi 校准"; exit 1; }
    grep -q 'ucidef_set_interfaces_lan_wan "lan1 lan2 lan3 lan4" "eth1"' "$NW" || { echo "::error::EW 网口映射不对"; exit 1; }
    ;;
  ruijie_rg-x60-new)
    DTS='target/linux/mediatek/dts/mt7986a-ruijie-rg-x60-new.dts'
    grep -q 'compatible = "ruijie,rg-x60-new"' "$DTS" || { echo "::error::X60 New compatible 不对"; exit 1; }
    grep -q 'label = "lan3"' "$DTS" || { echo "::error::X60 New 缺 lan3"; exit 1; }
    grep -q 'phy-handle = <&phy15>' "$DTS" || { echo "::error::X60 New 缺 2.5G WAN PHY"; exit 1; }
    grep -q 'reg = <0x680000 0x6b00000>' target/linux/mediatek/dts/mt7986a-ruijie-rg-x60-new.dtsi || { echo "::error::X60 New UBI 分区不对"; exit 1; }
    grep -q 'eeprom_factory_0' target/linux/mediatek/dts/mt7986a-ruijie-rg-x60-new.dtsi || { echo "::error::X60 New 缺 WiFi 校准"; exit 1; }
    grep -q 'ucidef_set_interfaces_lan_wan "lan1 lan2 lan3" eth1' "$NW" || { echo "::error::X60 New 网口映射不对"; exit 1; }
    ;;
  ruijie_rg-x30e)
    DTS='target/linux/mediatek/dts/mt7981b-ruijie-rg-x30e.dts'
    grep -q 'compatible = "ruijie,rg-x30e"' "$DTS" || { echo "::error::X30E compatible 不对"; exit 1; }
    grep -q 'label = "wan"' "$DTS" && grep -q 'label = "lan3"' "$DTS" || { echo "::error::X30E 端口标签不对"; exit 1; }
    grep -q 'eeprom_factory_0' "$DTS" || { echo "::error::X30E 缺 WiFi 校准"; exit 1; }
    grep -q 'reg = <0x880000 0x6f80000>' "$DTS" || { echo "::error::X30E UBI 分区不对"; exit 1; }
    grep -q 'ucidef_set_interfaces_lan_wan "lan1 lan2 lan3" wan' "$NW" || { echo "::error::X30E 网口映射不对"; exit 1; }
    ;;
  ruijie_rg-x30e-pro)
    DTS='target/linux/mediatek/dts/mt7981b-ruijie-rg-x30e-pro.dts'
    grep -q 'compatible = "ruijie,rg-x30e-pro"' "$DTS" || { echo "::error::X30E Pro compatible 不对"; exit 1; }
    grep -q 'label = "wan"' "$DTS" && grep -q 'label = "lan3"' "$DTS" || { echo "::error::X30E Pro 端口标签不对"; exit 1; }
    grep -q 'eeprom_factory_0' "$DTS" || { echo "::error::X30E Pro 缺 WiFi 校准"; exit 1; }
    grep -q 'reg = <0x880000 0x6f80000>' "$DTS" || { echo "::error::X30E Pro UBI 分区不对"; exit 1; }
    grep -q 'ucidef_set_interfaces_lan_wan "lan1 lan2 lan3" wan' "$NW" || { echo "::error::X30E Pro 网口映射不对"; exit 1; }
    ;;
  ruijie_rg-be72-pro-dsa-mod)
    DTS='target/linux/mediatek/dts/mt7988d-ruijie-rg-be72-pro-dsa-mod.dts'
    grep -q 'compatible = "ruijie,rg-be72-pro-dsa-mod"' "$DTS" || { echo "::error::BE72 compatible 不对"; exit 1; }
    grep -q 'realtek,rtl8372n' "$DTS" || { echo "::error::BE72 缺 RTL8372N DSA"; exit 1; }
    grep -q 'label = "wan"' "$DTS" && grep -q 'label = "lan8"' "$DTS" || { echo "::error::BE72 端口标签不全"; exit 1; }
    grep -q 'eeprom_factory_0' target/linux/mediatek/dts/mt7988d-ruijie-rg-be72-pro-base.dtsi || { echo "::error::BE72 缺 WiFi 校准"; exit 1; }
    grep -q 'ucidef_set_interfaces_lan_wan "lan1 lan2 lan3 lan4 lan5 lan6 lan7 lan8" wan' "$NW" || { echo "::error::BE72 网口映射不对"; exit 1; }
    ;;
esac

# 无线文件断言
test -f files/etc/config/wireless || { echo "::error::无线配置缺失"; exit 1; }
grep -q "option ssid '$RU_SSID_2G'" files/etc/config/wireless || { echo "::error::缺 2.4G AP"; exit 1; }
grep -q "option ssid '$RU_SSID_5G'" files/etc/config/wireless || { echo "::error::缺 5G AP"; exit 1; }
grep -q "option disabled '0'" files/etc/config/wireless || { echo "::error::无线仍为 disabled"; exit 1; }
if [ "$RU_WIFI_MODE" = "phy" ]; then
  grep -q "option phy '$RU_WIFI_2G'" files/etc/config/wireless || { echo "::error::缺 2.4G phy"; exit 1; }
  grep -q "option phy '$RU_WIFI_5G'" files/etc/config/wireless || { echo "::error::缺 5G phy"; exit 1; }
else
  grep -q "option path '$RU_WIFI_2G'" files/etc/config/wireless || { echo "::error::缺 2.4G path"; exit 1; }
  grep -q "option path '$RU_WIFI_5G'" files/etc/config/wireless || { echo "::error::缺 5G path"; exit 1; }
fi

echo "✔ $RU_DEVICE 注入完成（网口映射 + 双频无线 + iStore/中文；WiFi 增强由后续 vendor.sh uci-defaults 生成）"
