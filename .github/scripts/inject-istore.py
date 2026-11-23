#!/usr/bin/env python3
"""为「闪存 >= 128M」的机型注入 iStore 软件中心 + 首页 + 简体中文语言包。

用法： python3 inject-istore.py <target> <subtarget>
     在 openwrt 源码根目录执行。脚本读取同目录 128m-devices.json 的机型白名单，
     改写 target/linux/<target>/image/<subtarget>.mk 中对应机型的 DEVICE_PACKAGES。

为什么按机型而不是全局 .config：
  同一 subtarget 里小闪存机型会一起装上商店 + 中文包导致 image 超限，
  必须精确到机型，用 DEVICE_PACKAGES（沿用 tvliving/lede 已验证做法）。

注入的包：
  luci-app-store          iStore 软件中心
  luci-app-quickstart     iStore 首页（Kwrt 同款，进后台即中文引导页）
  luci-i18n-base-zh-cn    简体中文界面
  luci-i18n-store-zh-cn   iStore 中文（若该源无独立包，vendor.sh 会跳过）

白名单 128m-devices.json 由 tools/gen_128m_list.py 从上游 mk/dts 生成，
只含真实存在的机型；找不到机型只告警不失败（避免上游改名阻断构建）。
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LIST_FILE = os.path.join(HERE, '128m-devices.json')

STORE_PACKAGES = (
    'luci-app-store luci-app-quickstart '
    'luci-i18n-base-zh-cn luci-i18n-store-zh-cn'
)


def image_path(target, subtarget):
    base = os.path.join('target/linux', target, 'image')
    p = os.path.join(base, subtarget + '.mk')
    if os.path.isfile(p):
        return p
    # 某些 subtarget 没有独立 .mk，扫描 image/ 下所有 .mk 找含最多 Device 的
    best, best_n = None, 0
    if os.path.isdir(base):
        for fn in sorted(os.listdir(base)):
            if not fn.endswith('.mk'):
                continue
            fp = os.path.join(base, fn)
            txt = open(fp, encoding='utf-8', errors='replace').read()
            n = len(re.findall(r'^\s*define Device/', txt, re.M))
            if n > best_n:
                best, best_n = fp, n
    return best


def main():
    if len(sys.argv) != 3:
        print('用法: %s <target> <subtarget>' % sys.argv[0], file=sys.stderr)
        return 2
    target, subtarget = sys.argv[1], sys.argv[2]

    if not os.path.isfile(LIST_FILE):
        print('::error::缺少白名单文件 %s' % LIST_FILE, file=sys.stderr)
        return 1
    wl_all = json.load(open(LIST_FILE, encoding='utf-8'))
    key = '%s/%s' % (target, subtarget)
    whitelist = wl_all.get(key, [])
    if not whitelist:
        print('::warning::%s 未配置 128M+ 机型白名单，跳过 iStore 注入' % key)
        return 0

    path = image_path(target, subtarget)
    if not path:
        print('::error::找不到 %s/%s 的 image mk' % (target, subtarget), file=sys.stderr)
        return 1

    s = open(path, encoding='utf-8').read()
    done, missing, exists = [], [], []
    for dev in whitelist:
        m = re.search(r'(define Device/%s\n.*?)(\n\s*endef)' % re.escape(dev), s, re.S)
        if not m:
            missing.append(dev)
            continue
        if 'luci-app-store' in m.group(1):
            exists.append(dev)
            continue
        s = s[:m.start(2)] + '\n  DEVICE_PACKAGES += ' + STORE_PACKAGES + s[m.start(2):]
        done.append(dev)

    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(s)

    print('已注入 %d 台 128M+ 机型: %s' % (len(done), ' '.join(done[:20])))
    if exists:
        print('已存在(幂等跳过) %d 台' % len(exists))
    if missing:
        # 上游机型改名不应阻断整个构建，但要显式提醒维护者更新白名单
        print('::warning::%s 中找不到这些机型（上游改名？可更新 128m-devices.json）: %s'
              % (path, ' '.join(missing)))
    if not done and not exists and missing:
        print('::warning::白名单机型全部未命中，本次未注入任何 iStore')
    return 0


if __name__ == '__main__':
    sys.exit(main())
