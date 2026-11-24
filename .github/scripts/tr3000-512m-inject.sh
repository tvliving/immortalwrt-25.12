#!/bin/bash
# 把 Cudy TR3000 512MB v1（MT7981 NAND）注入 ImmortalWrt 25.12 源码树。
#
# 来源：tvliving/lede master 的 cudy_tr3000-512mb-v1 机型 + mt7981b-cudy-tr3000-512mb-v1.dts。
# 该 dts include mt7981b-cudy-tr3000-v1.dts（25.12 已自带，无需额外提供）。
#
# 机器性质：NAND（KERNEL_IN_UBI + sysupgrade-tar），多分区，只产 sysupgrade，
#   不产 factory（与 TR3000-256MB 一致）。
#
# 无线：DEVICE_PACKAGES 显式带 kmod-mt7915e（lede 原版只靠 kmod-mt7981-firmware 隐式拉起，
#   这里显式写死，确保固件一定带 WiFi 驱动）+ kmod-mt7981-firmware + mt7981-wo-firmware。
set -euo pipefail

TSRC='.github/lede/dts'
MK='target/linux/mediatek/image/filogic.mk'

[ -f "$MK" ] || { echo "::error::当前目录不是 ImmortalWrt 源码树（缺 $MK）"; exit 1; }
[ -d "$TSRC" ] || { echo "::error::缺少 dts 源目录 $TSRC"; exit 1; }

# ---------------------------------------------------------------------------
# 1) dts 落位
# ---------------------------------------------------------------------------
[ -f "$TSRC/mt7981b-cudy-tr3000-512mb-v1.dts" ] || { echo "::error::$TSRC 缺 mt7981b-cudy-tr3000-512mb-v1.dts"; exit 1; }
cp -f "$TSRC/mt7981b-cudy-tr3000-512mb-v1.dts" target/linux/mediatek/dts/
grep -q 'reg = <0x5c0000 0x1FA40000>' target/linux/mediatek/dts/mt7981b-cudy-tr3000-512mb-v1.dts \
  || { echo "::error::tr3000-512mb dts 的 ubi 分区不是 512M 布局"; exit 1; }
[ -f target/linux/mediatek/dts/mt7981b-cudy-tr3000-v1.dts ] \
  || { echo "::error::缺基础 dts mt7981b-cudy-tr3000-v1.dts（512mb dts include 它）"; exit 1; }
echo "✔ dts 已就位（mt7981b-cudy-tr3000-512mb-v1.dts，ubi 512M 布局）"

# ---------------------------------------------------------------------------
# 2) filogic.mk：追加 cudy_tr3000-512mb-v1（KERNEL_IN_UBI + sysupgrade-only）
# ---------------------------------------------------------------------------
python3 - <<'PYEOF'
import io

p = 'target/linux/mediatek/image/filogic.mk'
s = io.open(p, encoding='utf-8', newline='').read()

BLOCK = '''
# ============================================================================
# Cudy TR3000 512MB v1（MT7981 NAND），从 tvliving/lede 移植
#   - ubi 分区 0x5c0000 + 0x1FA40000（约 506MB），IMAGE_SIZE 520000k
#   - KERNEL_IN_UBI + sysupgrade-tar，多分区，只产 sysupgrade（不产 factory）
#   - 无线：显式带 kmod-mt7915e + mt7981-wo-firmware
# ============================================================================
define Device/cudy_tr3000-512mb-v1
  DEVICE_VENDOR := Cudy
  DEVICE_MODEL := TR3000
  DEVICE_VARIANT := 512mb v1
  DEVICE_DTS := mt7981b-cudy-tr3000-512mb-v1
  DEVICE_DTS_DIR := ../dts
  SUPPORTED_DEVICES += R47
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 520000k
  KERNEL_IN_UBI := 1
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
  DEVICE_PACKAGES := kmod-usb3 kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware \\
	luci-app-store luci-i18n-base-zh-cn
endef
TARGET_DEVICES += cudy_tr3000-512mb-v1
'''

if 'define Device/cudy_tr3000-512mb-v1\n' in s:
    print('filogic.mk: cudy_tr3000-512mb-v1 已存在，跳过')
else:
    s = s + BLOCK
    io.open(p, 'w', encoding='utf-8', newline='').write(s)
    print('filogic.mk: 已追加 cudy_tr3000-512mb-v1')

final = io.open(p, encoding='utf-8', newline='').read()
assert 'define Device/cudy_tr3000-512mb-v1\n' in final, 'filogic.mk 缺 cudy_tr3000-512mb-v1'
assert 'TARGET_DEVICES += cudy_tr3000-512mb-v1\n' in final, 'TARGET_DEVICES 缺 cudy_tr3000-512mb-v1'
blk = final[final.index('define Device/cudy_tr3000-512mb-v1'):]
blk = blk[:blk.index('TARGET_DEVICES += cudy_tr3000-512mb-v1')]
assert 'IMAGE/factory.bin' not in blk, 'TR3000-512M 是多分区，不应有 factory.bin'
assert 'IMAGE_SIZE := 520000k' in blk, 'IMAGE_SIZE 应为 520000k'
assert 'kmod-mt7915e' in blk and 'mt7981-wo-firmware' in blk, 'TR3000-512M 缺无线包'
print('✔ filogic.mk 校验通过（TR3000-512M，IMAGE_SIZE 520000k，仅 sysupgrade，带无线包）')
PYEOF

# ---------------------------------------------------------------------------
# 3) 02_network / platform.sh 不需要改：
#    dts compatible 是 cudy,tr3000-v1，25.12 的 02_network 已有该组（lan/wan = eth1/eth0），
#    KERNEL_IN_UBI 走默认 nand_do_upgrade。
# ---------------------------------------------------------------------------
# 兜底断言
grep -qF 'define Device/cudy_tr3000-512mb-v1' "$MK" || { echo "::error::filogic.mk 缺少 cudy_tr3000-512mb-v1"; exit 1; }
grep -q 'cudy,tr3000-v1' target/linux/mediatek/filogic/base-files/etc/board.d/02_network \
  || { echo "::error::02_network 缺 cudy,tr3000-v1（512M compatible 走它）"; exit 1; }

echo "✔ TR3000-512M 注入完成（dts / filogic.mk；02_network 复用 cudy,tr3000-v1）"
