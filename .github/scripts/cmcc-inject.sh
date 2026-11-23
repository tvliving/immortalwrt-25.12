#!/bin/bash
# 把 CMCC RAX3000M / XR30 四机型（NAND + eMMC）注入 ImmortalWrt 25.12 源码树。
#
# 机型方案与 dts 全部取自 tvliving/lede master（已在 tvliving/Kwrt 的 openwrt-25.12
# 上跑通），只是把 rax3000m 的三个文件加了 -lede 后缀，避免与本仓库
# target/linux/mediatek/dts/mt7981b-cmcc-rax3000m.dts（ImmortalWrt 自己的
# .itb 单镜像 + dtso overlay 方案）撞名：
#   NAND：kernel FIT 放 UBI "kernel" 卷 + squashfs 静态卷，出
#         *-squashfs-factory.bin（append-ubi 全量）+ *-squashfs-sysupgrade.bin
#   eMMC：kernel / rootfs 两分区 + root=PARTLABEL=rootfs，只出
#         *-squashfs-sysupgrade.bin
#   两类都不产 preloader / blip / bl31 / gpt，沿用机器现有 U-Boot。
#
# 注入点（全部幂等，重复执行不会重复追加）：
#   1) target/linux/mediatek/dts/  —— 6 个设备树文件
#   2) target/linux/mediatek/image/filogic.mk —— 4 个 Device 块
#   3) target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh
#        eMMC → emmc_do_upgrade / emmc_copy_config；四台 → ustar(tar) 校验组
#   4) target/linux/mediatek/filogic/base-files/etc/board.d/02_network
#        并入既有的 "lan1 lan2 lan3 / eth1" 组（与 cmcc,rax3000m 同组）
set -euo pipefail

TSRC='.github/cmcc/dts'
MK='target/linux/mediatek/image/filogic.mk'
PS='target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh'
NW='target/linux/mediatek/filogic/base-files/etc/board.d/02_network'

[ -f "$MK" ] || { echo "::error::当前目录不是 ImmortalWrt 源码树（缺 $MK）"; exit 1; }
[ -d "$TSRC" ] || { echo "::error::缺少 dts 源目录 $TSRC"; exit 1; }

# ---------------------------------------------------------------------------
# 1) DTS 落位
# ---------------------------------------------------------------------------
for f in "$TSRC"/*.dts "$TSRC"/*.dtsi; do
  [ -f "$f" ] || continue
  cp -f "$f" target/linux/mediatek/dts/
done
for d in mt7981b-cmcc-rax3000m-lede.dts mt7981b-cmcc-rax3000m-nand-lede.dts \
         mt7981b-cmcc-rax3000m-emmc-lede.dts mt7981b-cmcc-xr30.dtsi \
         mt7981b-cmcc-xr30-nand.dts mt7981b-cmcc-xr30-emmc.dts; do
  [ -f "target/linux/mediatek/dts/$d" ] || { echo "::error::DTS 未落位: $d"; exit 1; }
done
echo "✔ DTS 已就位（6 个文件）"

# ---------------------------------------------------------------------------
# 2) filogic.mk：追加 4 个设备块
# ---------------------------------------------------------------------------
python3 - <<'PYEOF'
import io

p = 'target/linux/mediatek/image/filogic.mk'
s = io.open(p, encoding='utf-8', newline='').read()

if 'define Device/cmcc_xr30-nand\n' in s:
    print('filogic.mk: 设备块已存在，跳过')
else:
    block = '''
# ============================================================================
# CMCC RAX3000M / XR30（NAND + eMMC），移植自 tvliving/lede master
#   - dts 由 .github/cmcc/dts 注入（-lede 后缀，避免与本仓库 .itb 方案撞名）
#   - NAND：factory.bin（append-ubi 全量）+ sysupgrade.bin
#   - eMMC：只有 sysupgrade.bin（sysupgrade-tar 写 kernel/rootfs 两分区）
#   - 不产 preloader / fip / gpt：沿用机器现有 U-Boot
# ============================================================================

#===== CMCC RAX3000M (eMMC) =====
define Device/cmcc_rax3000m-emmc
  DEVICE_VENDOR := CMCC
  DEVICE_MODEL := RAX3000M (eMMC version)
  DEVICE_DTS := mt7981b-cmcc-rax3000m-emmc-lede
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3 f2fsck mkf2fs
  KERNEL := kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
  KERNEL_INITRAMFS := kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cmcc_rax3000m-emmc

#===== CMCC RAX3000M (NAND) =====
define Device/cmcc_rax3000m-nand
  DEVICE_VENDOR := CMCC
  DEVICE_MODEL := RAX3000M (NAND version)
  DEVICE_DTS := mt7981b-cmcc-rax3000m-nand-lede
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 116736k
  KERNEL_IN_UBI := 1
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cmcc_rax3000m-nand

#===== CMCC XR30 (eMMC) =====
define Device/cmcc_xr30-emmc
  DEVICE_VENDOR := CMCC
  DEVICE_MODEL := XR30 (eMMC version)
  DEVICE_DTS := mt7981b-cmcc-xr30-emmc
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3 f2fsck mkf2fs
  KERNEL := kernel-bin | lzma | fit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb
  KERNEL_INITRAMFS := kernel-bin | lzma | \\
\tfit lzma $$(KDIR)/image-$$(firstword $$(DEVICE_DTS)).dtb with-initrd | pad-to 64k
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cmcc_xr30-emmc

#===== CMCC XR30 (NAND, U-Boot mod) =====
define Device/cmcc_xr30-nand
  DEVICE_VENDOR := CMCC
  DEVICE_MODEL := XR30 NAND
  DEVICE_VARIANT := (U-Boot mod)
  DEVICE_DTS := mt7981b-cmcc-xr30-nand
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware kmod-usb3
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  IMAGE_SIZE := 116736k
  KERNEL_IN_UBI := 1
  IMAGES += factory.bin
  IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += cmcc_xr30-nand
'''
    io.open(p, 'w', encoding='utf-8', newline='').write(s + block)
    print('filogic.mk: 已追加 4 个设备块')

final = io.open(p, encoding='utf-8', newline='').read()
for dev in ('cmcc_rax3000m-emmc', 'cmcc_rax3000m-nand', 'cmcc_xr30-emmc', 'cmcc_xr30-nand'):
    assert 'define Device/%s\n' % dev in final, 'filogic.mk 缺 %s' % dev
    assert 'TARGET_DEVICES += %s\n' % dev in final, 'filogic.mk 缺 TARGET_DEVICES += %s' % dev

MARK = '# CMCC RAX3000M / XR30（NAND + eMMC），移植自 tvliving/lede master'
sec = final[final.index(MARK):]
assert sec.count('IMAGE/factory.bin := append-ubi | check-size $$$$(IMAGE_SIZE)') == 2, \
    'factory.bin 配方数量异常（应为 2，只给两台 NAND）'
assert sec.count('IMAGES += factory.bin') == 2, 'factory.bin 只该出现在 NAND 机型'
assert sec.count('IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata') == 4, \
    '四个机型都该走 sysupgrade-tar'
print('✔ filogic.mk 校验通过（eMMC 只有 sysupgrade，NAND 有 factory + sysupgrade）')
PYEOF

# ---------------------------------------------------------------------------
# 3) platform.sh
# ---------------------------------------------------------------------------
python3 - <<'PYEOF'
import io

p = 'target/linux/mediatek/filogic/base-files/lib/upgrade/platform.sh'
s = io.open(p, encoding='utf-8', newline='').read()

EMMC = '\tcmcc,rax3000m-emmc|\\\n\tcmcc,xr30-emmc|\\\n'
ALL4 = ('\tcmcc,rax3000m-emmc|\\\n'
        '\tcmcc,rax3000m-nand|\\\n'
        '\tcmcc,xr30-emmc|\\\n'
        '\tcmcc,xr30-nand|\\\n')

if 'cmcc,rax3000m-emmc' in s:
    print('platform.sh: 路由已存在，跳过')
else:
    # 3a) platform_do_upgrade 的 emmc 组
    a = '\tglinet,gl-xe3000|\\\n\thiveton,h5000m|\\'
    assert s.count(a) == 1, 'do_upgrade emmc 锚点异常: %d' % s.count(a)
    s = s.replace(a, '\tglinet,gl-xe3000|\\\n' + EMMC + '\thiveton,h5000m|\\')

    # 3b) platform_check_image 的 ustar(tar) 组
    a = '\tcreatlentem,clt-r30b1-112m|\\\n\thiveton,h5000m|\\'
    assert s.count(a) == 1, 'check_image ustar 锚点异常: %d' % s.count(a)
    s = s.replace(a, '\tcreatlentem,clt-r30b1-112m|\\\n' + ALL4 + '\thiveton,h5000m|\\')

    # 3c) platform_copy_config 的 emmc 组
    a = '\tglinet,gl-xe3000|\\\n\tglobitel,bt-r320|\\'
    assert s.count(a) == 1, 'copy_config emmc 锚点异常: %d' % s.count(a)
    s = s.replace(a, '\tglinet,gl-xe3000|\\\n' + EMMC + '\tglobitel,bt-r320|\\')

    io.open(p, 'w', encoding='utf-8', newline='').write(s)

ps = io.open(p, encoding='utf-8', newline='').read()
assert ps.count('\tcmcc,rax3000m-emmc|') == 3, 'eMMC 路由行数量异常: %d' % ps.count('\tcmcc,rax3000m-emmc|')
assert ps.count('\tcmcc,xr30-emmc|') == 3, 'xr30 eMMC 路由行数量异常: %d' % ps.count('\tcmcc,xr30-emmc|')
assert ps.count('\tcmcc,rax3000m-nand|') == 1, 'NAND 路由行数量异常: %d' % ps.count('\tcmcc,rax3000m-nand|')
assert ps.count('\tcmcc,xr30-nand|') == 1, 'xr30 NAND 路由行数量异常: %d' % ps.count('\tcmcc,xr30-nand|')
print('✔ platform.sh 校验通过（eMMC 三处；NAND 只进 ustar 校验组，升级走默认 nand_do_upgrade）')
PYEOF

# ---------------------------------------------------------------------------
# 4) 02_network：并入既有的 "lan1 lan2 lan3 / eth1" 组（cmcc,rax3000m 同组）
# ---------------------------------------------------------------------------
python3 - <<'PYEOF'
import io

p = 'target/linux/mediatek/filogic/base-files/etc/board.d/02_network'
s = io.open(p, encoding='utf-8', newline='').read()

if 'cmcc,xr30-nand' in s:
    print('02_network: 机型已存在，跳过')
else:
    a = '\tcmcc,rax3000m|\\\n\tcmcc,rax3000me|\\\n'
    assert s.count(a) == 1, '02_network 锚点异常: %d' % s.count(a)
    new = ('\tcmcc,rax3000m|\\\n'
           '\tcmcc,rax3000m-emmc|\\\n'
           '\tcmcc,rax3000m-nand|\\\n'
           '\tcmcc,rax3000me|\\\n'
           '\tcmcc,xr30-emmc|\\\n'
           '\tcmcc,xr30-nand|\\\n')
    s = s.replace(a, new)
    io.open(p, 'w', encoding='utf-8', newline='').write(s)

nw = io.open(p, encoding='utf-8', newline='').read()
for dev in ('cmcc,rax3000m-emmc', 'cmcc,rax3000m-nand', 'cmcc,xr30-emmc', 'cmcc,xr30-nand'):
    assert dev + '|' in nw, '02_network 缺 %s' % dev
assert nw.count('ucidef_set_interfaces_lan_wan "lan1 lan2 lan3" eth1') >= 1
print('✔ 02_network 校验通过（四机型与 cmcc,rax3000m 同组：lan1 lan2 lan3 / wan=eth1）')
PYEOF

# ---------------------------------------------------------------------------
# 5) 兜底断言
# ---------------------------------------------------------------------------
for pat in 'define Device/cmcc_rax3000m-emmc' 'define Device/cmcc_rax3000m-nand' \
           'define Device/cmcc_xr30-emmc' 'define Device/cmcc_xr30-nand'; do
  grep -qF "$pat" "$MK" || { echo "::error::filogic.mk 缺少: $pat"; exit 1; }
done
grep -q 'root=PARTLABEL=rootfs' target/linux/mediatek/dts/mt7981b-cmcc-rax3000m-emmc-lede.dts \
  || { echo "::error::eMMC dts 缺 root=PARTLABEL=rootfs"; exit 1; }
grep -q 'root=PARTLABEL=rootfs' target/linux/mediatek/dts/mt7981b-cmcc-xr30-emmc.dts \
  || { echo "::error::xr30 eMMC dts 缺 root=PARTLABEL=rootfs"; exit 1; }

echo "✔ CMCC RAX3000M / XR30 四机型注入完成（dts / filogic.mk / platform.sh / 02_network）"
