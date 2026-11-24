#!/bin/bash
# 把 3 台 NAND 256M 机型注入 ImmortalWrt 25.12 源码树：
#   cmcc_rax3000m-nand-256m  CMCC RAX3000M NAND 硬改 256M
#   cmcc_xr30-nand-256m      CMCC XR30    NAND 硬改 256M
#   cudy_tr3000-256mb-v1     Cudy TR3000 256MB（原生支持；多分区布局，只 sysupgrade 不产 factory）
#
# 前两台在 tvliving/lede 里没有独立机型（lede 只有 128M 的 nand/emmc），
# 这里按 lede 的 NAND 方案派生：dts 用 lede 的 128M 版（.github/cmcc/dts 里已有，
# 由 cmcc-inject.sh 提供），只把 ubi 分区从 0x7200000(114MB) 扩到
# 0xFA80000(250.5MB)、model/compatible 改名，其余分区表、MAC 偏移、WiFi eeprom 不变。
#
# 产物口径（三台一致，NAND 经典 UBI 卷方案）：
#   *-squashfs-factory.bin    append-ubi 全量包（U-Boot Web / 首刷）
#   *-squashfs-sysupgrade.bin sysupgrade-tar（系统内升级）
#   不产 preloader / fip / gpt，沿用机器现有 U-Boot。
#
# platform.sh 不需要改：这三台的 compatible 都不是平台脚本里已有的分支，
# 会走默认分支（do_upgrade → nand_do_upgrade，check_image → nand_do_platform_check），
# 正好是经典 NAND + tar 升级要的行为。
set -euo pipefail

TSRC='.github/cmcc/dts'
MK='target/linux/mediatek/image/filogic.mk'
NW='target/linux/mediatek/filogic/base-files/etc/board.d/02_network'

[ -f "$MK" ] || { echo "::error::当前目录不是 ImmortalWrt 源码树（缺 $MK）"; exit 1; }
[ -d "$TSRC" ] || { echo "::error::缺少 dts 源目录 $TSRC"; exit 1; }

# ---------------------------------------------------------------------------
# 1) DTS 落位（含 256M dts 依赖的 base / dtsi）
# ---------------------------------------------------------------------------
for f in mt7981b-cmcc-rax3000m-lede.dts mt7981b-cmcc-xr30.dtsi \
         mt7981b-cmcc-rax3000m-nand-256m.dts mt7981b-cmcc-xr30-nand-256m.dts; do
  [ -f "$TSRC/$f" ] || { echo "::error::$TSRC 缺 $f"; exit 1; }
  cp -f "$TSRC/$f" target/linux/mediatek/dts/
done
for d in mt7981b-cmcc-rax3000m-nand-256m.dts mt7981b-cmcc-xr30-nand-256m.dts; do
  grep -q 'reg = <0x580000 0xFA80000>;' "target/linux/mediatek/dts/$d" \
    || { echo "::error::$d 的 ubi 分区不是 250.5MB"; exit 1; }
  # WiFi 校准数据：lede 系 dts 用 mtd-eeprom，ImmortalWrt 系用 nvmem-cells，二者取一
  grep -qE 'nvmem-cells = <&eeprom_factory_0>;|mediatek,mtd-eeprom = <&factory 0x0>;' \
    "target/linux/mediatek/dts/$d" \
    || { echo "::error::$d 缺 WiFi eeprom"; exit 1; }
done
echo "✔ DTS 已就位（2 台 256M + base/dtsi）"

# ---------------------------------------------------------------------------
# 2) filogic.mk：追加 2 台 256M 机型；给原生 tr3000-256mb 补 factory 产物
# ---------------------------------------------------------------------------
python3 - <<'PYEOF'
import io, re

p = 'target/linux/mediatek/image/filogic.mk'
s = io.open(p, encoding='utf-8', newline='').read()

BLOCK = '''
# ============================================================================
# NAND 硬改 256M（RAX3000M / XR30），从 tvliving/lede 的 128M 方案派生
#   - ubi 分区 0x580000 + 0xFA80000 = 250.5MB，其余分区与 128M 版一致
#   - factory.bin（append-ubi 全量）+ sysupgrade.bin（sysupgrade-tar）
#   - compatible 用 -256m 后缀，避免与 128M 机型 / 原生 .itb 机型共用 board_name
# ============================================================================

#===== CMCC RAX3000M (NAND 256M) =====
define Device/cmcc_rax3000m-nand-256m
  DEVICE_VENDOR := CMCC
  DEVICE_MODEL := RAX3000M
  DEVICE_VARIANT := (NAND 256M)
  DEVICE_DTS := mt7981b-cmcc-rax3000m-nand-256m
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3 \\
	luci-app-store luci-i18n-base-zh-cn
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 250880k
  KERNEL_IN_UBI := 1
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cmcc_rax3000m-nand-256m

#===== CMCC XR30 (NAND 256M) =====
define Device/cmcc_xr30-nand-256m
  DEVICE_VENDOR := CMCC
  DEVICE_MODEL := XR30
  DEVICE_VARIANT := (NAND 256M)
  DEVICE_DTS := mt7981b-cmcc-xr30-nand-256m
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3 \\
	luci-app-store luci-i18n-base-zh-cn
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 250880k
  KERNEL_IN_UBI := 1
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cmcc_xr30-nand-256m
'''

if 'define Device/cmcc_xr30-nand-256m\n' in s:
    print('filogic.mk: 256M 设备块已存在，跳过')
else:
    s = s + BLOCK
    print('filogic.mk: 已追加 2 台 256M 机型')

# --- 原生 cudy_tr3000-256mb-v1：多分区设备，只保留 sysupgrade，不产 factory ---
# TR3000-256M 是 KERNEL_IN_UBI + sysupgrade-tar 写 kernel/rootfs 两分区的多分区布局，
# append-ubi 整盘镜像不适用；若上游已带 factory.bin 则移除，保持 sysupgrade-only。
m = re.search(r'define Device/cudy_tr3000-256mb-v1\n(.*?)\nendef', s, re.S)
assert m, 'filogic.mk 里找不到 cudy_tr3000-256mb-v1（ImmortalWrt 原生机型，改名了？）'
body = m.group(1)
if 'IMAGE/factory.bin' in body:
    kept = [ln for ln in body.split('\n')
            if not re.match(r'\s*IMAGES \+= factory\.bin\s*$', ln)
            and not re.match(r'\s*IMAGE/factory\.bin\s*:=', ln)]
    nb = '\n'.join(kept)
    assert 'IMAGE/factory.bin' not in nb, 'tr3000-256mb 的 factory 行未清理干净'
    s = s[:m.start(1)] + nb + s[m.end(1):]
    print('filogic.mk: tr3000-256mb 已移除 factory.bin（多分区，只保留 sysupgrade）')
else:
    print('filogic.mk: tr3000-256mb 本就无 factory.bin（多分区 sysupgrade-only）')

# --- 同机型补 iStore + 简体中文语言包（kconfig 里 DEPENDS 不满足会被静默压成 n，
#     与其它平台 workflow 的 inject-istore 一样走 DEVICE_PACKAGES）---
m = re.search(r'define Device/cudy_tr3000-256mb-v1\n(.*?)\nendef', s, re.S)
body = m.group(1)
if 'luci-app-store' in body:
    print('filogic.mk: tr3000-256mb 已有 iStore，跳过')
else:
    nb = re.sub(r'(\n  DEVICE_PACKAGES := )(.*)', lambda x: x.group(1) + x.group(2) + ' luci-app-store luci-i18n-base-zh-cn', body, count=1)
    assert nb != body, 'tr3000-256mb 的 DEVICE_PACKAGES 未改写'
    s = s[:m.start(1)] + nb + s[m.end(1):]
    print('filogic.mk: cudy_tr3000-256mb-v1 已补 iStore + 中文包')

io.open(p, 'w', encoding='utf-8', newline='').write(s)

final = io.open(p, encoding='utf-8', newline='').read()
for dev in ('cmcc_rax3000m-nand-256m', 'cmcc_xr30-nand-256m'):
    assert 'define Device/%s\n' % dev in final, 'filogic.mk 缺 %s' % dev
    assert 'TARGET_DEVICES += %s\n' % dev in final, 'TARGET_DEVICES 缺 %s' % dev
sec = final[final.index('# NAND 硬改 256M'):]
assert sec.count('IMAGE/factory.bin := append-ubi') == 2, '256M 两台都应带 factory.bin'
m2 = re.search(r'define Device/cudy_tr3000-256mb-v1\n(.*?)\nendef', final, re.S)
assert m2 and 'IMAGE/factory.bin' not in m2.group(1), 'tr3000-256mb 必须 sysupgrade-only（多分区，不产 factory）'
print('✔ filogic.mk 校验通过（256M 两台 factory+sysupgrade；tr3000-256mb 仅 sysupgrade）')
PYEOF

# ---------------------------------------------------------------------------
# 3) 02_network：两台的 LAN/WAN 与 128M 版一致（lan1 lan2 lan3 + wan=eth1）
# ---------------------------------------------------------------------------
python3 - <<'PYEOF'
import io

p = 'target/linux/mediatek/filogic/base-files/etc/board.d/02_network'
s = io.open(p, encoding='utf-8', newline='').read()

if 'cmcc,xr30-nand-256m' in s:
    print('02_network: 256M 机型已存在，跳过')
else:
    a = '\tcmcc,rax3000m|\\\n'
    assert s.count(a) == 1, '02_network 锚点异常: %d' % s.count(a)
    new = ('\tcmcc,rax3000m|\\\n'
           '\tcmcc,rax3000m-nand-256m|\\\n'
           '\tcmcc,xr30-nand-256m|\\\n')
    s = s.replace(a, new)
    io.open(p, 'w', encoding='utf-8', newline='').write(s)

nw = io.open(p, encoding='utf-8', newline='').read()
for dev in ('cmcc,rax3000m-nand-256m', 'cmcc,xr30-nand-256m'):
    assert dev + '|' in nw, '02_network 缺 %s' % dev
print('✔ 02_network 校验通过（两台 256M 并入 lan1 lan2 lan3 / wan=eth1 组）')
PYEOF

# ---------------------------------------------------------------------------
# 4) 兜底断言
# ---------------------------------------------------------------------------
for pat in 'define Device/cmcc_rax3000m-nand-256m' 'define Device/cmcc_xr30-nand-256m'; do
  grep -qF "$pat" "$MK" || { echo "::error::filogic.mk 缺少: $pat"; exit 1; }
done
grep -q 'luci-app-store' "$MK" || { echo "::error::filogic.mk 没注入 iStore"; exit 1; }
grep -q 'define Device/cudy_tr3000-256mb-v1' "$MK" \
  || { echo "::error::filogic.mk 里没有原生 tr3000-256mb 机型"; exit 1; }

echo "✔ NAND 256M 三机型注入完成（dts / filogic.mk / 02_network）"
