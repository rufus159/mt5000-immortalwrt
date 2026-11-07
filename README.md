# GL.iNet MT5000 (Brume 3) — ImmortalWrt 自编译固件

给 **GL.iNet MT5000** 编译 ImmortalWrt。设备支持来自尚未合并的上游 PR，
因此必须全源码编译，无法用 ImageBuilder。

---

## 致敬原作者

本仓库的构建配方、GitHub Actions 工作流与补丁分层结构，全部来自 **Kitsune2077**：

- 项目：**[Kitsune2077/mt5000-immortalwrt](https://github.com/Kitsune2077/mt5000-immortalwrt)**
- 说明：**[原作者 README](https://github.com/Kitsune2077/mt5000-immortalwrt/blob/main/README.md)**

没有这份工作就没有本项目。原仓库未附 LICENSE 文件，本仓库以 **GPL-2.0** 发布
（见 [LICENSE](LICENSE)），并在下文逐项标注每处改动的依据。

设备支持与 Realtek 交换机驱动源自 OpenWrt 上游
**PR [#24237](https://github.com/openwrt/openwrt/pull/24237)**
（GL.iNet `GLiNet-Tech`，作者 John Crispin），GPL-2.0。

802.1Q tagger / MTK PPE 卸载的独立参考实现：
**[Beaverfffan/x-wrt-mt5000](https://github.com/Beaverfffan/x-wrt-mt5000)**。

---

## 基于哪个版本的源码

补丁只针对一个 ImmortalWrt 基线：

| ImmortalWrt 基线 commit | 日期 | 内核 | 补丁目录 |
|---|---|---|---|
| `4765b657625ec5bbda74b44400465fe043802b30`（`master`） | 2026-11-05 | **6.18** | `patches/` |

同一时间点的 `Merge Official Source` 同步提交 `de7e6ba56e45`（11-05 03:19）
也验证过 7 个补丁全部干净套用，二者任选其一都可以；本仓库以 `4765b65762` 为准，
因为补丁是对着它生成的（hunk 的 index 行也严格对齐）。
可用 `iwrt_ref` 输入覆盖为任意 ImmortalWrt commit。

### 基线的冻结，与漂移面到底有多大

基线冻结是刻意的——补丁依赖 `795-10` 等自建文件与上游板卡列表的确切上下文，
基线一动就得重做 rebase。但漂移面比看上去小得多：整套补丁 4400 行里，
**只有 6 个上游文件、约 10 个 hunk 会随基线变动**
（`board.d/02_network`、`upgrade/platform.sh`、`filogic/config-6.18`、
`image/filogic.mk`、`generic/config-6.18`，以及 `mtk_ppe_offload.c` 里
`mtk_flow_get_dsa_port()` 那一小段）；`795-10/11/12` 与 DTS 都是我们自己建的文件，
上游怎么改都不影响。

上一版基线 `f44d1535b4`（2026-09-18）到 `4765b65762` 之间隔了 **1831 个提交**，
实测只失败两处，都是 1~3 行的上下文错位：

- `platform.sh` 的板卡列表——上游插入了 `gl-be14000`、`rt-ax59u-ubi`、
  `bpi-r4-pro-4e` 等，把我们的插入点推后 37 行
- `filogic/config-6.18` 的 DSA TAG 段——上游新增 `TAG_YT921X` / `TAG_YT922X`

升级基线时：把新 SHA 填进 `iwrt_ref` 试跑；若 apply 失败，先查上面这两个位置。
`git apply` 没有 fuzz，用 `patch -p1 -F2` 能直接看出是「纯偏移」还是「真冲突」。

workflow 在 `Clone ImmortalWrt source` 步骤会：

- 校验 pin 的 SHA 是否真在仓库里，不存在则**立即失败**并打印当前可用的
  分支 HEAD（可直接复制进 `iwrt_ref`），不让问题拖到 40 分钟后编译阶段
- 若 SHA 存在但已是**悬空对象**（上游 force-push/rebase 过，下次 gc 就没），
  打 `::warning::` 但继续构建
- 把实际解析出的 `BASE_SHA` + 提交时间写进 Step Summary 和 Release 说明，
  避免"分支 HEAD 动了导致同一 pin 编出不同固件"这类不可追溯问题

---

## PPE 硬件加速：思路与做法

### 问题在哪

MTK 的 PPE（Packet Processing Engine）只解析自家 DSA 标签
（`DSA_TAG_PROTO_MTK`）。GL-MT5000 的 Realtek RTL8366UB 交换机用的是私有
`RTL8_4` 八字节标签，PPE 遇到直接拒绝：

```c
/* mtk_ppe_offload.c */
if (proto != DSA_TAG_PROTO_MTK)
        return -ENODEV;
```

后果：LAN↔WAN 的三层 NAT 转发全部落到 CPU，4×A53@2.0GHz 跑千兆宽带时
单核打满、吞吐上不去。

### 解决思路：换标签，不换硬件

用**标准 802.1Q VLAN 头**替代 Realtek 私有标签作 DSA 管理标签。
标准以太网 VLAN 头 PPE 认识，双向都能解析。

### 具体做法（4 步）

**① 写一个基于 `tag_8021q` 框架的 tagger**（`795-10` / `795-11`）

为 RTL8366UB 新增 `DSA_TAG_PROTO_RTL8366UB_8021Q`，用内核现成的
`net/dsa/tag_8021q.c` 机制代替私有标签。

**② 让 PPE 认得这个 tagger**（`795-11` 中的 `mtk_ppe_offload.c`）

```c
/* mtk_flow_get_dsa_port() 增加一个 case */
case DSA_TAG_PROTO_RTL8366UB_8021Q:
        if (push_vid) {
                struct net_device *br = dsa_port_bridge_dev_get(dp);
                if (br)
                        *push_vid = dsa_tag_8021q_bridge_vid(
                                        dsa_port_bridge_num_get(dp));
                else
                        *push_vid = dsa_tag_8021q_standalone_vid(dp);
        }
        break;
```

同时 `mtk_flow_set_output_device()` 把写 VLAN 的失败当成硬错误返回，
放弃卸载而不是留脏表项。

**③ 不破坏其他 tagger**（`mtk_eth_soc.c` 两处守卫）

`TX_DMA_SPTAG_V3` 与 `MTK_GDMA_SPECIAL_TAG` 只在原生 MTK tagger 下置位。

> 这里用的是**黑名单**写法：`proto != DSA_TAG_PROTO_RTL8366UB_8021Q`。
> 上游 master 的补丁是白名单（`proto == DSA_TAG_PROTO_MTK`），会把 BE14000
> 所用 YT922x tagger 的 TX 路径也一起改掉；黑名单只排除我们自己的 tagger，
> 对 MT5000 行为完全等价（本机只有 MTK 与 rtl8366ub 两种 tagger），但更通用。

**④ 协议号避坑**（`799-91`）

tagger 协议号取 **200**。上游 32 已被 `MXL862_8021Q` 占用，若重复，
内核升级后两个 tagger 抢同一 id 会静默编译通过、运行时随机命中。

### 怎么验证生效

```bash
# PPE 表项：BND（已绑定）+ 非零 bytes = 硬件真在转发
grep BND /sys/kernel/debug/ppe0/entries
grep -c OFFLOAD /proc/net/nf_conntrack
```

本机实测（PC 接 lan1、PVE 接 lan2 同时打流）：

```
ASIC 层（ethtool -S lan1 / lan2，真实值）：
  lan1 收 +4140 MB    lan2 发 +4134 MB
  lan1 发 +2588 MB    lan2 收 +2584 MB     ← 收发对称，硬件直通
eth0（交换机 CPU 口）：压测期间无增长        ← 证明不经 CPU
```

---

## 软件包：只用官方源

原配方会引入第三方 feed。本仓库**把这三个源连代码块一起删除**（不只是关掉
开关），构建时不会再 `feeds update` 它们，固件包集与官方 ImmortalWrt 同类型
有线路由器一致。

| 第三方源 | 原行为 | 本仓库默认 |
|---|---|---|
| `wukongdaily/luci-app-run` | **无条件追加** | ❌ **已移除**（输入 `enable_luci_app_run` 一并删除）|
| `linkease/istore` | `enable_store` 默认 `true` | ❌ **已移除**（输入 `store_mode` 一并删除）|
| `linkease/nas-packages` | `enable_quickstart` | ❌ **已移除**（quickstart 整体删除）|
| `kenzok8/openwrt-daede` | `bake_daede` | ❌ **已移除**（连带 `enable_honk`，两者依赖内核 BTF，已一并删除）|

### 原配方实际多装了什么（本机实测）

`apk list --installed` 共 **326** 个包，其中来自非官方源的有 **7 个**：

```
luci-app-run-1.0.0-r9                  {feeds/wkd}
luci-app-store-0.2.1-r1                {feeds/istore}
luci-lib-taskd-1.0.26                  {feeds/istore}
luci-lib-xterm-4.18.0                  {feeds/istore}
taskd-1.0.3-r2                         {feeds/istore}
luci-theme-argon-3.1.2-r20261102       额外主题（官方 luci 源，但非默认）
luci-i18n-argon-config-zh-cn-...       同上
```

本仓库默认构建**移除以上全部**，固件内容 = 官方源默认包集。

### ⚠️ 为什么 seed 里必须显式写 `luci`

ImmortalWrt 的 `include/target.mk` 里，**`master` 把这行注释掉了，`25.12` 是启用的**：

```make
# master
# DEFAULT_PACKAGES += $(DEFAULT_PACKAGES.tweak)
# openwrt-25.12
DEFAULT_PACKAGES += $(DEFAULT_PACKAGES.tweak)
```

而 tweak 段的内容正是（25.12）：

```make
DEFAULT_PACKAGES.tweak:= block-mount default-settings-chn kmod-nf-nathelper luci
```

**后果**：基于 `master` 直接编，固件里没有任何 LuCI —— 没有 `uhttpd`、没有
`luci-mod-*`、没有主题，刷完只能 SSH，**无法通过 web 管理**。

所以 `config/mt5000.seed` 显式补齐了 25.12 的 tweak 段：

| 包 | 作用 |
|---|---|
| `luci` | LuCI 全套（`luci-light` + 软件包管理，含 `uhttpd` 与 bootstrap 主题）|
| `block-mount` | 开机自动挂载磁盘（`fstab` 生效）|
| `default-settings-chn` | 中国化默认设置（apk 源切国内镜像 / NTP / 时区 `CST-8`）|
| `kmod-nf-nathelper` | FTP/SIP 等老协议的 NAT 穿透 |

外加少量基础增强：`bash` / `curl` / `ip-full` / `autocore`（CPU 型号、频率、温度状态页）。

> `default-settings-chn` 会改写软件源：把 `/etc/apk/repositories.d/distfeeds.list`
> 里的 `https://downloads.immortalwrt.org` 换成 `https://mirrors.vsean.net/openwrt`。
> 这是 **ImmortalWrt 项目自己的镜像入口**（302 跳转到北大开源镜像站
> `mirrors.pku.edu.cn/immortalwrt`），不是第三方源；本目标快照的包索引
> （`snapshots/targets/mediatek/filogic/packages/packages.adb`）实测两边都返回 200。
> 要换源只需预置 `system.@imm_init[0].apk_mirror`——上游脚本在这项为空时才填默认
> 值，随后用它去替换 `downloads.immortalwrt.org` 前缀。

**刻意不编入**的（对照组）：USB 上网卡全家桶（`kmod-usb-net-*` / `uqmi` / `umbim`）、
所有透明代理相关（`v2ray-geoip/geosite`、`kmod-nft-tproxy`、`kmod-sched-bpf`、
内核 BTF）、`ttyd`、`luci-app-diskman/openclash/rclone`。
这些只为缩短构建时间与固件体积，需要时在 seed 里加一行即可恢复。

CI 与 `scripts/build-local.sh` 的 sanity check 都会校验上面四个对齐项，
少一个直接报错，避免"又编出一个没有 web 的固件"。

### 内核调试：dynamic debug（已开启）

`config/mt5000.seed` 里开了 `CONFIG_KERNEL_DYNAMIC_DEBUG=y`（连带
`CONFIG_KERNEL_DEBUG_FS=y`），把 `pr_debug()` / `dev_dbg()` 编进内核，
**运行时**按源文件 / 函数 / 行号 / 模块开关日志，不用重编内核。

代价是内核 text 约 +2%（几 MB），默认全部关闭，对正常转发零开销。

```bash
# debugfs 已由 /etc/init.d/boot 自动挂到 /sys/kernel/debug
CTL=/sys/kernel/debug/dynamic_debug/control

# 打开某个驱动的调试日志
echo 'file mtk_eth_soc.c +p' > $CTL
dmesg -w | grep -i -E 'mtk|ppe'

# 只看某个函数 / 模块
echo 'func mtk_flow_offload +p' > $CTL
echo 'module rtl8366ub +p'      > $CTL

# 看当前有哪些可开关的点
grep -c '=_' $CTL          # 未开启的可调点数量
grep '=p' $CTL             # 已开启的

# 收工，全部关掉（不重启也能恢复干净状态）
echo 'file * -p' > $CTL
```

内核启动参数里也能预置，例如 `dyndbg="file mtk_eth_soc.c +p"`。
定位完问题后把 seed 里那行删掉即可回到原来的镜像。

---

## 本仓库相对原作者的全部改动

### 1. 配置精简（减法为主，少量加法）

**减法**：

| 项 | 原因 |
|---|---|
| `wpad*` / `hostapd-common` / `wpa-supplicant` | MT5000 **无 Wi-Fi 射频**。这三个包在本机启动即失败（`ubus: Unable to resolve path for module 'common'`），白占约 **18 MB** RAM |
| `miniupnpd` / `luci-app-upnp` | 默认关闭，减少攻击面。需要 NAT-PMP 时在 LuCI 手动开 |
| `luci-app-store` / iStore / `taskd` / `luci-lib-*`（含 istore feed 与 `store_mode` 输入）| 第三方源整体删除，构建时连 feed 都不再拉取 |
| `luci-app-run`（含 wkd feed 与 `enable_luci_app_run` 输入）| 同上 |
| `luci-theme-argon` | 第三方主题，默认用 bootstrap |
| USB 上网卡全家桶（`kmod-usb-net-*` / `uqmi` / `umbim` / `kmod-usb-serial*`）+ `files/etc/hotplug.d/net/30-usbmodem-auto` | 不用 USB 4G/5G 模块，约 20 个内核模块；驱动没了，那个「即插即用」hotplug 脚本只会空跑，一并删除 |
| 透明代理相关（`v2ray-geoip/geosite`、`kmod-nft-tproxy`、`kmod-sched-bpf`、`kmod-xdp-sockets-diag`、`kmod-veth`、`kmod-nft-queue`、内核 BTF）| 只做有线路由，BTF 还是内核编译时间的大头 |
| `ttyd` / `luci-app-ttyd` / `luci-app-diskman` / `luci-app-openclash` / `luci-app-rclone` | 非必需；rclone 会拖进整套 Ruby（约 10 个包）|
| daede / honk 整套功能（workflow 的 `bake_daede`、`enable_honk` 输入 + `config/honk/`）| 依赖内核 BTF，已随 BTF 一并彻底移除 |

**加法**（补齐 25.12 默认包集，否则没有 web 管理）：

| 包 | 原因 |
|---|---|
| `luci` / `block-mount` / `default-settings-chn` / `kmod-nf-nathelper` | master 的 `target.mk` 不追加 `DEFAULT_PACKAGES.tweak`，必须显式写出，详见上一节 |
| `bash` / `curl` / `ip-full` / `autocore` | 基础增强 + CPU 状态页 |
| `CONFIG_KERNEL_DYNAMIC_DEBUG` + `CONFIG_KERNEL_DEBUG_FS` | 内核调试：`pr_debug` 运行时按文件/函数开关，排障用，见上文「内核调试」一节 |

### 2. DSA 端口统计修复（`patches/0005`）

**症状**：`/sys/class/net/lanN/statistics/*` 显示的不是该端口自己的计数。

**根因**：`rtl8366ub_dsa.c` 的 `dsa_switch_ops` 只注册了
`get_ethtool_stats()`，**没有 `rtnl_link_stats64`**（全文件 `ndo_get_stats64`
搜索 0 处）。内核读 `statistics/*` 时调不到驱动的 `get_stats64`，
回退到 conduit（交换机 CPU 口）的聚合值，导致所有 LAN 口显示相同数字。

本机实测（压测中同时打流）：

```
driver 层：lan1 rx 6.88 GB / lan2 rx 2.1 KB     ← 错（聚合值）
ASIC  层：lan1 +4140 MB / lan2 +2584 MB         ← 对（ethtool -S 直读 MIB）
```

**修复**：在被 vendored 的 `795-10` 补丁内部注册
`rtl8366ub_sw_get_stats64()`，复用已有的 `rtl8366ub_mib_get_stats()`
读取硬件 MIB 寄存器，映射到 `struct rtnl_link_stats64`。

**注意**：驱动源码**内嵌在 `795-10-net-dsa-realtek-add-rtl8366ub.patch` 里**，
不是 buildroot 树里的独立 `.c` 文件。所以 `0005` 编辑的是那个 pending patch，
并且必须同步两处嵌套行数声明：

```
0001 里 795-10 的整文件声明   @@ -0,0 +1,3629  @@
0002-0007 叠加之后            @@ -0,0 +1,3729  @@   （+100 行）
内层同理：改了 795-10 里哪个 .c，就要同步它自己的 @@ -0,0 +1,N @@
```

两处数字均由真实 `git apply` 0001 后的结果推导，非人工计数。

### 3. 合规

补 GPL-2.0 [LICENSE](LICENSE) 与本文件的来源声明。

---

## 分支说明

| 分支 | 内容 | 用途 |
|---|---|---|
| **`master`** | **纯原作者代码**，与 `Kitsune2077/mt5000-immortalwrt` 保持一致 | 跟踪上游 |
| **`dev`** | 原作者代码 + 上述全部改动（配置精简、`patches/`、README、LICENSE）| 实际构建用 |

### 同步原作者更新到 master

```bash
git remote add upstream https://github.com/Kitsune2077/mt5000-immortalwrt.git
git fetch upstream
git checkout master
git merge --ff-only upstream/main
git push origin master
```

### 把上游更新并入 dev

```bash
git checkout dev
git rebase master        # 或 git merge master
```

---

## 使用方法

1. Fork 本仓库（或在 Actions 页面直接 Run workflow）
2. **Actions** → **Build ImmortalWrt for GL.iNet MT5000** → **Run workflow**
3. 关键输入项：

| 输入 | 默认 | 说明 |
|---|---|---|
| `iwrt_ref` | 空 | 留空用默认基线 `4765b65762`（2026-11-05，内核 6.18，有 PPE 加速）|
| `lan_ip` | `10.0.0.1` | 默认 LAN 地址 |
| `root_password` | `root` | 建议改掉 |
| `extra_services` | `none` | 附加服务：`none` / `mwan3` / `docker` / `docker+mwan3` |
| `extra_packages` | 空 | 额外编入的官方包，空格分隔 |

4. 缓存命中约 **50–80 分钟**（toolchain/staging_dir + ccache），冷启动约
   2.5–3 小时；完成后在 **Artifacts** 或 **Release** 下载
   `*glinet_gl-mt5000-squashfs-sysupgrade.bin`
5. 刷机：原厂固件升级页上传，或 SSH 内 `sysupgrade -n <image>`

> 注意：`workflow_dispatch` 的 inputs 有 **25 个上限**（原作者写到 26 个，手动
> 触发一直被 API 拒绝，HTTP 422）。本仓库现在只剩 18 个，因为把双基线
> `iwrt_profile`、`store_mode`、`enable_luci_app_run`、`bake_daede`、
> `enable_honk`、`luci_flavor`、`luci_extra_apps` 全部删掉了。

---

## 本地编译

`scripts/build-local.sh` 把 CI 的 597 行构建逻辑抽了出来，CI 和本地跑同一套
流程。改补丁后不必等 2.5 小时的 CI，本地增量编译通常 10–30 分钟。

```bash
./scripts/build-local.sh --help          # 全部参数
./scripts/build-local.sh                 # 全默认，编 master
./scripts/build-local.sh --from build    # 改完补丁后只重编
./scripts/build-local.sh --jobs 9        # 内存小的机器手动降并行度
```

### 环境要求

| 项 | 要求 | 说明 |
|---|---|---|
| 系统 | Linux / WSL2 | **不能在 `/mnt/c`、`/mnt/e` 等 Windows 盘上编译** |
| 文件系统 | **大小写敏感** | OpenWrt 的 `prereq-build.mk` 有 `case-sensitive-fs` 硬检查，SMB / NTFS 上必失败 |
| 磁盘 | ≥ 45G | `build_dir` 20–40G + `dl` 2.5G + `staging_dir` 4G |
| 内存 | 每并行进程约 1.3G | 脚本按内存自动算 `-j`，不够会警告 |
| umask | 022 | 否则打出来的包权限错乱 |

依赖（Debian/Ubuntu）：

```bash
sudo apt install -y --no-install-recommends \
  build-essential gcc-multilib g++-multilib ccache \
  libncurses-dev zlib1g-dev libssl-dev libelf-dev libltdl-dev \
  libmpc-dev libmpfr-dev libgmp-dev libpython3-dev libreadline-dev \
  bison flex gettext gawk pkg-config rsync unzip bzip2 patch \
  subversion swig python3 python3-ply python3-docutils python3-pyelftools \
  device-tree-compiler cpio squashfs-tools mkisofs xxd \
  autoconf automake autopoint libtool libglib2.0-dev libyaml-dev \
  intltool help2man ack nano wget curl git
```

### 与 CI 的差异

本地脚本刻意不做 GitHub 专属的事（缓存 prune/restore、artifact 上传、Release
发布）。此外：

- **ccache 上限放大到 5G**（CI 限 1G 是因为仓库缓存总配额 10G）
- **支持 `--from <step>` 断点续跑**，CI 每次都从头
- **并行度按内存而非核数决定**，避免容器/虚拟机里 OOM
- **补丁步骤幂等**：用 `base SHA + 补丁清单` 做标记，重复跑会跳过；
  基线 commit 或补丁清单变了才会重置代码树再重打（`build_dir`/`staging_dir` 不受影响）

### 断点续跑

| `--from` | 适用场景 |
|---|---|
| `validate` | 默认，从头 |
| `clone` | 只重新 checkout 基线 |
| `patch` | 改了补丁文件 |
| `overlay` | 改了 `files/` 或 feed 开关 |
| `config` | 改了 `config/mt5000.seed` 或 Kconfig 选项 |
| `uci` | 改了时区/主机名/密码/IPv6 等运行参数 |
| `download` | 只重新下载依赖包 |
| `build` | 快速迭代：源码、补丁、配置都没动 |

---

## 已知问题

仍在测试中

---

## 许可

构建配方、脚本与补丁以 **GPL-2.0** 发布，见 [LICENSE](LICENSE)。
固件产物因包含 Linux 内核及 GPL 组件，同样受 GPL-2.0 约束；
再分发时须随附对应源码——本仓库的 workflow 与 patch 即构成完整可复现路径。
