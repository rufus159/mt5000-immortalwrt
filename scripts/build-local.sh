#!/usr/bin/env bash
#
# build-local.sh — 在本地（Linux / WSL / NAS 虚拟机）编译 GL.iNet MT5000 的
#                  ImmortalWrt 固件。
#
# 全部编译都在本地执行；GitHub 仓库只用于记录补丁与开发记录，不跑 Actions 构建。
#
# 范围约束：
#   * 源码基线只用 immortalwrt master 分支（默认 4765b65762，内核 6.18.60）
#   * 施加到源码树上的只有 patches/ 的 7 个 format-patch 提交，以及
#     config/mt5000.seed 里 6 个包
#   * 不生成任何首启定制脚本，不写 LAN IP / 主机名 / 时区 / root 密码 /
#     界面语言 / PPPoE / IPv6 等 uci-defaults，不追加额外包或第三方 feed
#   * 唯一额外后处理是给 ImmortalWrt 基线补一个缺失的 Kconfig 符号，
#     详见 do_patch；它不属于上游补丁系列
#
# 用法：
#   ./scripts/build-local.sh                     # 全默认，从头编
#   ./scripts/build-local.sh --jobs 9            # 指定并行度
#   ./scripts/build-local.sh --from patch        # 改完补丁后增量续跑
#   ./scripts/build-local.sh --from build        # 只重编
#   ./scripts/build-local.sh --dry-run           # 只打印解析后的配置
#   ./scripts/build-local.sh --help
#
set -euo pipefail

# ============================================================================
# 常量
# ============================================================================

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# 唯一允许的基线：immortalwrt master 分支
REF_MASTER_DEFAULT=4765b65762
IMMORTALWRT_GIT=https://github.com/immortalwrt/immortalwrt

# 25.12 常规正式版分支相对 master 默认多出的包（与 config/mt5000.seed 一致）
DELTA_PACKAGES=(block-mount default-settings-chn kmod-nf-nathelper luci \
                autocore kmod-crypto-hw-safexcel)

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
# 默认参数
# ============================================================================

IWRT_REF=${IWRT_REF:-}
SRC_DIR=${SRC_DIR:-$REPO_ROOT/immortalwrt}
JOBS=${JOBS:-}          # 空 = 按内存自动算
FROM_STEP=${FROM_STEP:-validate}
CLEAN=0
SKIP_DOWNLOAD=0
DRY_RUN=0

# 由 resolve_* 派生
PATCHDIR=''
BASE_SHA=''

# ============================================================================
# 用法
# ============================================================================

usage() {
    cat <<'USAGE'
build-local.sh — 本地编译 GL.iNet MT5000 (Brume 3) 的 ImmortalWrt 固件

  --ref <commit>             覆盖默认基线（默认 master 4765b65762）
  --src <dir>                源码目录（默认 <repo>/immortalwrt）
  --jobs <N>                 编译并行度（默认按可用内存自动算）
  --clean                    删除并重新克隆源码树（会丢增量编译成果）
  --from <step>              从指定步骤开始：validate|clone|patch|overlay|
                             config|download|build（默认 validate）
  --skip-download            跳过 make download
  --dry-run                  只打印解析后的配置，不执行
  -h, --help                 显示本帮助

环境变量：IWRT_REF / SRC_DIR / JOBS / FROM_STEP / SKIP_DOWNLOAD / DRY_RUN
          / GIT_NO_FETCH / CCACHE_MAXSIZE 可用同名大写形式传入。

例子：
  ./scripts/build-local.sh
  ./scripts/build-local.sh --from patch --jobs 4
  ./scripts/build-local.sh --from build
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
            -h|--help)          usage; exit 0 ;;
            *)                  die "未知参数: $1（--help 看用法）" ;;
        esac
    done
}

# ============================================================================
# 输入校验 + 派生
# ============================================================================

resolve_inputs() {
    if [ -n "$IWRT_REF" ]; then
        dim "显式指定基线: $IWRT_REF"
    else
        IWRT_REF=$REF_MASTER_DEFAULT
        dim "master 默认基线: $IWRT_REF"
    fi

    case "$FROM_STEP" in
        validate|clone|patch|overlay|config|download|build) ;;
        *) die "非法 --from: $FROM_STEP（可选 validate|clone|patch|overlay|config|download|build）" ;;
    esac

    PATCHDIR=$REPO_ROOT/patches
    [ -d "$PATCHDIR" ] || die "补丁目录不存在: $PATCHDIR"
    [ -f "$REPO_ROOT/config/mt5000.seed" ] || die "seed 不存在: $REPO_ROOT/config/mt5000.seed"
}

# 并行度：按内存而非核数。一次编译进程峰值约 1~1.5G，核多内存少会 OOM。
resolve_jobs() {
    local nproc_n mem_gb auto
    nproc_n=$(nproc 2>/dev/null || echo 4)
    mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 8)

    if [ -z "$JOBS" ]; then
        auto=$(( (mem_gb - 1) * 10 / 13 ))
        [ "$auto" -lt 1 ] && auto=1
        [ "$auto" -gt "$nproc_n" ] && auto=$nproc_n
        JOBS=$auto
        JOBS_NOTE="按内存 ${mem_gb}G / ${nproc_n} 核自动算出"
    else
        JOBS_NOTE="手动指定"
    fi

    local need=$(( JOBS * 13 / 10 ))
    if [ "$need" -gt "$mem_gb" ]; then
        warn "-j${JOBS} 预计需要约 ${need}G 内存，但只有 ${mem_gb}G。"
        warn "可能被 OOM killer 杀掉；建议降到 --jobs $(( mem_gb * 10 / 13 ))。"
    fi
}

print_config() {
    local d=$([ "$DRY_RUN" = "1" ] && echo "(dry-run) " || echo "")
    printf '\n%s%s构建配置%s\n' "$C_BLU" "$d" "$C_RST"
    printf '  %-13s %s\n' "baseline"     "immortalwrt master @ $IWRT_REF"
    printf '  %-13s %s\n' "patch dir"    "${PATCHDIR#$REPO_ROOT/}"
    printf '  %-13s %s\n' "seed"         "config/mt5000.seed"
    printf '  %-13s %s\n' "source dir"   "$SRC_DIR"
    printf '  %-13s %s\n' "jobs"         "$JOBS  ($JOBS_NOTE)"
    printf '  %-13s %s\n' "delta pkgs"   "${DELTA_PACKAGES[*]}"
    printf '  %-13s %s\n' "custom cfg"   "none (LAN/password/tz/uci-defaults 全为官方默认)"
    printf '  %-13s %s\n' "from step"    "$FROM_STEP"
    printf '\n'
}

# ============================================================================
# 前置检查
# ============================================================================

check_prereq() {
    step_banner "前置检查"

    # 大小写敏感 —— OpenWrt 的 include/prereq-build.mk 有 case-sensitive-fs
    # 硬检查，不敏感的文件系统上 make 会在 defconfig 阶段直接失败。
    local probe="$SRC_DIR/../.cstest.$$"
    mkdir -p "$(dirname "$probe")"
    : > "$probe"
    if [ -e "${probe%.*}.CSTEST.$$" ] 2>/dev/null; then
        rm -f "$probe"; die "目标目录大小写不敏感，OpenWrt 无法在此编译: $(dirname "$probe")"
    fi
    rm -f "$probe"
    ok "文件系统大小写敏感"

    local um
    um=$(umask)
    case "$um" in
        022|0022) ok "umask $um" ;;
        *) warn "umask 是 $um，OpenWrt 要求 022。建议先执行 umask 022" ;;
    esac

    local missing=''
    for t in git make gcc g++ awk grep sed xargs find python3; do
        command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    [ -n "$missing" ] && die "缺少必需工具:$missing"
    ok "基础工具齐全"

    # OpenWrt 的完整依赖清单；缺了不致命 —— make 会自己报 —— 只做提示。
    local hint=''
    for p in gcc-multilib libncurses-dev zlib1g-dev libssl-dev rsync unzip \
             bzip2 patch subversion swig python3 python3-ply python3-docutils \
             device-tree-compiler cpio rsync gettext flex bison pkg-config \
             libelf-dev libltdl-dev libmpc-dev libmpfr-dev libgmp-dev \
             squashfs-tools mkisofs xxd; do
        if command -v dpkg >/dev/null 2>&1 && ! dpkg -s "$p" >/dev/null 2>&1; then
            # Ubuntu 24.04 上这两个是命令别名：pkgconf 提供 pkg-config、
            # genisoimage 提供 mkisofs，dpkg -s 按包名查会误报缺失。
            case "$p" in
                pkg-config|mkisofs) command -v "$p" >/dev/null 2>&1 && continue ;;
            esac
            hint="$hint $p"
        fi
    done
    if [ -n "$hint" ]; then
        warn "以下开发包似乎未安装（若编译报错再来补）:"
        printf '       sudo apt install -y --no-install-recommends \\\n          %s\n' "$(echo $hint)" >&2
        dim "完整清单见 README 的「环境要求」"
    fi

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

step_index() {
    case "$1" in
        validate) echo 0 ;; clone) echo 1 ;; patch)   echo 2 ;;
        overlay)  echo 3 ;; config) echo 4 ;; download) echo 5 ;;
        build)    echo 6 ;; *) die "未知步骤: $1" ;;
    esac
}

should_run() {
    [ "$(step_index "$1")" -ge "$(step_index "$FROM_STEP")" ]
}

# --from patch 及以后会跳过 do_clone，这里补出 BASE_SHA，
# 否则 do_patch 的标记和 reset 目标都错了。
resolve_base_sha() {
    [ -n "$BASE_SHA" ] && return 0
    [ -d "$SRC_DIR/.git" ] || die "源码树不存在: $SRC_DIR（先跑 clone，或去掉 --from）"
    BASE_SHA=$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null) \
        || die "无法读取 $SRC_DIR 的 HEAD"
    dim "沿用现有源码树 HEAD: ${BASE_SHA:0:12}"
}

# ============================================================================
# 1. 克隆源码
# ============================================================================

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

    # 用 cat-file -e 而不是 rev-parse --verify：partial clone 下对不存在的
    # 对象 rev-parse 可能吐出前缀匹配的近似 SHA 且退出码为 0。
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

    if [ -z "$(git tag --points-at "$BASE_SHA")" ] \
       && ! git merge-base --is-ancestor "$BASE_SHA" origin/master 2>/dev/null; then
        warn "基线 ${BASE_SHA:0:12} 不在 master 可达历史里 —— 悬空对象，上游下次 gc 会回收"
    fi
}

# ============================================================================
# 2. 应用补丁
# ============================================================================

do_patch() {
    step_banner "应用 MT5000 补丁系列（7 个提交）"

    cd "$SRC_DIR"

    # 幂等标记：基线 + 补丁清单 + 后处理版本。改了补丁或后处理逻辑，
    # 必须让旧 marker 失效，否则会被整段跳过。
    local marker="$SRC_DIR/.mt5000-patches.applied"
    local base="${BASE_SHA:-$IWRT_REF}"
    local want n_total
    n_total=$(ls "$PATCHDIR"/*.patch | wc -l)
    want=$( { echo "base=$base";
              echo "series=pr24237-v1";
              echo "kconfig_fix=v1";
              for p in "$PATCHDIR"/*.patch; do basename "$p"; done; } )

    if [ -f "$marker" ] && [ "$(cat "$marker")" = "$want" ]; then
        ok "补丁链已是目标状态（基线 ${base:0:12}, $n_total 个提交），跳过"
        return 0
    fi

    # 把代码树退回基线；build_dir/ staging_dir/ dl/ bin/ 是 untracked，
    # git reset --hard 不会碰它们，所以不会毁掉已有的编译成果。
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
            git apply --index "$p"
            ok "  $name"
            n=$((n+1))
        else
            {
                echo "补丁应用失败: $name"
                echo "基线=$base"
                echo
                echo "定位真实冲突："
                echo "  cd $SRC_DIR && git apply --check -v '$p'"
            } >&2
            rm -f "$marker"
            die "补丁链断裂于 $name"
        fi
    done

    # ---- ImmortalWrt 基线适配（不属于上游 6 提交）--------------------
    # backport-6.18/967-03 往内核 drivers/net/dsa/Kconfig 加入
    # NET_DSA_YT921X，但 target/linux/generic/config-6.18 模板没有对应行。
    # 内核 syncconfig 会把它当作 (NEW) 符号交互式提问，后台非交互编译
    # 读到 EOF 直接失败。显式设 n 不改变固件内容。
    #
    # 上游 PR #24237 是给 openwrt/openwrt 的，那边没有这个 backport；
    # 将来提交 ImmortalWrt 主线时这一行需要单独作为一个 fix 提交。
    local cfg=target/linux/generic/config-6.18
    if ! grep -q '^# CONFIG_NET_DSA_YT921X is not set' "$cfg"; then
        python3 - "$cfg" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = '# CONFIG_NET_DSA_TAG_YT921X is not set'
assert anchor in s, 'Kconfig anchor missing: ' + anchor
s = s.replace(anchor, '# CONFIG_NET_DSA_YT921X is not set\n' + anchor, 1)
open(p, 'w').write(s)
PYEOF
        git add "$cfg"
        ok "  ImmortalWrt 基线适配: 补 # CONFIG_NET_DSA_YT921X is not set"
    else
        dim "  Kconfig 补行已存在"
    fi

    printf '%s' "$want" > "$marker"
    ok "补丁完成：应用 $n 个提交"
}

# 删除「补丁新建、但当前未被跟踪」的文件。路径清单直接从补丁里解析
# （+++ b/ 且该 hunk 是 new file），保证只动补丁涉及的文件。
_purge_patch_untracked() {
    local p f
    for p in "$PATCHDIR"/*.patch; do
        [ -e "$p" ] || continue
        awk '
            /^diff --git /   { isnew=0; next }
            /^new file mode/ { isnew=1; next }
            isnew && /^\+\+\+ b\// { print substr($0, 7); isnew=0 }
        ' "$p"
    done | sort -u > "$SRC_DIR/.mt5000-newfiles.tmp"

    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -e "$SRC_DIR/$f" ] \
           && ! git -C "$SRC_DIR" ls-files --error-unmatch "$f" >/dev/null 2>&1; then
            rm -f "$SRC_DIR/$f"
            dim "  清理残留: $f"
        fi
    done < "$SRC_DIR/.mt5000-newfiles.tmp"
    rm -f "$SRC_DIR/.mt5000-newfiles.tmp"
}

# ============================================================================
# 3. overlay + feeds
# ============================================================================

do_overlay() {
    step_banner "准备官方 feeds"

    cd "$SRC_DIR"

    # 本仓库不再携带任何 files/ 首启定制脚本。若用户自己放了 overlay，
    # 才复制；默认路径下 files/ 不存在，直接跳过。
    if [ -d "$REPO_ROOT/files" ]; then
        cp -r "$REPO_ROOT/files/." ./
        ok "files/ overlay 已复制（注意：这属于超出约定范围的自定义内容）"
    else
        ok "无 files/ overlay（首启定制脚本已全部移除）"
    fi

    ok "只使用官方 feeds.conf.default，不追加任何第三方 feed"

    log "  feeds update -a（首次约 3-5 分钟）"
    ./scripts/feeds update -a >/dev/null
    ok "feeds update 完成"

    log "  feeds install -a"
    ./scripts/feeds install -a >/dev/null
    ok "feeds install 完成"
}

# ============================================================================
# 4. 生成 .config
# ============================================================================

do_config() {
    step_banner "生成 .config"

    cd "$SRC_DIR"
    cp "$REPO_ROOT/config/mt5000.seed" .config

    # 不做任何参数化改写：seed 即最终配置，LAN IP、主机名、密码、语言、
    # PPPoE、IPv6、内核调试等全部沿用 master 官方默认。
    log "  make defconfig"
    make defconfig >/dev/null

    # 可选：本地构建机用主机 clang 代替从源码编译 tools/llvm-bpf。
    # 默认关闭 —— 不改变 seed、不改变固件内容，也不进仓库默认配方；
    # 仅当构建机已装 clang 且希望跳过约 4000 个 CXX 目标时由外部设置。
    if [ "${MT5000_LOCAL_BPF_HOST_CLANG:-0}" = "1" ]; then
        sed -i -E '/^(# )?CONFIG_(DEVEL|BPF_TOOLCHAIN_|USE_LLVM_)/d' .config
        printf 'CONFIG_DEVEL=y\nCONFIG_BPF_TOOLCHAIN_HOST=y\n' >> .config
        make defconfig >/dev/null
        grep -q '^CONFIG_USE_LLVM_HOST=y' .config \
            || die "本地加速开关未生效：USE_LLVM_HOST 未设置（主机 clang 可用？）"
        ok "本地加速：使用主机 clang（不编 tools/llvm-bpf）"
    fi

    # sanity check：确认设备目标与 6 个差异包都真的生效
    echo
    _chk() { grep -qE "$1" .config || die "$2"; }
    _chk 'TARGET_mediatek_filogic_DEVICE_glinet_gl-mt5000=y' "设备目标缺失"
    _chk '^CONFIG_PACKAGE_(luci|luci-light)=y' "LuCI 套件未生效"
    _chk '^CONFIG_PACKAGE_uhttpd=y' "uhttpd 缺失：LuCI 无 Web 服务器"
    for U in "${DELTA_PACKAGES[@]}"; do
        _chk "^CONFIG_PACKAGE_${U}=y" "25.12 差异包未生效: $U（config/mt5000.seed 被误删？）"
    done

    ok "sanity check 通过：设备目标 + ${#DELTA_PACKAGES[@]} 个差异包"
}

# ============================================================================
# 5. 下载源码包
# ============================================================================

do_download() {
    if [ "$SKIP_DOWNLOAD" = "1" ]; then
        dim "  跳过（--skip-download）"
        return 0
    fi
    step_banner "下载依赖源码包 (make download)"

    cd "$SRC_DIR"
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
# 6. 编译
# ============================================================================

do_build() {
    step_banner "编译固件"

    cd "$SRC_DIR"

    # 补丁栈的正确性由完整编译验证：这 7 个提交已在 ImmortalWrt
    # 4765b65762 / 6.18.60 上通过一次干净内核树的全量编译。
    # 旧的内核补丁 dry-run 门禁是针对被替换掉的折叠补丁（795-10/795-11
    # 的行号与 967 删除策略）设计的，对新系列会误报，故已移除。
    for f in target/linux/generic/pending-6.18/795-10-*.patch \
             target/linux/generic/pending-6.18/795-11-*.patch \
             target/linux/generic/pending-6.18/999-90-*.patch; do
        [ -e "$f" ] || die "补丁系列未完整落地，缺少: $f"
    done

    log "  make -j$JOBS（全量首编约 1-4 小时，增量通常 10-30 分钟）"
    local start; start=$(date +%s)

    # 不做 -j1 V=s 降级：串行重跑会触发 tools/llvm-bpf 全量重编，
    # 且详细日志被 log_make 吞掉，反而更难定位。失败直接保留现场。
    make -j"$JOBS" || die "编译失败，请查看上面的输出或构建日志"

    local mins=$(( ($(date +%s) - start) / 60 ))
    ok "编译完成，耗时 ${mins} 分钟"
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
        dim "校验：cd $IMGDIR && sha256sum -c sha256sums --ignore-missing"
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
    resolve_base_sha
    should_run patch    && do_patch
    should_run overlay  && do_overlay
    should_run config   && do_config
    should_run download && do_download
    should_run build    && do_build

    report
}

main "$@"
