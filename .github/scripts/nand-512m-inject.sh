#!/bin/bash
# 把 2 台 NAND 512M 机型注入 ImmortalWrt 25.12 源码树：
#   cmcc_rax3000m-nand-512m  CMCC RAX3000M NAND 硬改 512M
#   cmcc_xr30-nand-512m      CMCC XR30    NAND 硬改 512M
#
# 来源：与 .github/scripts/nand-256m-inject.sh 同一套做法（dts 从 lede 派生的 128M 版
# 扩 ubi 分区），只把 ubi 从 0xFA80000(250.5MB/256M) 再扩一档：
#   0x580000 + 0x1EA00000 = 0x1EF80000 = 495MiB，ubi 490MiB（512M 颗粒）
#   分区前缀（bl2 1M / u-boot-env 512k / factory 2M / fip 2M）与 128M、256M 完全一致，
#   ubi 起址仍是 0x580000 —— 也就是 mt7981 系列 CMCC 机型的通用 U-Boot 布局。
#
# 分区尺寸出处（不是拍脑袋）：tvliving/bl-mt798x-dhcpd 的 512M U-Boot dts
#   uboot-mtk-20250711/arch/arm/dts/mt7981-cmcc-{xr30,rax3000m}-512m.dts
#   layout@3 { label = "512m";
#              mtdparts = "nmbm0:1024k(bl2),512k(u-boot-env),2048k(factory),2048k(fip),490m(ubi)"; }
#   同一份 dts 里 256m 布局是 256512k(ubi)=250.5MiB，与 256M 机型用的 0xFA80000 一致，
#   所以 512M 直接用 490m，让内核分区表与 U-Boot 的 mtdparts 对得上（差一点就会踩到
#   NMBM 预留块，刷完起不来）。
#
# 产物口径（两台一致，NAND 经典 UBI 卷方案）：
#   *-squashfs-factory.bin    append-ubi 全量包（U-Boot Web / 首刷）
#   *-squashfs-sysupgrade.bin sysupgrade-tar（系统内升级）
#   不产 preloader / fip / gpt，沿用机器现有 512M U-Boot。
#
# platform.sh 不需要改：两台 compatible 都是新名字，走默认分支
# （do_upgrade → nand_do_upgrade，check_image → nand_do_platform_check）。
set -euo pipefail

TSRC='.github/cmcc/dts'
MK='target/linux/mediatek/image/filogic.mk'
NW='target/linux/mediatek/filogic/base-files/etc/board.d/02_network'

[ -f "$MK" ] || { echo "::error::当前目录不是 ImmortalWrt 源码树（缺 $MK）"; exit 1; }
[ -d "$TSRC" ] || { echo "::error::缺少 dts 源目录 $TSRC"; exit 1; }

# ---------------------------------------------------------------------------
# 1) DTS 落位（含 512M dts 依赖的 base / dtsi）
# ---------------------------------------------------------------------------
for f in mt7981b-cmcc-rax3000m-lede.dts mt7981b-cmcc-xr30.dtsi \
         mt7981b-cmcc-rax3000m-nand-512m.dts mt7981b-cmcc-xr30-nand-512m.dts; do
  [ -f "$TSRC/$f" ] || { echo "::error::$TSRC 缺 $f"; exit 1; }
  cp -f "$TSRC/$f" target/linux/mediatek/dts/
done
for d in mt7981b-cmcc-rax3000m-nand-512m.dts mt7981b-cmcc-xr30-nand-512m.dts; do
  grep -q 'reg = <0x580000 0x1EA00000>;' "target/linux/mediatek/dts/$d" \
    || { echo "::error::$d 的 ubi 分区不是 490MB(0x1EA00000)"; exit 1; }
  # WiFi 校准数据：lede 系 dts 用 mtd-eeprom，ImmortalWrt 系用 nvmem-cells，二者取一
  grep -qE 'nvmem-cells = <&eeprom_factory_0>;|mediatek,mtd-eeprom = <&factory 0x0>;' \
    "target/linux/mediatek/dts/$d" \
    || { echo "::error::$d 缺 WiFi eeprom"; exit 1; }
done
echo "✔ DTS 已就位（2 台 512M + base/dtsi）"

# ---------------------------------------------------------------------------
# 2) filogic.mk：追加 2 台 512M 机型
# ---------------------------------------------------------------------------
python3 - <<'PYEOF'
import io

p = 'target/linux/mediatek/image/filogic.mk'
s = io.open(p, encoding='utf-8', newline='').read()

BLOCK = '''
# ============================================================================
# NAND 硬改 512M（RAX3000M / XR30），与 128M / 256M 同一套前缀分区
#   - ubi 分区 0x580000 + 0x1EA00000 = 490MiB（对齐 bl-mt798x-dhcpd 的 512m 布局）
#   - factory.bin（append-ubi 全量）+ sysupgrade.bin（sysupgrade-tar）
#   - compatible 用 -512m 后缀，避免与 128M / 256M / 原生 .itb 机型共用 board_name
# ============================================================================

#===== CMCC RAX3000M (NAND 512M) =====
define Device/cmcc_rax3000m-nand-512m
  DEVICE_VENDOR := CMCC
  DEVICE_MODEL := RAX3000M
  DEVICE_VARIANT := (NAND 512M)
  DEVICE_DTS := mt7981b-cmcc-rax3000m-nand-512m
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3 \\
	luci-app-store luci-i18n-base-zh-cn
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 496128k
  KERNEL_IN_UBI := 1
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cmcc_rax3000m-nand-512m

#===== CMCC XR30 (NAND 512M) =====
define Device/cmcc_xr30-nand-512m
  DEVICE_VENDOR := CMCC
  DEVICE_MODEL := XR30
  DEVICE_VARIANT := (NAND 512M)
  DEVICE_DTS := mt7981b-cmcc-xr30-nand-512m
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3 \\
	luci-app-store luci-i18n-base-zh-cn
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 496128k
  KERNEL_IN_UBI := 1
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cmcc_xr30-nand-512m
'''

if 'define Device/cmcc_xr30-nand-512m\n' in s:
    print('filogic.mk: 512M 设备块已存在，跳过')
else:
    s = s + BLOCK
    print('filogic.mk: 已追加 2 台 512M 机型')

io.open(p, 'w', encoding='utf-8', newline='').write(s)

final = io.open(p, encoding='utf-8', newline='').read()
for dev in ('cmcc_rax3000m-nand-512m', 'cmcc_xr30-nand-512m'):
    assert 'define Device/%s\n' % dev in final, 'filogic.mk 缺 %s' % dev
    assert 'TARGET_DEVICES += %s\n' % dev, 'TARGET_DEVICES 缺 %s' % dev
assert 'IMAGE_SIZE := 496128k' in final, 'IMAGE_SIZE 未写入'
sec = final[final.index('# NAND 硬改 512M'):]
assert sec.count('IMAGE/factory.bin := append-ubi') == 2, '512M 两台都应带 factory.bin'
assert sec.count('luci-app-store') == 2, '512M 两台都应带 iStore'
print('✔ filogic.mk 校验通过（2 台 512M，factory + sysupgrade）')
PYEOF

# ---------------------------------------------------------------------------
# 3) 02_network：两台的 LAN/WAN 与 128M/256M 版一致（lan1 lan2 lan3 + wan=eth1）
# ---------------------------------------------------------------------------
python3 - <<'PYEOF'
import io

p = 'target/linux/mediatek/filogic/base-files/etc/board.d/02_network'
s = io.open(p, encoding='utf-8', newline='').read()

if 'cmcc,xr30-nand-512m' in s:
    print('02_network: 512M 机型已存在，跳过')
else:
    a = '\tcmcc,rax3000m|\\\n'
    assert s.count(a) == 1, '02_network 锚点异常: %d' % s.count(a)
    new = ('\tcmcc,rax3000m|\\\n'
           '\tcmcc,rax3000m-nand-512m|\\\n'
           '\tcmcc,xr30-nand-512m|\\\n')
    s = s.replace(a, new)
    io.open(p, 'w', encoding='utf-8', newline='').write(s)

nw = io.open(p, encoding='utf-8', newline='').read()
for dev in ('cmcc,rax3000m-nand-512m', 'cmcc,xr30-nand-512m'):
    assert dev + '|' in nw, '02_network 缺 %s' % dev
print('✔ 02_network 校验通过（两台 512M 并入 lan1 lan2 lan3 / wan=eth1 组）')
PYEOF

# ---------------------------------------------------------------------------
# 4) 兜底断言
# ---------------------------------------------------------------------------
for pat in 'define Device/cmcc_rax3000m-nand-512m' 'define Device/cmcc_xr30-nand-512m'; do
  grep -qF "$pat" "$MK" || { echo "::error::filogic.mk 缺少: $pat"; exit 1; }
done
grep -q 'luci-app-store' "$MK" || { echo "::error::filogic.mk 没注入 iStore"; exit 1; }
grep -q 'luci-i18n-base-zh-cn' "$MK" || { echo "::error::filogic.mk 没注入中文语言包"; exit 1; }

echo "✔ NAND 512M 两机型注入完成（dts / filogic.mk / 02_network）"
