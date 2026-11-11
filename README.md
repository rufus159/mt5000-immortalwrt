# GL.iNet GL-MT5000 · ImmortalWrt 6.18 移植记录

> **当前状态：本地编译已跑通｜P0「LAN 口假掉线」根因已定位并实机验证｜部分项目仍在测试中**
>
> 本仓库只记录补丁、构建配方与验证结论。**固件一律在本地编译，不发布二进制、
> 不使用 CI 构建、不提供 Release 下载**：此前上传的 `mt5000-r30` Release 已于
> 2026-11-11 下线删除。文中结论严格区分「已验证」与「仍在测试中」，
> 未实测项一律不作结论，请勿用于生产环境。

---

## 1. 目前进展

| 项目 | 情况 |
| --- | --- |
| 源码基线 | ImmortalWrt `master` @ `4765b657625ec5bbda74b44400465fe043802b30`，Linux **6.18.60** |
| 目标设备 | `mediatek/filogic` → `glinet_gl-mt5000` |
| 补丁系列 | `patches/` 下 **7 个 `format-patch` 提交**，按文件名顺序应用 |
| 编译结果 | 2026-11-08 `BUILD_EXIT=0`；2026-11-11 第六版测试固件 v1/v2 各 `BUILD_EXIT=0`（增量各 8 分钟） |
| 从零复编 | 2026-11-08 清空源码树 / `dl` / 旧日志后重跑：7 个补丁全部 `ok`，`make download` 一次成功，编译阶段 37 分钟，`BUILD_EXIT=0`，包清单与首次构建**逐行一致**（172 条） |
| 产物校验 | `sha256sums` **16 项全部 `OK`**；正式口径 **172 个包**（测试固件另加 5 个调试包，共 180，不对外） |
| 可重现性 | 同一源码两次全量构建包清单逐行一致，但**镜像不是位级可重现**（时间戳进入 FIT/rootfs） |
| 固件分发 | **不发布**。仓库不含任何固件二进制；刷机由使用者自行本地编译 |
| **P0 状态** | **根因已定位并实机验证**：MDIO 间接访问序列未串行化。详见第 6.3 节与 [docs/2026-11-11-P0根因定位报告.md](docs/2026-11-11-P0根因定位报告.md) |
| 实机测试 | 四轮实机验证，覆盖刷机、链路、吞吐、卸载、统计、VLAN/bridge、温度、长稳（见第 7 节） |

补丁已确认真正落地到内核源码树，而不只是补丁文件写对：`rtl8366ub_dsa.c` 中
`get_stats64` 与 `port_max_mtu` 回调均已注册，`999-90` 对
`net/netfilter/nf_flow_table_path.c` 的 PPE 路径改动也已生效；内核配置里
`NET_DSA_TAG_RTL8366UB_8021Q=y`、`NET_DSA_REALTEK_RTL8366UB=y`。

## 2. 参考来源与本次改进

设备支持、RTL8366UB DSA 驱动、MediaTek 原生标签处理与 PPE 卸载这一整套实现，
**参考借鉴了 OpenWrt 上游 [PR #24237](https://github.com/openwrt/openwrt/pull/24237)**
（GL.iNet `GLiNet-Tech`，Hongjian Zhang、Tao Luo 等）的四个提交；
`patches/0001`–`0004` 即该系列，保留了原作者信息。构建配方与补丁分层的
组织方式参考了 [Kitsune2077/mt5000-immortalwrt](https://github.com/Kitsune2077/mt5000-immortalwrt)。

在此基础上，各自作为独立提交增加了 `0005` / `0006` / `0007`：

1. **`get_stats64` — 每端口流量统计**
   驱动原本只提供 `get_ethtool_stats()`，未实现 `get_stats64`，于是
   `/sys/class/net/lanN/statistics/*`、`ifconfig` 和 LuCI 概览页会回退到
   DSA 核心默认值，把 conduit 的聚合流量算到每个用户口上。新增回调读取
   ASIC MIB 并映射到 `rtnl_link_stats64`。
   实测前：lan1 rx 6.88 GB / lan2 rx 2.1 KB（聚合值）；ASIC 真值：
   lan1 +4140 MB / lan2 +2584 MB。
2. **`port_max_mtu` — 放开用户口 MTU 上限**
   DSA 只在驱动提供 `port_max_mtu` 时抬高用户口 `max_mtu`，否则 lan1/lan2
   被 `ETH_DATA_LEN` 限制在 1500。新增回调返回 9000，有效值仍由 DSA 以
   `min(conduit->max_mtu, ...)` 钳制。**这一提交不完整**，实测改不动 MTU，
   见第 6.4 节。
3. **`0007` — PHY 链路状态去抖（workaround）**
   `rtl8366ub_phy_read_status()` 用一次 OCP 间接读就直接决定 `phydev->link`，
   偶发坏读数会让 phylib 关掉 carrier、丢弃当时排队的帧。实测开机 60 分钟
   内 67 次 Link Down，每次精确 1.0 s 恢复，lan1/lan2 交替出现。改动为状态
   翻转时先复读确认、再要求连续 2 个轮询周期一致才采纳。
   该提交**只是过滤后果**：根因（第 6.3 节）已在 2026-11-11 定位，去抖具备
   删除条件，待长窗口回归后删除。

另外把这两处改动按上游 `795-10` 的真实行号与 tab 缩进重新对齐，校正了
vendored patch 内层 hunk 计数（952 → 1002 → 1012），并补齐合规的
commit message 与 `Signed-off-by`，便于后续提交评审。

## 3. 编译包含的包（172 个）

配置来自 `config/mt5000.seed`（目标选择 + 6 个显式包），其余由平台默认包
与依赖关系展开。以下是 `...glinet_gl-mt5000.manifest` 的完整清单，按用途分组。
（测试固件额外安装的 `tcpdump / iperf3 / ethtool / ip-full / strace` 属临时调试，
不在正式清单内。）

### 系统基础与工具（44）

```
apk-openssl, autocore, base-files, blkid
block-mount, blockdev, busybox, default-settings
default-settings-chn, fit-check-sign, fitblk, fstools
fwtool, getrandom, jshn, jsonfilter
logd, mkf2fs, mtd, netifd
openwrt-keyring, procd, procd-seccomp, procd-ujail
shellsync, ubi-utils, uboot-envtools, ubox
ubus, ubusd, uci, ucode
ucode-mod-digest, ucode-mod-fs, ucode-mod-html, ucode-mod-log
ucode-mod-nl80211, ucode-mod-rtnl, ucode-mod-ubus, ucode-mod-uci
ucode-mod-uloop, urandom-seed, urngd, usign
```

### 网络、防火墙与无线（25）

```
bridger, ca-bundle, dnsmasq-full, dropbear
firewall4, hostapd-common, libiwinfo-data, libiwinfo20230701
libmnl0, libnetfilter-conntrack3, libnfnetlink0, libnftnl11
libnl-tiny1, libopenssl-conf, libopenssl-legacy, libopenssl3
libuclient20201210, libustream-openssl20201210, nftables-json, odhcp6c
odhcpd-ipv6only, ppp, ppp-mod-pppoe, uclient-fetch
wpad-openssl
```

### LuCI Web 界面（27）

```
cgi-io, liblucihttp-ucode, liblucihttp0, luci
luci-app-firewall, luci-app-package-manager, luci-base, luci-i18n-base-zh-cn
luci-i18n-firewall-zh-cn, luci-i18n-package-manager-zh-cn, luci-lib-uqr, luci-light
luci-mod-admin-full, luci-mod-network, luci-mod-status, luci-mod-system
luci-proto-ipv6, luci-proto-ppp, luci-theme-bootstrap, rpcd
rpcd-mod-file, rpcd-mod-iwinfo, rpcd-mod-luci, rpcd-mod-rrdns
rpcd-mod-ucode, uhttpd, uhttpd-mod-ubus
```

### 内核与内核模块（53）

```
kernel, kmod-crypto-aead, kmod-crypto-authenc, kmod-crypto-crc32
kmod-crypto-crc32c, kmod-crypto-des, kmod-crypto-hash, kmod-crypto-hmac
kmod-crypto-hw-safexcel, kmod-crypto-manager, kmod-crypto-md5, kmod-crypto-null
kmod-crypto-sha1, kmod-crypto-sha256, kmod-crypto-sha512, kmod-fs-ext4
kmod-fs-f2fs, kmod-fs-vfat, kmod-gpio-button-hotplug, kmod-leds-gpio
kmod-lib-crc-ccitt, kmod-lib-crc16, kmod-libphy, kmod-macvlan
kmod-mmc, kmod-mppe, kmod-nf-conntrack, kmod-nf-conntrack-netlink
kmod-nf-flow, kmod-nf-log, kmod-nf-nat, kmod-nf-nathelper
kmod-nf-reject, kmod-nf-reject6, kmod-nfnetlink, kmod-nft-core
kmod-nft-fib, kmod-nft-fullcone, kmod-nft-nat, kmod-nft-offload
kmod-nls-base, kmod-nls-cp437, kmod-nls-iso8859-1, kmod-nls-utf8
kmod-phy-mediatek-2p5g, kmod-ppp, kmod-pppoe, kmod-pppox
kmod-sched-act-vlan, kmod-sched-bpf, kmod-sched-core, kmod-sched-flower
kmod-slhc
```

### 运行库（21）

```
jansson4, libblkid1, libblobmsg-json20261103, libbpf1
libc, libelf1, libf2fs6, libgcc1
libgmp10, libjson-c5, libjson-script20261103, libnettle8
libpthread, librt, libubox20261103, libubus20261028
libuci20250120, libucode20261009, libudebug, libuuid1
zlib
```

### 硬件固件（2）

```
eip197-mini-firmware, mt7987-2p5g-phy-firmware
```

## 4. 编译产物与分发

本地编译会在 `immortalwrt/bin/targets/mediatek/filogic/` 生成：

| 文件 | 大小 | 用途 |
| --- | --- | --- |
| `...-squashfs-sysupgrade.bin` | 12 MB | 日常升级 |
| `...-squashfs-factory.bin` | 39 MB | 从原厂固件首次刷入 |
| `...-initramfs-kernel.bin` | 11 MB | 内存启动 / 救砖 |
| `...-glinet_gl-mt5000.manifest` | 5 KB | 包清单（上一节数据来源） |

刷机前先执行 `sha256sum -c sha256sums`。

> **本仓库不托管任何固件二进制，也不创建 Release。** 2026-11-08 曾发布一版
> `mt5000-r30`（第四版，含 7 个附件），已于 2026-11-11 全部删除：该版基于
> 现已被推翻的根因判断，继续流通只会造成误导。后续所有验证固件仅用于本地
> 实机测试，不对外分发。

## 5. 本地编译方法

环境与依赖：Ubuntu 24.04（本次在 NAS 虚拟机，8 核 / 7.8 GB 内存 / 250 GB
空闲磁盘，`--jobs 5`）；需要 `git make gcc g++ python3 flex bison pkg-config
libncurses-dev zlib1g-dev libssl-dev libelf-dev device-tree-compiler cpio
squashfs-tools mkisofs rsync unzip gettext xxd` 等常规 OpenWrt 构建依赖。
从空目录（含 `dl` 全部重下）到出固件实测 **48 分钟**，其中编译阶段 37 分钟；
已有源码树与 `dl` 时增量重编约 **8 分钟**。

```bash
git clone https://github.com/rufus159/mt5000-immortalwrt.git
cd mt5000-immortalwrt
./scripts/build-local.sh --dry-run              # 先看配置
./scripts/build-local.sh --jobs 4               # 从头编译
./scripts/build-local.sh --from patch --jobs 4  # 改完补丁增量重跑
```

脚本流程：克隆/复用源码 → 按顺序应用 `patches/` 的 7 个提交 → 补基线
Kconfig 缺失符号 → `make defconfig` → `make download` → `make`。
可选环境变量 `MT5000_LOCAL_BPF_HOST_CLANG=1` 让构建机用主机 clang 跳过
`tools/llvm-bpf` 源码编译（默认关闭，不改变固件内容）。
`--from` 支持 `validate|clone|patch|overlay|config|download|build`。

仓库不含 `.github/workflows`，不跑 GitHub Actions 构建。

> 构建机经验（2026-11-11）：`feeds update` 失败报
> `GnuTLS recv error (-9)` / `early EOF` 时，先确认 `git` 是否**显式**配置了
> 代理——只靠 TUN 透明代理时大对象传输容易被截断。给
> `http.https://github.com.proxy` 指定 HTTP CONNECT 代理、
> 调大 `http.postBuffer` 并放开低速中断（`lowSpeedLimit 0`）即可。

## 6. 已知事项

### 6.1 基线适配

`backport-6.18/967-03` 引入 `NET_DSA_YT921X`，但
`target/linux/generic/config-6.18` 缺对应行，内核 `syncconfig` 会以
`(NEW)` 交互提问导致非交互编译失败。`build-local.sh` 在应用补丁后补
`# CONFIG_NET_DSA_YT921X is not set`。这一行**不属于上游四提交**
（`0001`–`0004`），是将来把系列提交到 ImmortalWrt 主线时需要单独处理的
基线 fix。

PR #24237 目前仍是 `open`，OpenWrt 与 ImmortalWrt 主线都尚未合入，
因此仍需自行打补丁做全源码编译。

### 6.2 已排除的假设（避免重复论证）

| 假设 | 核查结论 |
| --- | --- |
| `reg_read()` 发 READ_OP 后不等完成、缺完成确认 | 本驱动、官方 SDK `smi.c`、RTL8372N 外部驱动三家逐行一致，**排除** |
| OCP 事务完全没有互斥 | `rtl8366ub_ocp_read()` 已有 `phy_mutex` 包住全过程，**排除** |
| 100 次无延时忙等过早退出 | 官方 SDK 超时常量同为 100、同样无延时，**排除** |
| 硬件去抖 `LINK_DOWN_CHK @ 0x01B8` 未配置 | 官方 SDK 全仓只有字段定义、无任何写入，量产同样不配，**降级为可选实验** |

### 6.3 P0 根因：MDIO 间接访问序列未串行化（已验证）

官方 SDK（`gl-inet/gl-rtl8366ub`）用一把全局锁串行化全部 DAL 调用：

```c
DEFINE_MUTEX(rtksw_api_mutex);
#define RTKSW_API_LOCK(unit)   mutex_lock(&rtksw_api_mutex)
```

全仓 26 个 `.c`、**543 处** `RTKSW_API_LOCK`，`prepare → CMD → poll BUSY → 读 RDATA`
这种序列在 SDK 中不可能被别的寄存器访问插入。

本驱动有四把互不相干的 mutex（`reg_mutex` / `phy_mutex` / `table_mutex` /
`mib_mutex`），而 `reg_read()/reg_write()` 底层只持 `bus->mdio_lock`，保护的是
**单次** MDIO 事务。所有间接访问共享同一组寄存器
（`CTRL0=31 / ADDRESS=23 / CTRL1=21 / DATA=25`），因此：

```
线程 A (phylib, phy_mutex):  ocp_prepare 写 OCP_MSB / INDACC_ADDR ──┐
线程 B (LuCI 统计, mib_mutex): 写 MIB_ADDR / 读 CMD / 读 DATA  ←──── 插入，改写共享寄存器
线程 A:  ocp_wait → 读 INDACC_RDATA  ──────────────────────────────┘  ← 读到被覆盖的地址上下文
```

`mib.c` / `l2.c` / `cpu.c` / `dsa.c` 的序列都不持 `phy_mutex`，都能与 OCP 事务交错。
这解释了全部观测事实：坏值是整个 16 位字、有时落在「合法但错误」的组合
（`speed=10/1000`）、carrier 恒 1 而 speed 乱跳、瞬态只出现在有 LuCI/SSH 会话
的时段（LuCI 概览页轮询 `get_stats64` 是天然并发读者）。

**实机 A/B 验证**（同一固件、同一并发压力，只切换运行时开关）：

| 阶段 | 时长 | OCP 读次数 | 坏读计数增量 | speed 瞬态 |
| --- | --- | --- | --- | --- |
| 统一锁**开** | 150 s | 18,328 | **0** | 无 |
| 统一锁**关** | 150 s | 18,878 | **7** | `lan2 speed=-1`，2 s 恢复 |

结论：**这是根因修复，不是 workaround**。`0007` 的去抖只是过滤后果，具备删除
条件（删除后仍需 24–72 h 长窗口复核）。修复以「补丁套补丁」形式（`0008` →
`pending-6.18/795-13`）在本地验证，尚未并入本仓库的 `patches/`：需要先整理成
可提交 PR #24237 的干净补丁，并附上本轮 A/B 数据。

### 6.4 `0006` 不完整：只声明了上限，不能真正改 MTU

`port_max_mtu` 返回 9000，但**没有实现 `ops->port_change_mtu`**，因此
`ip link set lan1 mtu 2000` 直接返回 `RTNETLINK answers: Not supported`，
用户口 MTU 永远锁在 1500。另外 conduit `eth0` 的 `max_mtu` 只有 **2030**
（`MTK_MAX_RX_LENGTH_2K 2048 − 18`），DSA 会把有效值 clamp 到
`min(conduit->max_mtu, ...)`，所以本平台**到不了 9000**。

这是「声明与能力不一致」，主线 reviewer 会挑。官方 SDK 里有
`MAX_LENGTH` / `FC_JUMBO_*` 字段，芯片可配。下一步二选一：
补全 `port_change_mtu`（并写最大帧长寄存器），或**撤掉 `0006`** 以免虚假声明。

## 7. 硬件实测

### 7.1 已验证

**刷机与系统（2026-11-08 / 2026-11-11）**

| 项目 | 结论 |
| --- | --- |
| 刷机 | `sysupgrade` 正常；运行内核已通过 eMMC `mmcblk0p6` 分区与镜像 FIT 逐字节比对确认 |
| 升级路径 | `-k`（保留配置）与 `-n`（不保留配置）**两条路径都验证通过**，重启约 52 s |
| 干净刷机自举 | `-n` 后仅靠固件预置即自动恢复 LAN `192.168.1.1/24`、root 凭据、PPPoE 自动拨号，四口全部 up |
| 端口协商 | `lan1`/`lan2`/`eth0`/`eth1` 均为 **2500 Mbps 全双工**，`ethtool` 报告 Speed 2500Mb/s / Full / Link detected yes |
| 内核健康 | 多轮测试后 `dmesg` 无 oops / panic / call trace（`ramoops` 子串不算） |
| 资源 | 温度 64.7 ℃、负载 0.11、可用内存 859 MB（实测时点） |

**转发、卸载与吞吐**

| 项目 | 结论 |
| --- | --- |
| LAN↔LAN 转发 | RTL8366UB 交换芯片**硬件直通**：手机↔内网 iperf3 1.66 Gbps 时 `eth0`（CPU 上行口）计数为 0、四核占用 1.3% |
| WAN↔LAN 卸载 | MTK PPE 生效：下行 1.1 Gbps 期间 `ppe1_bytes` 以约 126 MB/s 递增、四核占用 1.4–2.7% |
| 吞吐基线（早期） | 手机（WiFi 桥接经 `lan1`）下行 >1.3 Gbps、上行 1.0–1.28 Gbps；路由器本机↔内网主机单流双向 2.3–2.5 Gbps、零重传 |
| 吞吐基线（`-P 4`，2026-11-11） | PC WiFi → 有线主机 30 s：上行 **853–855 Mbps**、下行 **1.11 Gbps**，重传 6。链路与历史数据不同，仅作同批次基线 |

**P0 与稳定性**

| 项目 | 结论 |
| --- | --- |
| 假掉线修复 | 去抖版 480 s、101 分钟、**71.6 h**（138 次心跳）三级窗口均 **0 次自发 carrier 翻转**，真实插拔仍 1–2 s 上报 |
| 根因验证 | 统一锁 A/B：开锁 150 s / 18,328 次 OCP 读 **0 坏读**；关锁 150 s / 18,878 次 **7 次坏读** + `speed=-1` 瞬态（见 6.3） |
| 每端口统计 | `lan1`/`lan2` 计数准确（偏差即以太网帧开销）；`br-lan`、`pppoe-wan` 漏计是硬件交换与 PPE 卸载的正常结果 |
| 丢包 | 71.6 h 内 lan1 568→32、lan2 17→3，长时间恒定零增长；`eth1` 的丢包是 OLT 每 5 s 一帧 `0xfffa` 环路帧（30 s 采样实测精确 5.00 s/帧） |

**DSA 与配置操作（2026-11-11）**

| 项目 | 结论 |
| --- | --- |
| `tag_8021q` VLAN | `lan2.100` 创建 / up / 删除 ×3 全部成功，无残留接口 |
| bridge 反复摘挂 | lan2 `nomaster` → `master br-lan` ×3 全部成功，`br-lan` 保持 up，到对端 ping 0% 丢包 |
| MTU | **未通过**：`0006` 缺 `port_change_mtu`，`ip link set ... mtu` 返回 `Not supported`（见 6.4） |

**现象判读**（便于区分真故障与正常行为）

- `Link is Down` 若伴随 netifd `Interface 'lan' is now down` 与
  `left allmulticast/promiscuous`，是人为 `ifdown/ifup`；无 netifd 动作才是 P0 复发。
- LuCI「系统-插件」是空容器页，不是故障。
- PPE 表在 debugfs 的真实路径是 `/sys/kernel/debug/ppe0`、`ppe1`（不是 `mtk_ppe/`）。
- `br-lan` / `pppoe-wan` 的包计数会被 GRO/GSO 聚合，按包对比没有意义。

### 7.2 仍在测试中

- **删除 `0007` 后的回归**：根因已修，但尚未在正式补丁里删去抖，需 24–72 h 长窗口确认。
- **统一锁补丁入库**：本地已用 `0008` 验证，尚未整理进 `patches/`，也未提交 PR #24237。
- **真实网线拔插**：需人工插拔 lan1 / lan2，验证上报时延与计数。
- **数天级长稳**：守夜服务持续采集中，72 h 报告已出，更长时间窗口待累积。
- **串口 UART 启动日志与 initramfs/TFTP 先验后刷**：未做（SSH 取 `dmesg`/`logread` 已覆盖大部分）。

> 未列入「已验证」的项目请勿视为通过。

---

许可证：GPL-2.0（见 [LICENSE](LICENSE)）
