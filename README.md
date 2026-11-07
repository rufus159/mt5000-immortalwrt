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
**[Beaverfffan/x-wrt-push](https://github.com/Beaverfffan/x-wrt-push)**。

---

## 基于哪个版本的源码

补丁分两套，各针对一个 ImmortalWrt 基线：

| profile | ImmortalWrt 基线 commit | 日期 | 内核 | 补丁目录 |
|---|---|---|---|---|
| `master` | `f44d1535b4ef107a4ee255caa43cf101daf9fa35` | 2026-09-18 | **6.18** | `patches/` |
| `25.12` | `84b665b5de552e297d0f7d755b88a46fc0cfeb13` | 2026-10-23 | 6.12 | `patches-25.12/` |

两个基线都是 ImmortalWrt 的 `Merge Official Source` 提交点（同步上游 OpenWrt）。
`master` 基线可用 `iwrt_ref` 输入覆盖为任意 ImmortalWrt commit。

---

## ⚠️ 两个 profile 能力不同（重要）

| | `master`（6.18） | `25.12`（6.12） |
|---|---|---|
| 设备支持 | ✅ | ✅ |
| RTL8366UB DSA 交换机 | ✅ | ✅ |
| **PPE 硬件加速** | ✅ **有** | ❌ **没有** |
| 实测 WAN 吞吐 | **1238–1274 Mbps** | 未验证 |

**为什么 25.12 没有 PPE 加速**：

- `patches/` 的 `795-11` 改的是 `mtk_ppe_offload.c`，让 PPE 认得
  `DSA_TAG_PROTO_RTL8366UB_8021Q`（实测 **7 处**相关改动，含
  `mtk_flow_get_dsa_port()` 的 case 分支与 `mtk_flow_set_output_device()`）
- `patches-25.12/` 的 `795-11` 文件名叫
  `net-mediatek-use-native-dsa-special-tags`，内容只是**限制 MTK 原生特殊标签
  只对 MTK tagger 生效**，`mtk_ppe_offload.c` **一行未改**（实测 0 处）

25.12 的 tagger 会保留标准 EtherType 让 PPE 能解析帧头，但**没有向 PPE 注册
DSA 端口映射**，因此路由转发仍走 CPU。

**结论**：要硬件加速用 `master`；要 25.12 稳定线则接受无硬件加速。
`patches/0006`（统计修复）目前只对 `master` 有效，25.12 需单独生成。

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

> 已知改进点：master 版写的是 `proto == DSA_TAG_PROTO_MTK`（白名单），
> Beaverfffan 的实现写 `proto != DSA_TAG_PROTO_RTL8366UB_8021Q`（黑名单）。
> 后者不会连带改变 BE14000 所用 YT922x tagger 的 TX 路径，更严谨。
> 本仓库后续会向该写法对齐。

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

原配方会引入第三方 feed。本仓库**默认全部关闭**，目标是与官方 ImmortalWrt
同类型有线路由器保持一致的包集。

| 第三方源 | 原行为 | 本仓库默认 |
|---|---|---|
| `wukongdaily/luci-app-run` | **无条件追加** | ❌ 关闭（`enable_luci_app_run`，需手动开）|
| `linkease/istore` | `enable_store` 默认 `true` | ❌ 关闭（默认 `false`）|
| `linkease/nas-packages` | `enable_quickstart` | 原本就默认关 |
| `kenzok8/openwrt-daede` | `bake_daede` | 原本就默认关 |

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

### 刷完自己核对

登录 `192.168.5.1`（账号 `root`，密码见构建时 `root_password` 输入项），执行：

```bash
# 与官方同类型设备对比包数量
apk list --installed | wc -l

# 确认第三方包已绝迹（应无输出）
apk list --installed | grep -E "istore|luci-app-run|taskd|luci-lib-xterm|argon"
```

`patches/` 里没有任何新增软件包，纯内核驱动改动；`config/mt5000.seed`
只做减法。

---

## 本仓库相对原作者的全部改动

### 1. 配置精简（纯减法）

| 项 | 原因 |
|---|---|
| `wpad*` / `hostapd-common` / `wpa-supplicant` | MT5000 **无 Wi-Fi 射频**。这三个包在本机启动即失败（`ubus: Unable to resolve path for module 'common'`），白占约 **18 MB** RAM |
| `miniupnpd` / `luci-app-upnp` | 默认关闭，减少攻击面。需要 NAT-PMP 时在 LuCI 手动开 |
| `luci-app-store` / iStore / `taskd` / `luci-lib-*` | 第三方源，默认关闭 |
| `luci-app-run` | 第三方源，默认关闭 |
| `luci-theme-argon` | 第三方主题，默认用 bootstrap |

### 2. DSA 端口统计修复（`patches/0006`，仅 master）

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
不是 buildroot 树里的独立 `.c` 文件。所以 `0006` 编辑的是那个 pending patch，
并且必须同步两处嵌套行数声明：

```
内层  @@ -0,0 +1,993  @@                     → @@ -0,0 +1,1043 @@
外层  @@ -0,0 +1,3617 @@（在 0001 中）         → @@ -0,0 +1,3667 @@
```

两处数字均由真实 `git apply` 0001 后的结果推导，非人工计数。

### 3. 合规

补 GPL-2.0 [LICENSE](LICENSE) 与本文件的来源声明。

---

## 分支说明

| 分支 | 内容 | 用途 |
|---|---|---|
| **`master`** | **纯原作者代码**，与 `Kitsune2077/mt5000-immortalwrt` 保持一致 | 跟踪上游 |
| **`dev`** | 原作者代码 + 上述全部改动（配置精简、`patches/0006`、README、LICENSE）| 实际构建用 |

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
| `iwrt_profile` | `master` | `master`（6.18，**有 PPE 加速**）/ `25.12`（6.12，无加速）|
| `lan_ip` | `10.0.0.1` | 默认 LAN 地址 |
| `root_password` | `root` | 建议改掉 |
| `enable_store` | **`false`** | iStore（第三方源）|
| `enable_luci_app_run` | **`false`** | luci-app-run（第三方源）|
| `extra_packages` | 空 | 额外编入的官方包，空格分隔 |

4. 约 2.5–3.5 小时后，在 **Artifacts** 或 **Release** 下载
   `*glinet_gl-mt5000-squashfs-sysupgrade.bin`
5. 刷机：原厂固件升级页上传，或 SSH 内 `sysupgrade -n <image>`

---

## 已知问题

| 问题 | 影响 | 状态 |
|---|---|---|
| `rx_pp_recycle_ring_full` 计数高（约 0.009% 丢包）| 满速长传有极轻微损失 | MTK 平台特性，PPE 卸载也无法绕过 |
| `u-boot-env` 分区 CRC 报错 | 无（该分区为空）| 可忽略 |
| 以太网中断集中在 CPU0 | 高负载时单核受限 | 未解决，MTK 中断分发限制 |
| 无巨帧支持（MTU 上限 1500）| NAS/iSCSI 场景受限 | 未启用 |
| `get_stats64` 修复仅覆盖 `master` | 25.12 仍显示聚合值 | 待补 25.12 版 |

---

## 许可

构建配方、脚本与补丁以 **GPL-2.0** 发布，见 [LICENSE](LICENSE)。
固件产物因包含 Linux 内核及 GPL 组件，同样受 GPL-2.0 约束；
再分发时须随附对应源码——本仓库的 workflow 与 patch 即构成完整可复现路径。
