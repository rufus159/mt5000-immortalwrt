#!/usr/bin/env bash
#
# build-local.sh — 在本地（Linux / WSL / NAS 虚拟机）编译 GL.iNet MT5000 的
#                  ImmortalWrt 固件，逻辑与 .github/workflows/build-mt5000.yml
#                  的构建步骤保持一致。
#
# 为什么要有这个脚本：
#   workflow 把 597 行构建逻辑内联在 YAML 的 `run:` 里，本地没法直接复用。
#   这里把它们抽出来，让 CI 和本地跑同一套流程 —— 改补丁时不必等 2.5 小时的
#   CI，本地增量编译十几分钟就能出结果；CI 出问题时也能在本地复现。
#
# 与 CI 的差异（刻意为之，不是遗漏）：
#   * 不做 GitHub 专属的事：缓存 prune/restore、artifact 上传、Release 发布
#   * ccache 上限放大到 5G（CI 限 1G 是因为仓库缓存总配额 10G，本地没这约束）
#   * 允许从任意步骤断点续跑（--from），CI 每次都从头
#   * 并行度按「内存」而非「核数」决定，避免 OOM（见 resolve_jobs）
#
# 用法：
#   ./scripts/build-local.sh                     # 最简：全默认，编 master
#   ./scripts/build-local.sh --jobs 12           # 指定并行度
#   ./scripts/build-local.sh --from build        # 从编译步骤续跑（复用已下载+已配置）
#   ./scripts/build-local.sh --clean             # 清掉源码树重来
#   ./scripts/build-local.sh --help              # 看全部参数
#
set -euo pipefail

# ============================================================================
# 常量
# ============================================================================

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# master 默认基线。改动这里时同步改 .github/workflows/build-mt5000.yml
# 的 IWRT_REF 表达式，否则本地和 CI 会编出不同固件。
REF_MASTER_DEFAULT=f44d1535b4

IMMORTALWRT_GIT=https://github.com/immortalwrt/immortalwrt

# ============================================================================
# 输出
# ============================================================================

if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
    C_BLU=$'\033[34m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_DIM=''; C_RST=''
fi

log()  { printf '%s==>%s %s\n' "$C_BLU" "$C_RST" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%swarn%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '%serr %s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
dim()  { printf '%s     %s%s\n' "$C_DIM" "$*" "$C_RST"; }

step_banner() {
    printf '\n%s%s══ %s ══%s\n' "$C_BLU" "" "$*" "$C_RST"
}

# ============================================================================
# 默认参数（名字与 workflow 的 inputs 一一对应，方便照抄 CI 的某次运行）
# ============================================================================

IWRT_REF=${IWRT_REF:-}
SRC_DIR=${SRC_DIR:-$REPO_ROOT/immortalwrt}

LAN_IP=${LAN_IP:-10.0.0.1}
TIMEZONE=${TIMEZONE:-Asia/Shanghai}
UI_LANG=${UI_LANG:-zh-cn}
ROOTFS_SIZE=${ROOTFS_SIZE:-2048}

EXTRA_SERVICES=${EXTRA_SERVICES:-none}  # none | mwan3 | docker | docker+mwan3

PPPOE=${PPPOE:-false}
PPPOE_USERNAME=${PPPOE_USERNAME:-}
PPPOE_PASSWORD=${PPPOE_PASSWORD:-}

ENABLE_IPV6=${ENABLE_IPV6:-false}
LAN_IPV6_ASSIGN=${LAN_IPV6_ASSIGN:-64}
LAN_IPV6_SUFFIX=${LAN_IPV6_SUFFIX:-eui64}
LAN_IPV6_DHCPV6=${LAN_IPV6_DHCPV6:-disabled}
LAN_IPV6_DNS=${LAN_IPV6_DNS:-false}

# 注意：不能叫 HOSTNAME —— bash 会把它设成本机主机名（实测 thinkbook16s），
# ${HOSTNAME:-ImmortalWrt} 永远取不到默认值，固件里会被刷成编译机的主机名。
ROUTER_HOSTNAME=${ROUTER_HOSTNAME:-ImmortalWrt}
ROOT_PASSWORD=${ROOT_PASSWORD:-root}

EXTRA_FEEDS=${EXTRA_FEEDS:-}
EXTRA_PACKAGES=${EXTRA_PACKAGES:-}

JOBS=${JOBS:-}          # 空 = 按内存自动算
FROM_STEP=${FROM_STEP:-validate}
CLEAN=0
SKIP_DOWNLOAD=0
DRY_RUN=0

# 由 resolve_* 派生
INCLUDE_DOCKER=false
ENABLE_MWAN3=false
PATCHDIR=''
BASE_SHA=''

# ============================================================================
# 用法
# ============================================================================

usage() {
    cat <<'USAGE'
build-local.sh — 本地编译 GL.iNet MT5000 (Brume 3) 的 ImmortalWrt 固件

基本：
  --ref <commit|branch>       覆盖默认基线（默认 master→f44d1535b4）
  --src <dir>                 源码目录（默认 <repo>/immortalwrt）
  --jobs <N>                  编译并行度（默认按可用内存自动算）
  --clean                     删除并重新克隆源码树（会丢增量编译成果）
  --from <step>               从指定步骤开始：validate|clone|patch|overlay|
                              config|uci|download|build（默认 validate）
  --skip-download             跳过 make download
  --dry-run                   只打印解析后的配置，不执行

网络与系统（对应 workflow 同名 input）：
  --lan-ip <ip>               默认 LAN IP（默认 10.0.0.1）
  --hostname <name>           主机名（默认 ImmortalWrt）
  --root-password <pw>        root 密码（默认 root；空字符串=不设密码）
  --timezone <tz>             时区（默认 Asia/Shanghai）
  --lang zh-cn|en             LuCI 语言（默认 zh-cn）
  --rootfs-size <MB>          软件包分区大小（默认 2048）

软件包：
  --extra-services none|mwan3|docker|docker+mwan3   附加服务（默认 none）
  --extra-feeds '<line>|<line>'  追加 feeds.conf 行，多个用 | 分隔
  --extra-packages '<pkg> <pkg>' 额外编入的包

PPPoE / IPv6：
  --pppoe                     预置 PPPoE 拨号
  --pppoe-username <user>
  --pppoe-password <pass>
  --enable-ipv6               启用 IPv6（WAN 委托前缀 + LAN RA/SLAAC）
  --ipv6-assign 56|60|64|disabled
  --ipv6-suffix eui64|random|::1
  --ipv6-dhcpv6 disabled|server
  --ipv6-dns                  LAN 通告路由器为 IPv6 DNS

  -h, --help                  显示本帮助

环境变量：以上参数均可改用同名大写环境变量传入（LAN_IP=... ./build-local.sh），
          与 GitHub Actions 的 input 名一致，便于照抄某次 CI 运行的配置。

例子：
  # 复现 r11 那次构建（全默认：只有官方包集 + seed 里的那几项）
  ./scripts/build-local.sh

  # 改完补丁后增量重编，只跑 build
  ./scripts/build-local.sh --from build

  # 给 NAS 虚拟机用：16G 内存里给 12G，降到 -j9
  ./scripts/build-local.sh --jobs 9
USAGE
}

# ============================================================================
# 参数解析
# ============================================================================

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --ref)              IWRT_REF="$2"; shift 2 ;;
            --src)              SRC_DIR="$2"; shift 2 ;;
            --jobs)             JOBS="$2"; shift 2 ;;
            --clean)            CLEAN=1; shift ;;
            --from)             FROM_STEP="$2"; shift 2 ;;
            --skip-download)    SKIP_DOWNLOAD=1; shift ;;
            --dry-run)          DRY_RUN=1; shift ;;

            --lan-ip)           LAN_IP="$2"; shift 2 ;;
            --hostname)         ROUTER_HOSTNAME="$2"; shift 2 ;;
            --root-password)    ROOT_PASSWORD="$2"; shift 2 ;;
            --timezone)         TIMEZONE="$2"; shift 2 ;;
            --lang)             UI_LANG="$2"; shift 2 ;;
            --rootfs-size)      ROOTFS_SIZE="$2"; shift 2 ;;

            --extra-services)   EXTRA_SERVICES="$2"; shift 2 ;;
            --extra-feeds)      EXTRA_FEEDS="$2"; shift 2 ;;
            --extra-packages)   EXTRA_PACKAGES="$2"; shift 2 ;;

            --pppoe)            PPPOE=true; shift ;;
            --pppoe-username)   PPPOE_USERNAME="$2"; shift 2 ;;
            --pppoe-password)   PPPOE_PASSWORD="$2"; shift 2 ;;

            --enable-ipv6)      ENABLE_IPV6=true; shift ;;
            --ipv6-assign)      LAN_IPV6_ASSIGN="$2"; shift 2 ;;
            --ipv6-suffix)      LAN_IPV6_SUFFIX="$2"; shift 2 ;;
            --ipv6-dhcpv6)      LAN_IPV6_DHCPV6="$2"; shift 2 ;;
            --ipv6-dns)         LAN_IPV6_DNS=true; shift ;;

            -h|--help)          usage; exit 0 ;;
            *)                  die "未知参数: $1（--help 看用法）" ;;
        esac
    done
}

# ============================================================================
# 输入校验 + 派生（对应 workflow 的 Validate inputs）
# ============================================================================

resolve_inputs() {
    # 基线解析必须放在最前面：CI 里这段原本在 Validate inputs 步骤，而
    # Prune caches 是第 1 步 —— 那时 IWRT_REF 还是空字符串，导致缓存匹配
    # 模式变成 "dl--" / "stage--"，把该保留的缓存全删了。本地脚本没有缓存
    # prune，但把解析提到最前是正确的做法，CI 侧也要照此修正。
    if [ -n "$IWRT_REF" ]; then
        dim "显式指定基线: $IWRT_REF"
    else
        IWRT_REF=$REF_MASTER_DEFAULT
        dim "master 默认基线: $IWRT_REF"
    fi


    case "$EXTRA_SERVICES" in
        none)          INCLUDE_DOCKER=false; ENABLE_MWAN3=false ;;
        mwan3)         INCLUDE_DOCKER=false; ENABLE_MWAN3=true  ;;
        docker)        INCLUDE_DOCKER=true;  ENABLE_MWAN3=false ;;
        docker+mwan3)  INCLUDE_DOCKER=true;  ENABLE_MWAN3=true  ;;
        *) die "非法 extra_services: $EXTRA_SERVICES" ;;
    esac

    case "$UI_LANG" in zh-cn|en) ;; *) die "非法 lang: $UI_LANG（zh-cn/en）" ;; esac

    # CI 那边只查了 ^(\d{1,3}\.){3}\d{1,3}$，999.1.1.1 也能过。本地要真用这个
    # IP 去写 preinit，顺手把每段范围也校验掉。
    printf '%s' "$LAN_IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
        || die "非法 LAN IP: $LAN_IP"
    local _o
    # 用 10# 强制十进制：bash 的 [ 会把 08/09 当非法八进制而报错
    for _o in $(printf '%s' "$LAN_IP" | tr '.' ' '); do
        [ "$((10#$_o))" -le 255 ] || die "非法 LAN IP: $LAN_IP（某段大于 255）"
    done
    printf '%s' "$ROOTFS_SIZE" | grep -qE '^[0-9]+$' \
        || die "非法 rootfs-size: $ROOTFS_SIZE（要整数 MB）"

    if [ "$PPPOE" = "true" ] && [ -z "$PPPOE_USERNAME" ]; then
        die "启用了 PPPoE 但未给 --pppoe-username"
    fi
    if [ "$PPPOE" = "true" ] && [ -z "$PPPOE_PASSWORD" ]; then
        die "启用了 PPPoE 但未给 --pppoe-password"
    fi
    if [ "$ENABLE_IPV6" = "true" ]; then
        case "$LAN_IPV6_ASSIGN" in 56|60|64|disabled) ;; *) die "非法 ipv6-assign: $LAN_IPV6_ASSIGN" ;; esac
        case "$LAN_IPV6_SUFFIX" in eui64|random|::1) ;; *) die "非法 ipv6-suffix: $LAN_IPV6_SUFFIX" ;; esac
        case "$LAN_IPV6_DHCPV6" in disabled|server) ;; *) die "非法 ipv6-dhcpv6: $LAN_IPV6_DHCPV6" ;; esac
    fi

    case "$FROM_STEP" in
        validate|clone|patch|overlay|config|uci|download|build) ;;
        *) die "非法 --from: $FROM_STEP（可选 validate|clone|patch|overlay|config|uci|download|build）" ;;
    esac

    PATCHDIR=$REPO_ROOT/patches
    [ -d "$PATCHDIR" ] || die "补丁目录不存在: $PATCHDIR"
}

# 并行度：按内存而非核数。一次编译进程峰值约 1~1.5G，核多内存少会 OOM。
resolve_jobs() {
    local nproc_n mem_gb auto
    nproc_n=$(nproc 2>/dev/null || echo 4)
    mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 8)

    if [ -z "$JOBS" ]; then
        # 每进程按 1.3G 估，留 1G 给系统
        auto=$(( (mem_gb - 1) * 10 / 13 ))
        [ "$auto" -lt 1 ] && auto=1
        [ "$auto" -gt "$nproc_n" ] && auto=$nproc_n
        JOBS=$auto
        JOBS_NOTE="按内存 ${mem_gb}G / ${nproc_n} 核自动算出"
    else
        JOBS_NOTE="手动指定"
    fi

    # 内存不够时明确警告，不要让用户在 3 小时后看到 OOM killer
    local need=$(( JOBS * 13 / 10 ))
    if [ "$need" -gt "$mem_gb" ]; then
        warn "-j${JOBS} 预计需要约 ${need}G 内存，但只有 ${mem_gb}G。"
        warn "可能被 OOM killer 杀掉（症状：编译中途无提示退出、dmesg 有 Killed process）。"
        warn "建议降到 --jobs $(( mem_gb * 10 / 13 ))。"
    fi
}

print_config() {
    local d=$([ "$DRY_RUN" = "1" ] && echo "(dry-run) " || echo "")
    # 标签一律用 ASCII：printf 的 %-18s 按字节补空格，中文一个字 3 字节但只占
    # 2 列宽，混排必然错位（试过用 ${#label} 算宽度，在 Git Bash 下拿到的是
    # 字节数，反而更歪）。中文说明放代码注释里，标签保持可对齐。
    printf '\n%s%s构建配置%s\n' "$C_BLU" "$d" "$C_RST"
    printf '  %-13s %s\n' "ref"          "$IWRT_REF"
    printf '  %-13s %s\n' "patch dir"    "${PATCHDIR#$REPO_ROOT/}"
    printf '  %-13s %s\n' "source dir"   "$SRC_DIR"
    printf '  %-13s %s\n' "jobs"         "$JOBS  ($JOBS_NOTE)"
    printf '  %-13s %s\n' "lan ip"       "$LAN_IP"
    printf '  %-13s %s\n' "hostname"     "$ROUTER_HOSTNAME"
    printf '  %-13s %s\n' "timezone"     "$TIMEZONE / $UI_LANG"
    printf '  %-13s %s\n' "rootfs size"  "${ROOTFS_SIZE} MB"
    printf '  %-13s %s\n' "luci"         "luci 全套 (seed 固定, 含 uhttpd)"
    printf '  %-13s %s\n' "services"     "$EXTRA_SERVICES"
    printf '  %-13s %s\n' "pppoe"        "$PPPOE"
    printf '  %-13s %s\n' "ipv6"         "$ENABLE_IPV6"
    printf '  %-13s %s\n' "from step"    "$FROM_STEP"
    printf '\n'
}

# ============================================================================
# 前置检查
# ============================================================================

check_prereq() {
    step_banner "前置检查"

    # 大小写敏感 —— OpenWrt 的 include/prereq-build.mk 有 case-sensitive-fs
    # 硬检查，不敏感的文件系统上 make 会在 deconfig 阶段直接失败。WSL 挂在
    # /mnt/c、/mnt/e 的 Windows 盘就是典型反例（实测不敏感）。
    local probe="$SRC_DIR/../.cstest.$$"
    mkdir -p "$(dirname "$probe")"
    : > "$probe"
    if [ -e "${probe%.*}.CSTEST.$$" ] 2>/dev/null; then
        rm -f "$probe"; die "目标目录大小写不敏感，OpenWrt 无法在此编译: $(dirname "$probe")"
    fi
    rm -f "$probe"
    ok "文件系统大小写敏感"

    # umask 必须是 022，否则打出来的包权限错乱（OpenWrt 也会检查）
    local um
    um=$(umask)
    case "$um" in
        022|0022) ok "umask $um" ;;
        *) warn "umask 是 $um，OpenWrt 要求 022。建议先执行 umask 022" ;;
    esac

    # 源码目录之外还需要的工具
    local missing=''
    for t in git make gcc g++ awk grep sed xargs find; do
        command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    [ -n "$missing" ] || ok "基础工具齐全"

    # OpenWrt 的完整依赖清单（与 workflow 的 Install build dependencies 同源，
    # 但不装 GUI 无关的东西）。缺了不致命 —— make 会自己报 —— 只做提示。
    local hint=''
    for p in gcc-multilib libncurses-dev zlib1g-dev libssl-dev rsync unzip \
             bzip2 patch subversion swig python3 python3-ply python3-docutils \
             device-tree-compiler cpio rsync gettext flex bison pkg-config \
             libelf-dev libltdl-dev libmpc-dev libmpfr-dev libgmp-dev \
             squashfs-tools mkisofs xxd; do
        if command -v dpkg >/dev/null 2>&1 && ! dpkg -s "$p" >/dev/null 2>&1; then
            hint="$hint $p"
        fi
    done
    if [ -n "$hint" ]; then
        warn "以下开发包似乎未安装（若编译报错再来补）:"
        printf '       sudo apt install -y --no-install-recommends \\\n          %s\n' "$(echo $hint)" >&2
        dim "完整清单见 .github/workflows/build-mt5000.yml 的 Install build dependencies"
    fi

    if [ -n "$missing" ]; then
        die "缺少必需工具:$missing"
    fi

    # openssl 只在设 root 密码时用到
    if [ -n "${ROOT_PASSWORD:-}" ] && ! command -v openssl >/dev/null 2>&1; then
        die "设置 root 密码需要 openssl，请先安装"
    fi

    # 磁盘：编译峰值约 45G（build_dir 20-40G + dl 2.5G + staging_dir 4G）
    local avail_gb
    avail_gb=$(df -BG --output=avail "$(dirname "$SRC_DIR")" 2>/dev/null | tail -1 | tr -dc '0-9')
    if [ -n "$avail_gb" ]; then
        if [ "$avail_gb" -lt 45 ]; then
            warn "可用磁盘 ${avail_gb}G，全量编译约需 45G。可能中途空间不足。"
        else
            ok "磁盘可用 ${avail_gb}G"
        fi
    fi
}

# ============================================================================
# 步骤判定
# ============================================================================

# 步骤按固定顺序排列，--from 之后的所有步骤都执行
step_index() {
    case "$1" in
        validate) echo 0 ;; clone) echo 1 ;; patch) echo 2 ;; overlay) echo 3 ;;
        config)   echo 4 ;; uci)   echo 5 ;; download) echo 6 ;;
        build)    echo 7 ;; *) die "未知步骤: $1" ;;
    esac
}

should_run() {
    [ "$(step_index "$1")" -ge "$(step_index "$FROM_STEP")" ]
}

# 读当前源码树的 HEAD 作为 BASE_SHA。--from patch 及以后会跳过 do_clone，
# 若不在这里补上，BASE_SHA 会是空串，do_patch 的标记和 reset 目标就都错了。
resolve_base_sha() {
    [ -n "$BASE_SHA" ] && return 0
    [ -d "$SRC_DIR/.git" ] || die "源码树不存在: $SRC_DIR（先跑 clone，或去掉 --from）"
    BASE_SHA=$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null) \
        || die "无法读取 $SRC_DIR 的 HEAD"
    dim "沿用现有源码树 HEAD: ${BASE_SHA:0:12}"
}



do_clone() {
    step_banner "克隆 ImmortalWrt 源码"

    if [ "$CLEAN" = "1" ] && [ -d "$SRC_DIR" ]; then
        log "  --clean: 删除 $SRC_DIR"
        rm -rf "$SRC_DIR"
    fi

    if [ -d "$SRC_DIR/.git" ]; then
        ok "复用已有源码树: $SRC_DIR"
        if [ -z "${GIT_NO_FETCH:-}" ]; then
            log "  增量 fetch 上游（要跳过可设 GIT_NO_FETCH=1）"
            git -C "$SRC_DIR" fetch --filter=blob:none origin \
                '+refs/heads/master:refs/remotes/origin/master' \
                --quiet || warn "fetch 失败（离线？），沿用本地已有对象"
        fi
    else
        log "  git clone --filter=blob:none（约 2.5G 下载，首次较慢）"
        mkdir -p "$(dirname "$SRC_DIR")"
        git clone --filter=blob:none "$IMMORTALWRT_GIT" "$SRC_DIR"
    fi

    cd "$SRC_DIR"
    git config advice.detachedHead false

    # 用 cat-file -e 而不是 rev-parse --verify：带 --filter=blob:none 的
    # partial clone 下，对不存在的对象 rev-parse 会先尝试 lazy-fetch，拿到
    # "not our ref" 之后仍可能吐出一个前缀匹配到的近似 SHA 且退出码为 0。
    if ! git cat-file -e "${IWRT_REF}^{commit}" 2>/dev/null; then
        {
            echo "基线 ${IWRT_REF} 在本地仓库中不存在（上游已 rebase 或 gc 回收）"
            echo "可用基线："
            git ls-remote origin 'refs/heads/master' 2>/dev/null | sed 's/^/  /'
            echo "把上面的 SHA 用 --ref 传进来即可"
        } >&2
        die "基线不存在: $IWRT_REF"
    fi

    git checkout --detach "$IWRT_REF" --quiet
    BASE_SHA=$(git rev-parse HEAD)
    ok "基线: ${BASE_SHA:0:12} ($(git log -1 --format='%cI' | cut -dT -f1)) $(git log -1 --format='%s')"

    # 对象存在 ≠ 长期可用：上游 force-push 后旧提交会变悬空对象，本次能编，
    # 下次 gc 就没了。
    if [ -z "$(git tag --points-at "$BASE_SHA")" ] \
       && ! git merge-base --is-ancestor "$BASE_SHA" origin/master 2>/dev/null; then
        warn "基线 ${BASE_SHA:0:12} 不是 tag 也不在 master 可达历史里 —— 悬空对象，上游下次 gc 会回收"
    fi
}

# ============================================================================
# 2. 应用补丁（对应 Apply MT5000 device patch）
# ============================================================================

do_patch() {
    step_banner "应用 MT5000 补丁"

    cd "$SRC_DIR"

    # 幂等性不能靠「逐个补丁反向 apply --check」判断。反例就在本仓库里：
    #   0001 创建 target/linux/generic/pending-6.18/795-10-...patch
    #   0006 又修改了这个文件（给内层 dsa.c 加 get_stats64）
    #   0008 再改一次（加 port_max_mtu）
    # 全链应用后，0001 反向检查会因 795-10 已被 0006/0008 改过而失败，
    # 于是被误判成「没打过」，再正向 apply 又撞 already exists —— 死锁。
    #
    # 改用标记文件：记下「哪个基线 + 哪批补丁」已经应用过。标记匹配就整段
    # 跳过；不匹配就把 tracked 文件重置回基线再重新打一遍。build_dir/、
    # staging_dir/、dl/、bin/ 都是 untracked，git reset --hard 不会碰它们，
    # 所以重置不会毁掉已有的编译成果。
    local marker="$SRC_DIR/.mt5000-patches.applied"
    local base="${BASE_SHA:-$IWRT_REF}"
    local want
    want=$( { echo "base=$base";
              for p in "$PATCHDIR"/*.patch; do basename "$p"; done; } )

    if [ -f "$marker" ] && [ "$(cat "$marker")" = "$want" ]; then
        ok "补丁链已是目标状态（基线 ${base:0:12}, $(ls "$PATCHDIR"/*.patch | wc -l) 个），跳过"
        return 0
    fi

    # 之前打过一半或换了配置档 —— 把代码树退回基线，避免叠加冲突。
    #
    # 关键：必须先把「补丁新建的文件」纳入索引，否则 git reset --hard 不会删
    # 它们（untracked 文件 reset 不管）。这里靠 --index 记录，配合下面那轮
    # 「清掉所有补丁引入的 untracked 文件」。实测：不加 --index 时，0001 新建
    # 的 795-10/11/12、dts 会残留在树上，第二次跑就撞 "already exists"。
    #
    # build_dir/ staging_dir/ dl/ bin/ feeds/ 都是 untracked 且不在补丁文件
    # 清单里，下面的清理只针对补丁涉及的具体路径，不会误删编译成果。
    if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
        log "  工作区有改动，重置回基线（build_dir/staging_dir/dl 不受影响）"
        git reset --hard "$base" -q
    fi
    # 清掉补丁新建但尚未跟踪的残留文件（只认补丁清单里的路径）
    _purge_patch_untracked

    local n=0 p name
    for p in "$PATCHDIR"/*.patch; do
        [ -e "$p" ] || die "补丁目录为空: $PATCHDIR"
        name=$(basename "$p")

        if git apply --check "$p" >/dev/null 2>&1; then
            # --index：新建文件同时进索引，下次重置时能被 reset --hard 清掉
            git apply --index "$p"
            ok "  $name"
            n=$((n+1))
        else
            {
                echo "补丁应用失败: $name"
                echo "基线=$base"
                echo
                echo "常见原因："
                echo "  1. 基线漂移 —— 上游动过补丁涉及的代码行，需要重新生成该 hunk"
                echo "  2. 补丁顺序错 —— 后面的补丁依赖前面的（如 0008 依赖 0006）"
                echo "  3. 源码树有非补丁的残留改动 —— 用 --clean 重来"
                echo
                echo "定位真实冲突："
                echo "  cd $SRC_DIR && git apply --check -v '$p'"
            } >&2
            rm -f "$marker"
            die "补丁链断裂于 $name"
        fi
    done

    printf '%s' "$want" > "$marker"
    ok "补丁完成：应用 $n 个"
}

# 删除「补丁新建、但当前未被跟踪」的文件。路径清单直接从补丁里解析
# （+++ b/ 且该 hunk 是 new file），保证只动补丁涉及的文件，
# 绝不扫 build_dir / staging_dir / dl / feeds。
_purge_patch_untracked() {
    local p f
    local -a files=()
    # 收集所有 "new file mode ... +++ b/<path>" 的路径
    for p in "$PATCHDIR"/*.patch; do
        [ -e "$p" ] || continue
        # 按 diff 段分割，找 new file mode 段里的 +++ 行
        awk '
            /^diff --git /   { isnew=0; next }
            /^new file mode/ { isnew=1; next }
            isnew && /^\+\+\+ b\// { print substr($0, 7); isnew=0 }
        ' "$p"
    done | sort -u > "$SRC_DIR/.mt5000-newfiles.tmp"

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        # 只删未跟踪的；已跟踪的交给 reset --hard
        if [ -e "$SRC_DIR/$f" ] \
           && ! git -C "$SRC_DIR" ls-files --error-unmatch "$f" >/dev/null 2>&1; then
            rm -f "$SRC_DIR/$f"
            dim "  清理残留: $f"
        fi
    done < "$SRC_DIR/.mt5000-newfiles.tmp"
    rm -f "$SRC_DIR/.mt5000-newfiles.tmp"
}

# ============================================================================
# 3. overlay + feeds（对应 Overlay files/ and feeds）
# ============================================================================

do_overlay() {
    step_banner "覆盖 files/ 并准备 feeds"

    cd "$SRC_DIR"
    cp -r "$REPO_ROOT/files/." ./
    ok "files/ overlay 已复制"

    # 只用官方 feeds：固件包集 = 官方 filogic 默认 + config/mt5000.seed 显式项。
    # 第三方源（istore / wukongdaily / nas-packages）已整块删除；确需某个第三方
    # 包时走 --extra-feeds + --extra-packages。
    local added=0
    if [ -n "$EXTRA_FEEDS" ]; then
        printf '%s' "$EXTRA_FEEDS" | tr '|' '\n' | while IFS= read -r FEEDLINE; do
            FEEDLINE=$(printf '%s' "$FEEDLINE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            case "$FEEDLINE" in ''|'#'*) continue ;; esac
            echo "$FEEDLINE" >> feeds.conf.default
            echo "  追加 feed: $FEEDLINE"
        done
        added=$((added+1))
    fi
    if [ "$added" = "0" ]; then
        ok "未启用任何第三方 feed（官方源 only）"
    else
        warn "已追加 $added 个第三方 feed —— 产出的固件不是纯官方源"
    fi

    log "  feeds update -a（首次约 3-5 分钟）"
    ./scripts/feeds update -a >/dev/null
    ok "feeds update 完成"

    log "  feeds install -a"
    ./scripts/feeds install -a >/dev/null
    ok "feeds install 完成"

    if [ -n "$EXTRA_FEEDS" ]; then
        for FEED in $(printf '%s' "$EXTRA_FEEDS" | tr '|' '\n' \
                      | sed -n 's/^src-git[[:space:]][[:space:]]*\([^ ;]*\).*/\1/p'); do
            ./scripts/feeds install -a -f -p "$FEED" || warn "feed $FEED 强制安装失败（名称是否正确？）"
        done
    fi
}

# ============================================================================
# 4. 生成 .config（对应 Generate .config）
# ============================================================================

do_config() {
    step_banner "生成 .config"

    cd "$SRC_DIR"
    cp "$REPO_ROOT/config/mt5000.seed" .config

    # --- 参数化 ---
    local LAN_BC="${LAN_IP%.*}.255"
    sed -i "s|^CONFIG_TARGET_ROOTFS_PARTSIZE=.*|CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_SIZE|" .config
    sed -i "s|^CONFIG_TARGET_PREINIT_IP=.*|CONFIG_TARGET_PREINIT_IP=\"$LAN_IP\"|" .config
    sed -i "s|^CONFIG_TARGET_PREINIT_BROADCAST=.*|CONFIG_TARGET_PREINIT_BROADCAST=\"$LAN_BC\"|" .config

    # 语言: default-settings-chn 依赖 @LUCI_LANG_zh_Hans + luci-i18n-base-zh-cn，
    # 中文 i18n 一定在固件里；默认界面语言由首启脚本 99-luci-lang 决定
    # （写 luci.main.lang=zh_cn 即中文，不写则按浏览器协商）。

    # LuCI 全套由 config/mt5000.seed 的 CONFIG_PACKAGE_luci=y 保证
    # （master 的 include/target.mk 不追加 tweak 段，必须显式选中）

    if [ "$INCLUDE_DOCKER" = "true" ]; then
        printf '%s\n' \
          'CONFIG_KERNEL_CGROUPS=y' \
          'CONFIG_KERNEL_CGROUP_CPUACCT=y' \
          'CONFIG_KERNEL_CGROUP_DEVICE=y' \
          'CONFIG_KERNEL_CGROUP_FREEZER=y' \
          'CONFIG_KERNEL_CGROUP_SCHED=y' \
          'CONFIG_KERNEL_MEMCG=y' \
          'CONFIG_KERNEL_NAMESPACES=y' \
          'CONFIG_PACKAGE_cgroupfs-mount=y' \
          'CONFIG_PACKAGE_docker=y' \
          'CONFIG_PACKAGE_dockerd=y' \
          'CONFIG_PACKAGE_luci-app-dockerman=y' >> .config
    fi

    if [ "$ENABLE_MWAN3" = "true" ]; then
        printf '%s\n' \
          'CONFIG_PACKAGE_mwan3=y' \
          'CONFIG_PACKAGE_luci-app-mwan3=y' >> .config
    fi

    if [ -n "$EXTRA_PACKAGES" ]; then
        for PKG in $EXTRA_PACKAGES; do
            case "$PKG" in '#'*) continue ;; esac
            printf 'CONFIG_PACKAGE_%s=y\n' "$PKG" >> .config
        done
    fi

    log "  make defconfig"
    make defconfig >/dev/null

    # --- sanity check（与 workflow 一致，防止静默编出残废固件）---
    echo
    _chk() { grep -qE "$1" .config || die "$2"; }
    _chk 'TARGET_mediatek_filogic_DEVICE_glinet_gl-mt5000=y' "设备目标缺失"

    if [ "$ENABLE_MWAN3" = "true" ]; then
        for U in mwan3 luci-app-mwan3; do
            _chk "^CONFIG_PACKAGE_${U}=y" "多线管理组件缺失: $U"
        done
    fi

    _chk '^CONFIG_PACKAGE_(luci|luci-light)=y' "LuCI 套件未生效（config/mt5000.seed 的 CONFIG_PACKAGE_luci=y）"
    _chk '^CONFIG_PACKAGE_uhttpd=y' "uhttpd 缺失：LuCI 无 Web 服务器，管理页面打不开"
    # 25.12 filogic 默认包集对齐项（master 的 target.mk 不追加 tweak 段）
    for U in block-mount default-settings-chn kmod-nf-nathelper; do
        _chk "^CONFIG_PACKAGE_${U}=y" "25.12 默认包集对齐项缺失: $U（config/mt5000.seed 被误删？）"
    done
    grep -q "CONFIG_TARGET_PREINIT_IP=\"$LAN_IP\"" .config || die "LAN IP 未生效"
    grep -qE "CONFIG_TARGET_ROOTFS_PARTSIZE=$ROOTFS_SIZE" .config || die "分区大小未生效"
    # 内核调试能力（pr_debug/dev_dbg 运行时开关，依赖 debugfs）
    _chk '^CONFIG_KERNEL_DYNAMIC_DEBUG=y' "CONFIG_KERNEL_DYNAMIC_DEBUG 未生效（config/mt5000.seed 被改动？）"
    _chk '^CONFIG_KERNEL_DEBUG_FS=y' "debugfs 未开启，dynamic debug 无法在运行时控制"

    if [ -n "$EXTRA_PACKAGES" ]; then
        local MISSING='' PKG
        for PKG in $EXTRA_PACKAGES; do
            case "$PKG" in '#'*) continue ;; esac
            grep -q "^CONFIG_PACKAGE_${PKG}=y" .config || MISSING="$MISSING $PKG"
        done
        if [ -n "$MISSING" ]; then
            die "额外软件包未生效（名称错误或依赖未满足）:$MISSING"
        fi
    fi

    ok "sanity check 通过"
}

# ============================================================================
# 5. 首启定制 uci-defaults（对应 Generate first-boot customization）
# ============================================================================

do_uci_defaults() {
    step_banner "生成首启定制 (uci-defaults)"

    cd "$SRC_DIR"
    local UD=files/etc/uci-defaults
    mkdir -p "$UD"

    # 时区（busybox 需要 POSIX TZ 形式）
    local TZP
    case "$TIMEZONE" in
        Asia/Shanghai)    TZP='CST-8' ;;
        Asia/Hong_Kong)   TZP='HKT-8' ;;
        Asia/Taipei)      TZP='CST-8' ;;
        Asia/Tokyo)       TZP='JST-9' ;;
        Asia/Singapore)   TZP='SGT-8' ;;
        Europe/Berlin)    TZP='CET-1CEST,M3.5.0,M10.5.0/3' ;;
        *)                TZP='UTC0' ;;
    esac
    printf '%s\n' \
        '#!/bin/sh' \
        "uci set system.@system[0].timezone='$TZP'" \
        "uci set system.@system[0].zonename='$TIMEZONE'" \
        'uci commit system' > "$UD/99-timezone"

    # 主机名
    printf '%s\n' \
        '#!/bin/sh' \
        "uci set system.@system[0].hostname='$ROUTER_HOSTNAME'" \
        'uci commit system' > "$UD/99-hostname"

    # root 密码：留空 = 保持无密码；只在新刷机（root 无密码）时写入，
    # 保留配置升级不会覆盖用户已设的密码。S10-boot 阶段跑，先于 dropbear/uhttpd。
    if [ -n "$ROOT_PASSWORD" ]; then
        local HASH
        HASH=$(printf '%s' "$ROOT_PASSWORD" | openssl passwd -6 -stdin)
        printf '%s\n' \
            '#!/bin/sh' \
            '# 仅当 root 尚无密码(全新刷机)时写入默认密码;' \
            '# 保留配置升级时 /etc/shadow 随配置保留, 此脚本不会覆盖已设密码' \
            "if grep -q '^root::' /etc/shadow; then" \
            "  sed -i 's|^root::|root:$HASH:|' /etc/shadow" \
            'fi' \
            'exit 0' > "$UD/99-root-password"
    fi

    # LuCI 语言
    if [ "$UI_LANG" = "zh-cn" ]; then
        printf '%s\n' \
            '#!/bin/sh' \
            "uci set luci.main.lang='zh_cn'" \
            'uci commit luci' > "$UD/99-luci-lang"
    fi

    # PPPoE（MT5000 的 WAN 是 eth1）
    if [ "$PPPOE" = "true" ]; then
        local UPE PPE
        UPE=$(printf '%s' "$PPPOE_USERNAME" | sed "s/'/'\\\\''/g")
        PPE=$(printf '%s' "$PPPOE_PASSWORD" | sed "s/'/'\\\\''/g")
        printf '%s\n' \
            '#!/bin/sh' \
            "uci set network.wan.proto='pppoe'" \
            "uci set network.wan.username='$UPE'" \
            "uci set network.wan.password='$PPE'" \
            'uci commit network' > "$UD/99-pppoe"
    fi

    # IPv6（参考 Aethersailor/Custom_OpenClash_Rules 的 OpenWrt IPv6 设置方案）
    #   PPPoE    -> ppp6-up 由 AUTOIPV6 自动生成动态 wan_6(dhcpv6+PD)，
    #               前提是 wan.ipv6 留空/auto（显式 ipv6=1 会禁用它）
    #   DHCP WAN -> proto dhcp 不会自动生成 wan_6，需显式 wan6 承载 PD
    if [ "$ENABLE_IPV6" = "true" ]; then
        local IU="$UD/99-ipv6"
        printf '%s\n' \
            '#!/bin/sh' \
            '# IPv6 per Aethersailor/Custom_OpenClash_Rules wiki (OpenWrt IPv6 设置方案)' \
            "# 生成参数: ip6assign=$LAN_IPV6_ASSIGN ip6ifaceid=$LAN_IPV6_SUFFIX dhcpv6=$LAN_IPV6_DHCPV6 ipv6_dns=$LAN_IPV6_DNS" \
            '' \
            '# --- WAN: 委托上游前缀 ---' \
            "uci -q set network.wan.delegate='1'" \
            '# 关键: wan.ipv6 必须留空/auto，否则 ppp.sh 不会设 AUTOIPV6，' \
            '# 动态 wan_6 不会生成（旧脚本 r9 上 wan_6 缺失的根因），故一并清掉残留' \
            'uci -q delete network.wan.ipv6' \
            'uci -q delete network.wan.ip6assign' \
            'uci -q delete network.wan.ip6class' \
            'uci -q delete network.wan.ip6hint' \
            'uci -q delete network.wan.ip6weight' \
            '[ -n "$(uci -q get dhcp.wan)" ] && uci -q set dhcp.wan.ignore=1' > "$IU"

        if [ "$PPPOE" = "true" ]; then
            printf '%s\n' \
                '' \
                '# --- PPPoE: 依赖自动生成的动态 wan_6 (dhcpv6 客户端 + PD) ---' \
                'uci -q delete network.wan6' >> "$IU"
        else
            printf '%s\n' \
                '' \
                '# --- DHCP WAN: 确保 wan6 (dhcpv6 客户端) 存在并承载 PD ---' \
                'uci -q set network.wan6=interface' \
                'WANDEV=$(uci -q get network.wan.device || uci -q get network.wan.ifname)' \
                '[ -n "$WANDEV" ] && uci -q set network.wan6.device="$WANDEV"' \
                "uci -q set network.wan6.proto='dhcpv6'" \
                "uci -q set network.wan6.reqaddress='try'" \
                "uci -q set network.wan6.reqprefix='auto'" >> "$IU"
        fi

        printf '%s\n' \
            '' \
            '# --- LAN: 从委派前缀中划分子网 ---' \
            "uci -q set network.lan.delegate='1'" \
            "uci -q set network.lan.ipv6='1'" \
            "uci -q set network.lan.ip6ifaceid='$LAN_IPV6_SUFFIX'" >> "$IU"

        if [ "$LAN_IPV6_ASSIGN" = "disabled" ]; then
            printf '%s\n' '# 不向下游分配公网 IPv6 前缀' \
                          'uci -q delete network.lan.ip6assign' >> "$IU"
        else
            printf '%s\n' "uci -q set network.lan.ip6assign='$LAN_IPV6_ASSIGN'" >> "$IU"
        fi

        printf '%s\n' \
            '' \
            '# --- LAN DHCP 服务器: RA + SLAAC, 关闭 NDP 代理 ---' \
            'uci -q get dhcp.lan >/dev/null || { uci -q set dhcp.lan=dhcp; uci -q set dhcp.lan.interface=lan; }' \
            "uci -q set dhcp.lan.ra='server'" \
            "uci -q set dhcp.lan.ra_slaac='1'" \
            "uci -q set dhcp.lan.ndp='disabled'" \
            "uci -q set dhcp.lan.dhcpv6='$LAN_IPV6_DHCPV6'" >> "$IU"

        if [ "$LAN_IPV6_DHCPV6" = "disabled" ]; then
            printf '%s\n' '# 无 DHCPv6 -> RA 不带 M/O 标志 (纯 SLAAC)' \
                          'uci -q delete dhcp.lan.ra_flags' \
                          "uci -q add_list dhcp.lan.ra_flags='none'" >> "$IU"
        else
            printf '%s\n' '# 有状态 DHCPv6 -> RA 带 M/O 标志' \
                          'uci -q delete dhcp.lan.ra_flags' \
                          "uci -q add_list dhcp.lan.ra_flags='managed-config'" \
                          "uci -q add_list dhcp.lan.ra_flags='other-config'" >> "$IU"
        fi

        if [ "$LAN_IPV6_DNS" = "true" ]; then
            printf '%s\n' "uci -q set dhcp.lan.dns_service='1'" >> "$IU"
        else
            printf '%s\n' \
                '# 不通告路由器为 IPv6 DNS -> 客户端继续用路由器 IPv4 地址解析, 保持 OpenClash 分流' \
                "uci -q set dhcp.lan.dns_service='0'" \
                'uci -q delete dhcp.lan.dns' >> "$IU"
        fi

        printf '%s\n' \
            '' \
            '# --- dnsmasq: 不过滤 IPv6 AAAA 记录 ---' \
            "uci -q set dhcp.@dnsmasq[0].filter_aaaa='0'" \
            '' \
            'uci -q commit network' \
            'uci -q commit dhcp' \
            'exit 0' >> "$IU"

        [ -s "$IU" ] || die "99-ipv6 未生成"
        ok "99-ipv6 已生成（assign=$LAN_IPV6_ASSIGN suffix=$LAN_IPV6_SUFFIX dhcpv6=$LAN_IPV6_DHCPV6）"
    fi

    # mwan3 只让它接管 IPv4：默认配置的 default_rule_v6 指向 balanced 策略，
    # balanced 没有 IPv6 成员时会给每个 IPv6 包打 fwmark 0x3e00，命中
    # ip6 rule "0x3e00/0x3f00 unreachable"（优先级 2062，先于 main 表），
    # 结果路由器与下游的 IPv6 全部 ENETUNREACH。
    if [ "$ENABLE_MWAN3" = "true" ]; then
        cat > "$UD/99-mwan3-ipv4" <<'MWAN3_EOF'
#!/bin/sh
# mwan3 默认配置会破坏 IPv6:
#   mwan3.default_rule_v6 -> balanced 策略(无 IPv6 成员)
#   -> IPv6 包被打 fwmark 0x3e00 -> ip -6 rule unreachable -> 全网 IPv6 不通
# 修复: 让 mwan3 的规则只作用于 IPv4, 删掉 IPv6 默认规则。
# 若将来真的要 mwan3 管 IPv6, 需要建 family ipv6 的接口/成员/策略,
# 仅 uci set mwan3.wan6.enabled='1' 是不够的。
[ -n "$(uci -q get mwan3.https)" ] && uci -q set mwan3.https.family='ipv4'
uci -q delete mwan3.default_rule_v6
uci -q commit mwan3
exit 0
MWAN3_EOF
        chmod 755 "$UD/99-mwan3-ipv4"
        [ -s "$UD/99-mwan3-ipv4" ] || die "99-mwan3-ipv4 未生成"
    fi

    chmod 755 "$UD"/99-* 2>/dev/null || true
    ok "uci-defaults: $(ls "$UD" | tr '\n' ' ')"
}

# ============================================================================
# 6. 下载源码包（对应 Download sources）
# ============================================================================

do_download() {
    if [ "$SKIP_DOWNLOAD" = "1" ]; then
        dim "  跳过（--skip-download）"
        return 0
    fi
    step_banner "下载依赖源码包 (make download)"

    cd "$SRC_DIR"
    # 本地下载失败往往是网络抖动，重试 3 次；CI 上是一次定生死。
    local attempt
    for attempt in 1 2 3; do
        if make download -j"$JOBS" 2>&1 | tail -n 5; then
            ok "下载完成（第 $attempt 次尝试）"
            return 0
        fi
        warn "下载失败，重试 $attempt/3"
        sleep 3
    done
    die "make download 连续 3 次失败。常见原因：网络不通、上游某个包 404、dl/ 里有零字节残留文件"
}

# ============================================================================
# 7. 编译（对应 Build firmware）
# ============================================================================

do_build() {
    step_banner "编译固件"

    cd "$SRC_DIR"

    # rules.mk 在 CONFIG_CCACHE=y 时自己 export CCACHE_DIR=$(TOPDIR)/.ccache、
    # CCACHE_BASEDIR=$(TOPDIR)，并强制 CCACHE_NOCOMPRESS=true。
    # 所以只给 maxsize，其余交给它管，避免两边打架。
    # 本地放到 5G：CI 限 1G 是因为仓库缓存总配额 10G，本地没这约束。
    export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-5G}"
    if command -v ccache >/dev/null 2>&1; then
        ccache -s 2>/dev/null | head -5 || true
    else
        warn "未安装 ccache（CONFIG_CCACHE=y 会静默忽略），装一下可大幅加快重编"
    fi

    log "  make -j$JOBS（全量首编约 1-4 小时，增量通常 10-30 分钟）"
    local start; start=$(date +%s)

    if ! make -j"$JOBS"; then
        warn "并行编译失败。用 -j1 V=s 串行重跑定位真正的错误（ccache 已编过的目标会直接命中）"
        make -j1 V=s || die "编译失败"
    fi

    local mins=$(( ($(date +%s) - start) / 60 ))
    ok "编译完成，耗时 ${mins} 分钟"

    command -v ccache >/dev/null 2>&1 && { echo; ccache -s 2>/dev/null | head -8 || true; }
}

# ============================================================================
# 汇总
# ============================================================================

report() {
    local IMGDIR="$SRC_DIR/bin/targets/mediatek/filogic"
    step_banner "产物"

    if [ ! -d "$IMGDIR" ]; then
        warn "产物目录不存在: $IMGDIR（编译未跑完？）"
        return 0
    fi

    ls -lh "$IMGDIR"/*glinet_gl-mt5000* "$IMGDIR/sha256sums" 2>/dev/null \
        | awk '{printf "  %-10s %s\n", $5, $9}' || true

    local sysup="$IMGDIR/immortalwrt-mediatek-filogic-glinet_gl-mt5000-squashfs-sysupgrade.bin"
    if [ -f "$sysup" ]; then
        printf '\n'
        ok "sysupgrade: $sysup"
        dim "刷机：LuCI → 系统 → 备份/刷写固件，或 sysupgrade -n $sysup"
        if [ -f "$IMGDIR/sha256sums" ]; then
            dim "校验：cd $IMGDIR && sha256sum -c sha256sums --ignore-missing"
        fi
    fi

    if [ -n "${BASE_SHA:-}" ]; then
        printf '\n  源码基线: %s\n' "$BASE_SHA"
    fi
}

# ============================================================================
# main
# ============================================================================

main() {
    parse_args "$@"
    resolve_inputs
    resolve_jobs

    print_config

    if [ "$DRY_RUN" = "1" ]; then
        ok "dry-run：未执行任何实际操作"
        exit 0
    fi

    should_run validate && check_prereq
    should_run clone    && do_clone
    resolve_base_sha    # --from patch 及以后跳过 clone 时，补出 BASE_SHA
    should_run patch    && do_patch
    should_run overlay  && do_overlay
    should_run config   && do_config
    should_run uci      && do_uci_defaults
    should_run download && do_download
    should_run build    && do_build

    report
}

main "$@"
