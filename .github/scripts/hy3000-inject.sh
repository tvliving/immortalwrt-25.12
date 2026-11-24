#!/bin/bash
# 把 Philips HY3000（MT7981 eMMC）注入 ImmortalWrt 25.12 源码树。
#
# 来源：tvliving/lede master 的 philips_hy3000 机型 + mt7981b-philips-hy3000.dts。
# 适配点（lede -> 25.12）：
#   - dts 的 include 由 mt7981.dtsi 改为 mt7981b.dtsi（25.12 内核命名）
#   - memory 节点改成 memory@40000000 + device_type = "memory"
#
# 机器性质：eMMC（root=PARTLABEL=rootfs，kernel 为 fit 格式），
#   产物只有 *-squashfs-sysupgrade.bin（sysupgrade-tar 写 kernel/rootfs 两分区），
#   不产 factory（与 cmcc eMMC 机型同一套口径）。
#
# 无线：DEVICE_PACKAGES 显式带 kmod-mt7915e / kmod-mt7981-firmware / mt7981-wo-firmware，
#   dts 的 &wifi 用 nvmem-cells = <&eeprom_factory_0>（eMMC factory 分区）做校准。
set -euo pipefail

TSRC='.github/lede/dts'
MK='target/linux/mediatek/image/filogic.mk'
NW='target/linux/mediatek/filogic/base-files/etc/board.d/02_network'
PS='target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh'

[ -f "$MK" ] || { echo "::error::当前目录不是 ImmortalWrt 源码树（缺 $MK）"; exit 1; }
[ -d "$TSRC" ] || { echo "::error::缺少 dts 源目录 $TSRC"; exit 1; }

# ---------------------------------------------------------------------------
# 1) dts 落位
# ---------------------------------------------------------------------------
[ -f "$TSRC/mt7981b-philips-hy3000.dts" ] || { echo "::error::$TSRC 缺 mt7981b-philips-hy3000.dts"; exit 1; }
cp -f "$TSRC/mt7981b-philips-hy3000.dts" target/linux/mediatek/dts/
grep -q 'compatible = "philips,hy3000"' target/linux/mediatek/dts/mt7981b-philips-hy3000.dts \
  || { echo "::error::hy3000 dts 的 compatible 不对"; exit 1; }
grep -q 'eeprom_factory_0' target/linux/mediatek/dts/mt7981b-philips-hy3000.dts \
  || { echo "::error::hy3000 dts 缺 WiFi 校准 eeprom_factory_0"; exit 1; }
echo "✔ dts 已就位（mt7981b-philips-hy3000.dts，WiFi 校准来自 eMMC factory）"

# ---------------------------------------------------------------------------
# 2) filogic.mk：追加 philips_hy3000（eMMC fit + sysupgrade-only）
# ---------------------------------------------------------------------------
python3 - <<'PYEOF'
import io

p = 'target/linux/mediatek/image/filogic.mk'
s = io.open(p, encoding='utf-8', newline='').read()

BLOCK = '''
# ============================================================================
# Philips HY3000（MT7981 eMMC），从 tvliving/lede 移植
#   - eMMC：kernel(fit) / rootfs 两分区，root=PARTLABEL=rootfs
#   - 产物只有 sysupgrade-tar，不产 factory
#   - 无线：kmod-mt7915e + mt7981-wo-firmware（显式带上，确保 LuCI 有"无线"菜单）
# ============================================================================
define Device/philips_hy3000
  DEVICE_VENDOR := Philips
  DEVICE_MODEL := HY3000
  DEVICE_DTS := mt7981b-philips-hy3000
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware \\
	kmod-usb3 f2fsck mkf2fs luci-app-store luci-i18n-base-zh-cn
  KERNEL := kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
  KERNEL_INITRAMFS := kernel-bin | lzma | \\
	fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  SUPPORTED_DEVICES += philips,hy3000
endef
TARGET_DEVICES += philips_hy3000
'''

if 'define Device/philips_hy3000\n' in s:
    print('filogic.mk: philips_hy3000 已存在，跳过')
else:
    s = s + BLOCK
    io.open(p, 'w', encoding='utf-8', newline='').write(s)
    print('filogic.mk: 已追加 philips_hy3000')

final = io.open(p, encoding='utf-8', newline='').read()
assert 'define Device/philips_hy3000\n' in final, 'filogic.mk 缺 philips_hy3000'
assert 'TARGET_DEVICES += philips_hy3000\n' in final, 'TARGET_DEVICES 缺 philips_hy3000'
blk = final[final.index('define Device/philips_hy3000'):]
blk = blk[:blk.index('TARGET_DEVICES += philips_hy3000')]
assert 'IMAGE/factory.bin' not in blk, 'HY3000 是 eMMC，不应有 factory.bin'
assert 'kmod-mt7915e' in blk and 'mt7981-wo-firmware' in blk, 'HY3000 缺无线包'
print('✔ filogic.mk 校验通过（HY3000 eMMC，仅 sysupgrade，带无线包）')
PYEOF

# ---------------------------------------------------------------------------
# 3) 02_network：并入 "lan1 lan2 lan3 / wan" 组 + MAC（eMMC factory 0x74）
# ---------------------------------------------------------------------------
python3 - <<'PYEOF'
import io

p = 'target/linux/mediatek/filogic/base-files/etc/board.d/02_network'
s = io.open(p, encoding='utf-8', newline='').read()

if 'philips,hy3000' in s:
    print('02_network: philips,hy3000 已存在，跳过')
else:
    # 3a) 网口组：并入 qihoo,360t7 所在的 "lan1 lan2 lan3" wan 组
    a = '\tqihoo,360t7|\\\n'
    assert s.count(a) == 1, '02_network lan/wan 锚点异常: %d' % s.count(a)
    s = s.replace(a, '\tphilips,hy3000|\\\n' + a)

    # 3b) MAC：在 mediatek_setup_macs 的 hiveton,h5000m 分支后插入
    anchor = ('\thiveton,h5000m)\n'
              '\t\tlan_mac=$(macaddr_generate_from_mmc_cid mmcblk0)\n'
              '\t\twan_mac=$(macaddr_add "$lan_mac" 1)\n'
              '\t\tlabel_mac=$wan_mac\n'
              '\t\t;;\n')
    assert s.count(anchor) == 1, '02_network MAC 锚点异常: %d' % s.count(anchor)
    branch = ('\tphilips,hy3000)\n'
              '\t\t# eMMC factory 分区 0x74 处是 base MAC（与 dts 的 macaddr_factory_74 一致）\n'
              '\t\tif command -v mmc_get_mac_binary >/dev/null 2>&1; then\n'
              '\t\t\tlan_mac=$(mmc_get_mac_binary factory 0x74)\n'
              '\t\telse\n'
              '\t\t\tlocal mfg_dev\n'
              '\t\t\tmfg_dev=$(find_mmc_part factory 2>/dev/null || true)\n'
              '\t\t\t[ -n "$mfg_dev" ] && lan_mac=$(get_mac_binary "$mfg_dev" 0x74)\n'
              '\t\tfi\n'
              '\t\t[ -n "$lan_mac" ] || lan_mac=$(cat /sys/class/net/eth0/address 2>/dev/null)\n'
              '\t\twan_mac=$(macaddr_add "$lan_mac" 1)\n'
              '\t\tlabel_mac=$wan_mac\n'
              '\t\t;;\n')
    s = s.replace(anchor, anchor + branch)
    io.open(p, 'w', encoding='utf-8', newline='').write(s)

final = io.open(p, encoding='utf-8', newline='').read()
assert final.count('philips,hy3000') == 2, \
    'philips,hy3000 应出现 2 次（网口组 + MAC），实际 %d' % final.count('philips,hy3000')
print('✔ 02_network 校验通过（lan1/2/3+wan 组 + MAC 从 eMMC factory 0x74）')
PYEOF

# ---------------------------------------------------------------------------
# 4) platform.sh：HY3000 是 eMMC，升级走 emmc_do_upgrade（三处路由）
# ---------------------------------------------------------------------------
python3 - <<'PYEOF'
import io

p = 'target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh'
s = io.open(p, encoding='utf-8', newline='').read()

if 'philips,hy3000' in s:
    print('platform.sh: philips,hy3000 已存在，跳过')
else:
    HY = '\tphilips,hy3000|\\\n'
    # 4a) platform_do_upgrade 的 emmc 组
    a = '\tglinet,gl-xe3000|\\\n\thiveton,h5000m|\\'
    assert s.count(a) == 1, 'platform.sh do_upgrade 锚点异常: %d' % s.count(a)
    s = s.replace(a, '\tglinet,gl-xe3000|\\\n' + HY + '\thiveton,h5000m|\\')
    # 4b) platform_check_image 的 ustar(tar) 组
    a = '\tcreatlentem,clt-r30b1-112m|\\\n\thiveton,h5000m|\\'
    assert s.count(a) == 1, 'platform.sh check_image 锚点异常: %d' % s.count(a)
    s = s.replace(a, '\tcreatlentem,clt-r30b1-112m|\\\n' + HY + '\thiveton,h5000m|\\')
    # 4c) platform_copy_config 的 emmc 组
    a = '\tglinet,gl-xe3000|\\\n\tglobitel,bt-r320|\\'
    assert s.count(a) == 1, 'platform.sh copy_config 锚点异常: %d' % s.count(a)
    s = s.replace(a, '\tglinet,gl-xe3000|\\\n' + HY + '\tglobitel,bt-r320|\\')
    io.open(p, 'w', encoding='utf-8', newline='').write(s)

final = io.open(p, encoding='utf-8', newline='').read()
assert final.count('\tphilips,hy3000|') == 3, \
    'platform.sh 应有 3 处 hy3000 路由，实际 %d' % final.count('\tphilips,hy3000|')
print('✔ platform.sh 校验通过（eMMC 三处：do_upgrade / check_image ustar / copy_config）')
PYEOF

# ---------------------------------------------------------------------------
# 5) 兜底断言
# ---------------------------------------------------------------------------
grep -qF 'define Device/philips_hy3000' "$MK" || { echo "::error::filogic.mk 缺少 philips_hy3000"; exit 1; }
grep -q 'luci-app-store' "$MK" || { echo "::error::filogic.mk 没注入 iStore"; exit 1; }
grep -q 'philips,hy3000' "$NW" || { echo "::error::02_network 缺 philips,hy3000"; exit 1; }
grep -q 'philips,hy3000' "$PS" || { echo "::error::platform.sh 缺 philips,hy3000"; exit 1; }

echo "✔ HY3000 注入完成（dts / filogic.mk / 02_network / platform.sh）"
