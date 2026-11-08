# GL.iNet GL-MT5000 · ImmortalWrt 6.18 移植记录

> **当前状态：本地编译已跑通｜首轮实机验证完成（LAN 链路抖动已修复并验证）｜其余项测试进行中**
>
> 本仓库只用于记录补丁与开发过程，固件一律在**本地**编译，不使用 CI 构建。
> 已完成刷机与首轮实机验证（详见第 7 节），MTU、VLAN、温度与长期稳定性
> 尚未覆盖，请勿用于生产环境。

---

## 1. 目前进展

| 项目 | 情况 |
| --- | --- |
| 源码基线 | ImmortalWrt `master` @ `4765b657625ec5bbda74b44400465fe043802b30`，Linux **6.18.60** |
| 目标设备 | `mediatek/filogic` → `glinet_gl-mt5000` |
| 补丁系列 | `patches/` 下 **7 个 `format-patch` 提交**，按文件名顺序应用 |
| 编译结果 | 2026-11-08 20:53 `BUILD_EXIT=0`（7 提交）；增量重编 6 分钟（仅内核与镜像重打） |
| 产物校验 | `sha256sums` 16 项全部 `OK`；固件包清单 **172 个包**；`rtl8366ub_phy.o` 已确认引用 `usleep_range_state` |
| 运行期配置 | 未做 LAN IP / 密码 / 首启脚本定制，沿用官方默认（LAN `192.168.1.1`） |
| **实机测试** | **首轮已完成**：刷机、LAN 口链路与热插拔、PPE 卸载、端口统计、LAN/WAN 吞吐；MTU、VLAN、温度、长期稳定性待补（见第 7 节） |

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

在此基础上做了三处改进，各自作为独立提交（`0005` / `0006` / `0007`）：

1. **`get_stats64` — 每端口流量统计**
   驱动原本只提供 `get_ethtool_stats()`，未实现 `get_stats64`，于是
   `/sys/class/net/lanN/statistics/*`、`ifconfig` 和 LuCI 概览页会回退到
   DSA 核心默认值，把 conduit 的聚合流量算到每个用户口上。新增回调读取
   ASIC MIB 并映射到 `rtnl_link_stats64`。
   实测前：lan1 rx 6.88 GB / lan2 rx 2.1 KB（聚合值）；ASIC 真值：
   lan1 +4140 MB / lan2 +2584 MB。
2. **`port_max_mtu` — 放开用户口 MTU 上限**
   DSA 只在驱动提供 `port_max_mtu` 时抬高用户口 `max_mtu`，否则 lan1/lan2
   被 `ETH_DATA_LEN` 限制在 1500（conduit 实际可到 2030）。新增回调返回
   9000，有效值仍由 DSA 以 `min(conduit->max_mtu, ...)` 钳制。
3. **`0007` — PHY 链路状态去抖**
   `rtl8366ub_phy_read_status()` 用一次 OCP 间接读就直接决定 `phydev->link`，
   偶发的坏读数会让 phylib 关掉 carrier、丢弃当时排队的帧。实测开机 60 分钟
   内 67 次 Link Down，每次精确 1.0 s 恢复，lan1/lan2 交替出现，LuCI 概览
   页因此反复显示"未连接"。改动为：状态翻转时先复读确认，仍不一致则要求
   连续 2 个轮询周期都读到新状态才采纳，真实插拔比单次采样最多晚一个周期。
   刷入该版后同一台设备 480 s 内 **0 次自发 Down**（基线预期约 9 次），
   真实插拔仍在 1–2 s 内上报，详见第 7 节。

另外把这两处改动按上游 `795-10` 的真实行号与 tab 缩进重新对齐，校正了
vendored patch 内层 hunk 计数（952 → 1002 → 1012），并补齐合规的
commit message 与 `Signed-off-by`，便于后续提交评审。

## 3. 本次编译包含的包（172 个）

配置来自 `config/mt5000.seed`（目标选择 + 6 个显式包），其余由平台默认包
与依赖关系展开。以下是 `...glinet_gl-mt5000.manifest` 的完整清单，按用途分组。

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

## 4. 本次编译产物

| 文件 | 大小 | 用途 |
| --- | --- | --- |
| `...-squashfs-sysupgrade.bin` | 12 MB | 日常升级 |
| `...-squashfs-factory.bin` | 39 MB | 从原厂固件首次刷入 |
| `...-initramfs-kernel.bin` | 11 MB | 内存启动 / 救砖 |
| `...-glinet_gl-mt5000.manifest` | 5 KB | 包清单（上一节数据来源） |

产物位于 `immortalwrt/bin/targets/mediatek/filogic/`，刷机前先执行
`sha256sum -c sha256sums`。**刷机请自行确认；本仓库产物为自用构建，不提供任何担保。**

## 5. 本地编译方法

环境与依赖：Ubuntu 24.04（本次在 NAS 虚拟机，8 核 / 7.8 GB 内存 / 250 GB
空闲磁盘，`make -j4`）；需要 `git make gcc g++ python3 flex bison pkg-config
libncurses-dev zlib1g-dev libssl-dev libelf-dev device-tree-compiler cpio
squashfs-tools mkisofs rsync unzip gettext xxd` 等常规 OpenWrt 构建依赖。

```bash
git clone https://github.com/foxsfire/gl-mt5000.git mt5000-immortalwrt
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

## 6. 已知事项

- **ImmortalWrt 基线适配**：`backport-6.18/967-03` 引入 `NET_DSA_YT921X`，
  但 `target/linux/generic/config-6.18` 缺对应行，内核 `syncconfig` 会以
  `(NEW)` 交互提问导致非交互编译失败。`build-local.sh` 在应用补丁后补
  `# CONFIG_NET_DSA_YT921X is not set`。这一行**不属于上游四提交**
  （`0001`–`0004`），是将来把系列提交到 ImmortalWrt 主线时需要单独处理的
  基线 fix。
- PR #24237 目前仍是 `open`，OpenWrt 与 ImmortalWrt 主线都尚未合入，
  因此仍需自行打补丁做全源码编译。
- 旧的「内核补丁 dry-run 门禁」是针对被替换掉的折叠补丁写的，已移除；
  补丁正确性以完整编译验证为准。

## 7. 硬件实测

### 7.1 已验证（GL-MT5000 实机，2026-11-08）

| 项目 | 结论 |
| --- | --- |
| 刷机与固化 | `sysupgrade` 正常；运行内核已通过 eMMC `mmcblk0p6` 分区与镜像 FIT 逐字节比对确认 |
| 端口协商 | `lan1`/`lan2`/`eth0`/`eth1` 均为 **2500 Mbps 全双工** |
| LAN↔LAN 转发 | RTL8366UB 交换芯片**硬件直通**：手机↔内网 iperf3 1.66 Gbps 时 `eth0`（CPU 上行口）计数为 0、四核占用 1.3% |
| WAN↔LAN 卸载 | MTK PPE 生效：下行 1.1 Gbps 期间 `ppe1_bytes` 以约 126 MB/s 递增、四核占用 1.4–2.7% |
| 吞吐基线 | 手机（WiFi 桥接经 `lan1`）下行 >1.3 Gbps、上行 1.0–1.28 Gbps；路由器本机↔内网主机单流双向 2.3–2.5 Gbps、零重传 |
| LAN2「未连接」现象 | 定位为 `rtl8366ub_phy_read_status()` 单次采样判 `link`，第 7 提交去抖后 480 s 内 **0 次**自发 Down（基线预期约 9 次），真实插拔仍在 1–2 s 内上报 |
| 每端口统计 | `lan1`/`lan2` 计数准确（偏差即以太网帧开销）；`br-lan`、`pppoe-wan` 漏计是硬件交换与 PPE 卸载的正常结果，不是故障 |

补充两点实测记录：PPE 表在 debugfs 的真实路径是 `/sys/kernel/debug/ppe0`、
`/sys/kernel/debug/ppe1`（不是早期文档里的 `mtk_ppe/`）；软件路径上的
`br-lan` / `pppoe-wan` 包计数会被 GRO/GSO 聚合，平均每「包」可达数十 KB，
按包对比没有意义，按接口算账应读 `lan1`/`lan2` 或使用 `nlbwmon`。

### 7.2 待验证

- 用户口 MTU、`tag_8021q` 的 VLAN 增删与 bridge 反复操作
- 待机与满载温度、`ethtool` 计数，以及与 MTK 原生标签设备的回归对比
- 长时间（数天）稳定性，以及链路抖动在长窗口下的复核

> 首轮结论仅覆盖上述已验证项；未覆盖项请勿视为通过。

---

许可证：GPL-2.0（见 [LICENSE](LICENSE)）
