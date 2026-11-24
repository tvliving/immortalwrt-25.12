#!/bin/bash
# 为 ImmortalWrt 25.12 的 Globitel BT-R320（MT7981B / eMMC / FIT）补齐构建定制。
#
# 说明：25.12 源码已自带上游 BT-R320 机型支持（DTS / U-Boot / 02_network /
# platform.sh / uboot-envtools 均齐全），本脚本不重复新增机型，只做三件事：
#   1. 在 Device/globitel_bt-r320 的 DEVICE_PACKAGES 里显式加入 iStore + 简体中文基础包
#   2. 落位一份可直接启动的双频无线配置（LuCI「网络-无线」里可见、首启即开启）
#   3. 对上游机型支持做硬校验：FIT 启动口径、2.5G CPU 端口、WiFi 校准、MAC 热插拔
#
# 产物口径：eMMC FIT，只有 *-squashfs-sysupgrade.itb；不产 factory，不附带 preloader/fip/gpt。
set -euo pipefail

MK='target/linux/mediatek/image/filogic.mk'
DTS='target/linux/mediatek/dts/mt7981b-globitel-bt-r320.dts'
NW='target/linux/mediatek/filogic/base-files/etc/board.d/02_network'
MAC='target/linux/mediatek/filogic/base-files/etc/hotplug.d/ieee80211/11_fix_wifi_mac'
PS='target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh'
UBOOT_MK='package/boot/uboot-mediatek/Makefile'
UBOOT_PATCH='package/boot/uboot-mediatek/patches/472-add-globitel-bt-r320.patch'

for f in "$MK" "$DTS" "$NW" "$MAC" "$PS" "$UBOOT_MK" "$UBOOT_PATCH"; do
  [ -f "$f" ] || { echo "::error::源码树缺少 $f，当前不是完整的 ImmortalWrt 25.12 树"; exit 1; }
done

# ---------------------------------------------------------------------------
# 1) filogic.mk：只改 BT-R320 的 DEVICE_PACKAGES
# ---------------------------------------------------------------------------
python3 - <<'PYEOF'
import io

p = 'target/linux/mediatek/image/filogic.mk'
s = io.open(p, encoding='utf-8', newline='').read()
start = 'define Device/globitel_bt-r320\n'
end = 'TARGET_DEVICES += globitel_bt-r320\n'
assert s.count(start) == 1, 'filogic.mk 里 BT-R320 Device 块数量异常'
i = s.index(start)
j = s.index(end, i) + len(end)
blk = s[i:j]

pkgs = ('  DEVICE_PACKAGES := kmod-usb3 kmod-mt7915e kmod-mt7981-firmware '
        'mt7981-wo-firmware f2fsck mkf2fs luci-app-store luci-i18n-base-zh-cn\n')
lines = blk.splitlines(keepends=True)
for n, line in enumerate(lines):
    if line.startswith('  DEVICE_PACKAGES :='):
        lines[n] = pkgs
        break
else:
    raise SystemExit('BT-R320 Device 块里找不到 DEVICE_PACKAGES 行')
new_blk = ''.join(lines)
if new_blk != blk:
    s = s[:i] + new_blk + s[j:]
    io.open(p, 'w', encoding='utf-8', newline='').write(s)
    print('filogic.mk: 已更新 BT-R320 DEVICE_PACKAGES（iStore + 中文 + 无线）')
else:
    print('filogic.mk: BT-R320 DEVICE_PACKAGES 已符合要求，跳过')

final = io.open(p, encoding='utf-8', newline='').read()
blk = final[final.index(start):final.index(end, final.index(start))]
for token in ('kmod-mt7915e', 'kmod-mt7981-firmware', 'mt7981-wo-firmware',
              'luci-app-store', 'luci-i18n-base-zh-cn'):
    assert token in blk, 'BT-R320 DEVICE_PACKAGES 缺少: ' + token
assert 'IMAGE/factory.bin' not in blk, 'BT-R320 是 eMMC FIT，不应有 factory.bin'
assert 'IMAGES := sysupgrade.itb' in blk, 'BT-R320 应走 FIT sysupgrade.itb'
print('✔ filogic.mk 校验通过（BT-R320 eMMC FIT，仅 sysupgrade.itb）')
PYEOF

# ---------------------------------------------------------------------------
# 2) 落位双频无线配置：25.12 的 MT7981 路径是 platform/soc/18000000.wifi(+1)
#    每个 radio 只放一个 AP，避开 25.12 多 BSSID + 160MHz 的已知回归。
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
	option ssid 'BT-R320-2.4G'
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
	option ssid 'BT-R320-5G'
	option encryption 'none'
EOF
chmod 644 files/etc/config/wireless
echo "✔ files/etc/config/wireless 已落位（radio0 2.4G / radio1 5G，首启开启）"

# ---------------------------------------------------------------------------
# 3) 上游机型支持硬校验：确认这台机器在仓库里确实能正常启动/联网
# ---------------------------------------------------------------------------
grep -q 'compatible = "globitel,bt-r320"' "$DTS" \
  || { echo "::error::BT-R320 DTS compatible 不对"; exit 1; }
grep -q 'root=/dev/fit0 rootwait' "$DTS" \
  || { echo "::error::BT-R320 DTS 缺 FIT root=/dev/fit0 启动参数"; exit 1; }
grep -q 'rootdisk = <&emmc_rootdisk>' "$DTS" \
  || { echo "::error::BT-R320 DTS 缺 rootdisk 指向 production 分区"; exit 1; }
grep -q 'compatible = "gpt-partitions"' "$DTS" \
  || { echo "::error::BT-R320 DTS 缺 GPT 分区描述"; exit 1; }
grep -q '2500base-x' "$DTS" \
  || { echo "::error::BT-R320 DTS CPU 端口不是 2.5G，以太网会不通"; exit 1; }
grep -q '&wifi' "$DTS" && grep -q 'eeprom_factory_0' "$DTS" \
  || { echo "::error::BT-R320 DTS 缺 WiFi 节点或 factory 校准 eeprom"; exit 1; }

grep -q 'globitel,bt-r320' "$NW" \
  || { echo "::error::02_network 缺 BT-R320 网口分配（lan1-3 / wan）"; exit 1; }
grep -q 'globitel,bt-r320' "$MAC" \
  || { echo "::error::11_fix_wifi_mac 缺 BT-R320，无线 MAC 会异常"; exit 1; }
grep -q 'globitel,bt-r320' "$PS" \
  || { echo "::error::platform.sh 缺 BT-R320 升级路由"; exit 1; }
grep -q 'mt7981_globitel_bt-r320' "$UBOOT_MK" \
  || { echo "::error::uboot-mediatek 缺 BT-R320 配置"; exit 1; }
grep -q '2500base-x' "$UBOOT_PATCH" \
  || { echo "::error::U-Boot 补丁缺 BT-R320 2.5G 以太网修复"; exit 1; }

grep -q "option path 'platform/soc/18000000.wifi'" files/etc/config/wireless \
  || { echo "::error::无线配置缺 2.4G radio"; exit 1; }
grep -q "option path 'platform/soc/18000000.wifi+1'" files/etc/config/wireless \
  || { echo "::error::无线配置缺 5G radio"; exit 1; }
grep -q "option ssid 'BT-R320-2.4G'" files/etc/config/wireless \
  || { echo "::error::无线配置缺 2.4G AP"; exit 1; }
grep -q "option ssid 'BT-R320-5G'" files/etc/config/wireless \
  || { echo "::error::无线配置缺 5G AP"; exit 1; }

echo "✔ BT-R320 注入与校验完成（FIT / 2.5G / 双频 WiFi / iStore / 中文）"
