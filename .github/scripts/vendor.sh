#!/usr/bin/env bash
#
# 全仓库统一的「默认主题 + iStore 市场 + 中文包」注入助手，供 .github/workflows/*.yml 调用。
#
# 主题：默认 luci-theme-argon（ImmortalWrt feeds 自带 themes/luci-theme-argon）
#   默认值可用环境变量覆盖：THEME=argon（默认）/ THEME=vantage
#   argon 直接来自 feeds，不需要 vendor，配置栈里本来就是 CONFIG_PACKAGE_luci-theme-argon=y。
#   vantage 属于外部 vendor（https://github.com/anothaDev/luci-theme-vantage），
#   只有 THEME=vantage 时才克隆；克隆失败或结构不符会自动回退 argon，构建不中断。
#
# 语言/商店：强制简体中文（luci.main.lang=zh_cn + LUCI_LANG_zh_Hans + 全量 zh-cn 包），
#   iStore 市场 luci-app-store 与其中文语言包 luci-i18n-store-zh-cn 一并选入。
#
# 无线：uci-defaults 99-wifi-boost 统一做「国码 CN + 5G 开 160MHz + 802.11k/v/r +
#   HE beamforming」，2.4G 只到 HE40（radio 按 band 自动判断，不会给 2.4G 强塞 HE160）。
#
# 用法（在 feed / 配置生成的不同阶段分别调用）：
#   vendor.sh feed              # 在 feeds.conf.default 里追加 istore 源（feeds update 之前）
#   vendor.sh store             # feeds update 之后：安装 iStore 市场与中文语言包
#   vendor.sh theme             # 校验/准备主题，结果写入 $PWD/.theme（argon|vantage）
#   vendor.sh collections       # 把 feeds/luci 集合对 bootstrap 的依赖改成本次主题
#   vendor.sh config <file>     # 在生成的 .config 里切换主题 + 中文 + iStore
#   vendor.sh wifi              # 写 files/etc/uci-defaults/99-wifi-boost（无线增强）
#   vendor.sh uci-defaults      # 写默认主题 / 中文 / 无线三个 uci-defaults 脚本
#
set -uo pipefail

THEME_REPO="${THEME_REPO:-https://github.com/anothaDev/luci-theme-vantage}"
THEME="${THEME:-argon}"
THEME_FILE="${THEME_FILE:-$PWD/.theme}"
ISTORE_FEED='src-git istore https://github.com/linkease/istore;main'

log()  { echo ">>> $*"; }
warn() { echo "::warning::$*"; }
err()  { echo "::error::$*"; }

current_theme() {
  if [ -f "$THEME_FILE" ]; then cat "$THEME_FILE"; else echo "${THEME:-argon}"; fi
}

cmd_feed() {
  if grep -q 'src-git istore' feeds.conf.default; then
    log "istore 源已存在"
  else
    echo "$ISTORE_FEED" >> feeds.conf.default
    log "已追加 istore 源: $ISTORE_FEED"
  fi
}

cmd_store() {
  # feeds install -a 不一定装上 istore feed 的包，显式再装一遍
  ./scripts/feeds install -d y -p istore luci-app-store || warn "luci-app-store 安装失败"
  # iStore 的中文翻译内置在 luci-app-store 里，istore 源通常没有独立的
  # luci-i18n-store-zh-cn；只有确实存在时才装，避免每次都报一条假失败
  if [ -d feeds/istore/luci-i18n-store-zh-cn ] || [ -d package/feeds/istore/luci-i18n-store-zh-cn ]; then
    ./scripts/feeds install -d y -p istore luci-i18n-store-zh-cn || warn "luci-i18n-store-zh-cn 安装失败"
  else
    log "istore 源无独立中文包（iStore 中文内置），跳过 luci-i18n-store-zh-cn"
  fi
  found=""
  for p in package/feeds/istore/luci-app-store package/feeds/luci/luci-app-store feeds/istore/luci-app-store; do
    [ -f "$p/Makefile" ] && found="$p" && break
  done
  if [ -n "$found" ]; then
    log "iStore 市场就绪: $found"
  else
    # 不在这里硬失败：配置阶段会校验 CONFIG_PACKAGE_luci-app-store=y
    warn "没找到 luci-app-store 包目录（istore 源可能没拉到），配置阶段会再校验"
  fi

  # iStore 首页（Kwrt 同款 quickstart）：25.12 官方 feeds 不含该包，
  # 需要从 kiddin9/op-packages vendor 到树内 package/。缺依赖时 kconfig 会
  # 静默丢弃 luci-app-quickstart，因此连同 taskd/quickstart 依赖一起 vendor。
  local qsrc='https://github.com/kiddin9/op-packages.git'
  local qpkgs='luci-app-quickstart quickstart taskd luci-lib-taskd luci-lib-xterm'
  if [ -f package/luci-app-quickstart/Makefile ]; then
    log "luci-app-quickstart 已存在，跳过 vendor"
  else
    local tmp; tmp="$(mktemp -d)"
    if git clone -q --depth 1 --filter=blob:none --sparse "$qsrc" "$tmp/repo" 2>/dev/null \
       && ( cd "$tmp/repo" && git sparse-checkout set $qpkgs >/dev/null 2>&1 ); then
      mkdir -p package
      local p
      for p in $qpkgs; do
        [ -f "$tmp/repo/$p/Makefile" ] || continue
        # 先删 feed 里的同名包，确保 kconfig 用树内这份（避免 feed 约束导致静默丢弃）
        rm -rf "package/feeds/kiddin9/$p" "package/feeds/luci/$p" "package/$p"
        cp -a "$tmp/repo/$p" "package/$p"
      done
      log "已 vendor iStore 首页与依赖: $qpkgs"
    else
      warn "克隆 $qsrc 失败，跳过 iStore 首页 vendor（iStore 市场仍可用）"
    fi
    rm -rf "$tmp"
  fi
}

cmd_theme() {
  local theme="$THEME"
  # 无论选哪个主题，先把外部 vendor 进来的 vantage 包清掉：
  # vantage 是复制到 package/ 的，若不走 vantage 分支还留着它，
  # 集合依赖会指向一个没被 .config 选中的包，构建直接失败。
  rm -rf /tmp/vantage-theme package/luci-theme-vantage package/luci-app-vantage

  if [ "$theme" = "vantage" ]; then
    # 必须保证 package/ 存在：否则 `cp -a src package/` 会把 src 的内容摊平到 package/
    mkdir -p package
    # 只取两个包目录（blob 不全下载），比整仓克隆快很多
    if git clone -q --depth 1 --filter=blob:none --sparse "$THEME_REPO" /tmp/vantage-theme 2>/dev/null \
       && ( cd /tmp/vantage-theme && git sparse-checkout set luci-theme-vantage luci-app-vantage >/dev/null 2>&1 ) \
       && [ -d /tmp/vantage-theme/luci-theme-vantage ]; then
      cp -a /tmp/vantage-theme/luci-theme-vantage package/
      [ -d /tmp/vantage-theme/luci-app-vantage ] && cp -a /tmp/vantage-theme/luci-app-vantage package/
    else
      warn "克隆 $THEME_REPO 失败"
    fi

    if [ -f package/luci-theme-vantage/Makefile ] \
       && [ -d package/luci-theme-vantage/htdocs/luci-static/vantage ] \
       && [ -d package/luci-theme-vantage/ucode/template/themes/vantage ]; then
      log "vantage 主题结构符合 24.10（ucode 模板 + luci-static/vantage）"
      grep -E '^PKG_VERSION|^LUCI_DEPENDS' package/luci-theme-vantage/Makefile 2>/dev/null || true
      # 默认展开侧栏（图标 + 菜单文字）：vantage 的 data-rail="pinned" 必须加在 <html>
      # 标签上（CSS 用 html[data-rail=pinned] 匹配，menu-vantage.js 的 this.root 就是
      # documentElement），加到 <nav> 上无效。默认无此属性时左侧只显示图标 rail。
      sed -i 's|<html |<html data-rail="pinned" |' \
        package/luci-theme-vantage/ucode/template/themes/vantage/header.ut
      log "已设置默认展开侧栏（data-rail=pinned）"
    else
      warn "vantage 主题不可用（结构不兼容 24.10），回退 argon"
      rm -rf package/luci-theme-vantage package/luci-app-vantage
      theme=argon
    fi
  else
    # argon：直接用 feeds 自带的 immortalwrt/luci themes/luci-theme-argon，不需要 vendor。
    # 这里只做一次存在性提示（feeds install 顺序不对时能早点看出来），不硬失败。
    theme=argon
    if [ ! -d feeds/luci/themes/luci-theme-argon ] \
       && [ ! -d package/feeds/luci/luci-theme-argon ]; then
      warn "feeds 里暂时没看到 luci-theme-argon（若后续 feeds install 成功则无影响）"
    else
      log "argon 主题来自 feeds：immortalwrt/luci themes/luci-theme-argon"
    fi
  fi
  echo "$theme" > "$THEME_FILE"
  log "本次默认主题: $theme"
}

cmd_collections() {
  local theme f; theme=$(current_theme)
  f=feeds/luci/collections/luci-light/Makefile
  if [ ! -f "$f" ]; then
    warn "找不到 $f，跳过集合依赖改写（.config 里已显式指定主题）"
    return 0
  fi
  # 先清掉之前注入过的主题行（vantage/argon 二选一时必须换掉，否则回退到
  # argon 后集合仍然依赖已被删除的 luci-theme-vantage，构建直接失败）
  sed -i -E '/^[[:space:]]*\+luci-theme-(vantage|argon)[[:space:]]*\\?[[:space:]]*$/d' "$f"
  if grep -q "luci-theme-$theme" "$f"; then
    log "集合包已包含 luci-theme-$theme"
    return 0
  fi
  # 只做「加法」：保留 luci-theme-bootstrap 作运行时兜底，把本次主题追加进
  # LUCI_DEPENDS 列表。插在 bootstrap 那一行前面，两行都以 " \" 结尾，
  # 不会破坏 Makefile 的续行。
  if grep -qE '^[[:space:]]*\+luci-theme-bootstrap[[:space:]]*\\?[[:space:]]*$' "$f"; then
    awk -v t="+luci-theme-$theme" '
      /^[[:space:]]*\+luci-theme-bootstrap/ && !done { printf "\t%s \\\n", t; done=1 }
      { print }
    ' "$f" > "$f.new" && mv "$f.new" "$f"
    log "已把 luci-theme-$theme 加入 luci-light 依赖（bootstrap 保留兜底）"
  else
    warn "$f 里没有 luci-theme-bootstrap 行，不改写（.config 已显式指定主题）"
  fi
  grep -nE "luci-theme-(bootstrap|$theme)" "$f" || true
}

cmd_config() {
  local theme f="${1:-.config}"
  theme=$(current_theme)
  [ -f "$f" ] || { err "配置文件不存在: $f"; return 1; }
  if [ "$theme" = "vantage" ]; then
    sed -i -E 's|^CONFIG_PACKAGE_luci-theme-argon=y|CONFIG_PACKAGE_luci-theme-vantage=y|' "$f"
    sed -i -E 's|^CONFIG_PACKAGE_luci-app-argon-config=y|# CONFIG_PACKAGE_luci-app-argon-config is not set|' "$f"
    grep -q '^CONFIG_PACKAGE_luci-theme-vantage=y$' "$f" || echo 'CONFIG_PACKAGE_luci-theme-vantage=y' >> "$f"
    # 仪表盘（luci-app-vantage）是可选加分项：只有当它自己以及全部 +依赖
    # 都在本次配置里存在时才启用，避免缺包导致整份 .config 编译失败
    if [ -f package/luci-app-vantage/Makefile ]; then
      missing=""
      for dep in luci-base rpcd rpcd-mod-iwinfo rpcd-mod-ucode \
                 ucode-mod-uci ucode-mod-ubus ucode-mod-fs ucode-mod-rtnl ucode-mod-nl80211; do
        if [ -f tmp/.config-package.in ] && ! grep -q "^config PACKAGE_${dep}\$" tmp/.config-package.in; then
          missing="$missing $dep"
        fi
      done
      if [ -z "$missing" ]; then
        grep -q '^CONFIG_PACKAGE_luci-app-vantage=y$' "$f" || echo 'CONFIG_PACKAGE_luci-app-vantage=y' >> "$f"
        log "启用 luci-app-vantage 仪表盘"
      else
        warn "luci-app-vantage 依赖缺失:$missing，跳过仪表盘（主题照常启用）"
      fi
    fi
  else
    # argon：配置栈里本来就是 CONFIG_PACKAGE_luci-theme-argon=y，
    # 这里只做「清掉 vantage 残留 + 缺失时补上」，不重复写入
    sed -i -E 's|^CONFIG_PACKAGE_luci-theme-vantage=y|# CONFIG_PACKAGE_luci-theme-vantage is not set|' "$f"
    sed -i -E 's|^CONFIG_PACKAGE_luci-app-vantage=y|# CONFIG_PACKAGE_luci-app-vantage is not set|' "$f"
    grep -q '^CONFIG_PACKAGE_luci-theme-argon=y$' "$f" || echo 'CONFIG_PACKAGE_luci-theme-argon=y' >> "$f"
  fi
  # 全量简体中文语言包（只对本次构建里存在的包生效；注意要补 CONFIG_ 前缀，
  # tmp/.config-package.in 里的行是 "config PACKAGE_xxx"）
  # 该文件由 make defconfig 的前置目标 prepare-tmpinfo 生成；如果调用时机在
  # defconfig 之前（本仓库的 workflow 都是这样），先手工生成一次。
  if [ ! -f tmp/.config-package.in ]; then
    log "tmp/.config-package.in 不存在，先生成包元数据（make prepare-tmpinfo）"
    if ! make prepare-tmpinfo > /tmp/prepare-tmpinfo.log 2>&1; then
      warn "prepare-tmpinfo 失败，中文语言包可能不全（日志尾部如下）"
      tail -5 /tmp/prepare-tmpinfo.log >&2 || true
    fi
  fi
  if [ -f tmp/.config-package.in ]; then
    # 中文界面开关：luci.mk 里 luci-i18n-*-zh-cn 的 DEFAULT:=LUCI_LANG_zh_Hans，
    # 不打开这个开关，全量枚举出来的 zh-cn =y 会在 defconfig 时被压回 n，
    # 表现就是「装了一堆中文包，界面还是英文」。
    # 注意：.config-package.in 里的 config 行可能带 tab/空格前缀（package-metadata.pl
    # 的缩进），所以判定符号时必须允许行首空白，否则会出现「元数据明明有、却报缺失」
    if grep -qE '^[[:space:]]*config LUCI_LANG_zh_Hans$' tmp/.config-package.in; then
      grep -qxF 'CONFIG_LUCI_LANG_zh_Hans=y' "$f" || echo 'CONFIG_LUCI_LANG_zh_Hans=y' >> "$f"
      log "已打开 CONFIG_LUCI_LANG_zh_Hans（中文界面开关）"
    else
      warn "元数据里没有 LUCI_LANG_zh_Hans 符号，跳过语言开关"
    fi
    # iStore 市场 + 它的中文语言包（后者多数版本没有，存在才写，避免污染 kconfig）
    for p in luci-app-store luci-i18n-store-zh-cn; do
      if grep -qE "^[[:space:]]*config PACKAGE_${p}\$" tmp/.config-package.in; then
        grep -qxF "CONFIG_PACKAGE_${p}=y" "$f" || echo "CONFIG_PACKAGE_${p}=y" >> "$f"
      elif [ "$p" = "luci-i18n-store-zh-cn" ]; then
        log "元数据里没有 PACKAGE_${p}（iStore 中文内置），跳过"
      else
        warn "元数据里没有 PACKAGE_${p}（istore feed 可能没拉到）"
      fi
    done
    awk '/^[[:space:]]*config PACKAGE_luci-i18n-.+-zh-cn$/{print "CONFIG_"$2"=y"}' tmp/.config-package.in > /tmp/zh-i18n.txt || true
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      grep -qxF "$line" "$f" || echo "$line" >> "$f"
    done < /tmp/zh-i18n.txt
    log "简体中文语言包: $(wc -l < /tmp/zh-i18n.txt) 个候选"
  fi
  log "已按主题 $theme 处理 $f"
}

cmd_wifi() {
  mkdir -p files/etc/uci-defaults
  cat > files/etc/uci-defaults/99-wifi-boost <<'SH'
#!/bin/sh
# 无线首启增强（全机型通用，按 band 自动判断，不要手改各机型分支）：
#   - 国码 CN + 802.11d 国码广播（部分驱动据此放开功率上限）
#   - 5G/6G 开 160MHz（HE160）；2.4G 最高 HE40 —— 给 2.4G 强塞 HE160 会让 radio 起不来
#   - 802.11k/v/r 快速漫游、HE SU beamformee、关掉 disassoc_low_ack 的伪断连
[ -f /etc/config/wireless ] || exit 0

for r in $(uci -q show wireless | sed -n 's/^wireless\.\(radio[0-9]\+\)=.*/\1/p'); do
  band=$(uci -q get wireless.$r.band)
  if [ -z "$band" ]; then
    case "$(uci -q get wireless.$r.hwmode)" in
      11a|11ac|11ax|11be) band=5g ;;
      *)                  band=2g ;;
    esac
  fi
  uci -q set wireless.$r.disabled='0'
  uci -q set wireless.$r.country='CN'
  uci -q set wireless.$r.ieee80211d='1'
  case "$band" in
    5g|6g)
      uci -q set wireless.$r.channel='auto'
      uci -q set wireless.$r.htmode='HE160'
      ;;
    2g)
      uci -q set wireless.$r.htmode='HE40'
      ;;
  esac
  echo "wifi-boost: $r band=$band htmode=$(uci -q get wireless.$r.htmode)"
done

for i in $(uci -q show wireless | sed -n 's/^wireless\.\(@wifi-iface\[[0-9]\+\]\)=.*/\1/p'); do
  uci -q set wireless.$i.ieee80211k='1'
  uci -q set wireless.$i.ieee80211v='1'
  uci -q set wireless.$i.ieee80211r='1'
  uci -q set wireless.$i.he_su_beamformee='1'
  uci -q set wireless.$i.disassoc_low_ack='0'
done

uci -q commit wireless
exit 0
SH
  chmod +x files/etc/uci-defaults/99-wifi-boost
  log "已写入 99-wifi-boost（国码 CN + 5G 160MHz + 802.11k/v/r + beamformee）"
}

cmd_uci_defaults() {
  local theme; theme=$(current_theme)
  mkdir -p files/etc/uci-defaults
  if [ "$theme" = "vantage" ]; then
    cat > files/etc/uci-defaults/99-luci-theme-vantage <<'SH'
#!/bin/sh
uci -q set luci.themes.Vantage='/luci-static/vantage'
uci -q set luci.main.mediaurlbase='/luci-static/vantage'
uci -q commit luci
exit 0
SH
    chmod +x files/etc/uci-defaults/99-luci-theme-vantage
  else
    cat > files/etc/uci-defaults/99-luci-theme-argon <<'SH'
#!/bin/sh
uci -q set luci.themes.Argon='/luci-static/argon'
uci -q set luci.main.mediaurlbase='/luci-static/argon'
uci -q commit luci
exit 0
SH
    chmod +x files/etc/uci-defaults/99-luci-theme-argon
  fi
  log "已写入 99-luci-theme-$theme"

  # 默认语言强制简体中文：LuCI 与 iStore 市场都跟随 luci.main.lang，
  # 只装 luci-i18n-store-zh-cn 而不改这个，市场仍按浏览器语言显示英文。
  cat > files/etc/uci-defaults/99-luci-lang-zh-cn <<'SH'
#!/bin/sh
uci -q set luci.main.lang='zh_cn'
uci -q commit luci
exit 0
SH
  chmod +x files/etc/uci-defaults/99-luci-lang-zh-cn
  log "已写入 99-luci-lang-zh-cn（luci.main.lang=zh_cn，iStore 跟随）"

  cmd_wifi
}

case "${1:-}" in
  feed)         cmd_feed ;;
  store)        cmd_store ;;
  theme)        cmd_theme ;;
  collections)  cmd_collections ;;
  config)       shift; cmd_config "${1:-.config}" ;;
  wifi)         cmd_wifi ;;
  uci-defaults) cmd_uci_defaults ;;
  *) echo "用法: $0 {feed|store|theme|collections|config <file>|wifi|uci-defaults}"; exit 2 ;;
esac
