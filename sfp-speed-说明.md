# TP-Link TL-ER2260T SFP 速率手动指定 — 修改说明

## 概述

针对网口（SFP 光口）速率手动指定功能，共涉及 **3 处修改**，共同解决同一个核心问题：

> **TL-ER2260T 的 SFP 光口在自动协商模式下无法可靠建立/维持链路。**

三个修改分别承担「执行」「修复」「入口」三个角色，缺一不可：

| 角色 | 文件 | 作用 |
|------|------|------|
| 执行 | `sfp_link_speed` init 脚本 | 读取配置并把速率下发到 SerDes |
| 修复 | qca-ssdk 补丁 | 让下发的速率能被正确识别为 link up |
| 入口 | LuCI `tools/network.js` | 提供用户可操作的下拉框 |

---

## 背景：SFP 端口的双重速率体系

一个 SFP 口存在两层速率协商：

1. **模块侧（line side）**：光模块与对端设备之间，由光模块自己处理，固件不参与。
2. **主控侧（host side / SerDes）**：SoC 的 SerDes 与光模块之间，这个速率必须和模块能力**精确匹配**，否则物理层出不了稳定信号。

问题出在第 2 层。默认情况下 SSDK 按 `10GBASE-R` 驱动 SerDes，但插入 1G SFP 或 2.5G 模块时，主控侧仍跑 10G 会导致**链路起不来或频繁掉线**。自动协商在部分模块上不可靠（很多 SFP 模块不支持 host-side 速率协商），因此需要一个**手动指定**的开关。

---

## 修改 1：`sfp_link_speed` init 脚本（执行者）

**文件**：`target/linux/qualcommax/ipq807x/base-files/etc/init.d/sfp_link_speed`（新增）

这是核心逻辑，负责把用户在 UCI 配置里写的数值翻译成 SSDK 命令并下发到硬件。

### 关键设计点

- **`config_foreach sfp_speed_device_cb device`**：遍历 `/etc/config/network` 里所有 `device` section，读取每个的 `option sfp_speed`。配置直接写在标准 UCI 网络配置里，与 LuCI 界面天然对接。
- **速率映射**：
  - `1  → sgmii_fiber`（1G）
  - `2  → sgmii_plus`（2.5G / HSGMII）
  - `10 → 10gbase_r`（10G）
  
  这三个是 SSDK 里 SFP host-side 支持的实际 SerDes 模式名。
- **端口映射**：`lan5 → SSDK port 6`、`lan6 → SSDK port 5`。编号来自 DTS 里 `dp6_syn` / `dp5_syn` 的 `port_id`，是软件接口名到芯片物理端口的对应，不可写反。
- **两步下发**：先对每个端口 `ssdk_sh port interfaceMode set`（写入暂存寄存器），最后统一 `interfaceMode apply`（一次性生效）。因为 SSDK 的接口模式是批量提交的，逐端口 apply 会互相覆盖。
- **`board_name` 守卫**：`[ "$(board_name)" = "tplink,tl-er2260t" ] || return 0`，避免此脚本在别的机器上误执行、干扰其他设备端口。
- **`procd_add_reload_trigger network`**：在 LuCI 保存网络配置后，procd 自动重启该服务，改动即时生效，无需重启路由器。

---

## 修改 2：qca-ssdk 补丁（修复者）

**文件**：`package/kernel/qca-ssdk/patches/0013-sfp-ignore-missing-rx-los-gpio.patch`（新增）

这是最容易被忽略、但**不加就会出 bug** 的一处。

### 原理

`sfp_port_status_get_from_uniphy()` 是 SSDK 判断 SFP 口是否 link up 的函数，逻辑为：

1. 读 UNIPHY/PCS 的链路状态；
2. 再读 **RX_LOS（接收信号丢失）GPIO** 的状态；
3. 若 UNIPHY 显示 up 但 RX_LOS 为 1，判定为**假链路**（没有光信号），报 link down。

问题在于：**TL-ER2260T 的 SFP 口没有连接 RX_LOS GPIO**，`sfp_phy_rx_los_status_get()` 返回 `SW_NOT_SUPPORTED`。

原代码忽略了返回值，导致 `rx_los_status` 变量**未赋值就参与判断**（保留栈上垃圾值），结果是：物理链路明明通了，却因垃圾值被误判成「假链路」而报 down —— 速率设置成功了也会显示断开。

### 补丁内容

```c
rv = sfp_phy_rx_los_status_get(dev_id, port_id, &rx_los_status);
SSDK_DEBUG("port %d rx_los_status is %x (rv %d)\n", port_id, rx_los_status, rv);
/* No valid RX_LOS GPIO on this port: trust the PCS/UNIPHY
   link status instead of treating it as a fake link */
if (rv == SW_NOT_SUPPORTED)
    rx_los_status = A_FALSE;
```

当端口不存在 RX_LOS GPIO 时，把 `rx_los_status` 强制置 `A_FALSE`（= 无丢失信号），从而**完全信任 UNIPHY/PCS 的链路状态**，不再做假链路过滤。这样手动指定速率后，link 状态才能正确上报到内核和 LuCI。

---

## 修改 3：LuCI `tools/network.js`（入口）

**文件**：`feeds/luci/modules/luci-mod-network/htdocs/luci-static/resources/tools/network.js`（修改）

在设备**高级选项卡**中新增一个 `SFP link speed` 下拉框，用户可选 1G / 2.5G / 10G。

### 关键设计点

- **`o.depends('name_simple', 'lan5')` / `'lan6'`**：让选项**只在设备名为 lan5/lan6 时显示**，其他设备（VLAN 桥、bond 接口等）不会看到这个无关选项。`name_simple` 和 `name_complex` 覆盖普通命名与复杂命名两种情况。
- **`form.ListValue` 而非 `form.RadioButton`**：该版本 LuCI 不存在 `form.RadioButton` 类（会报 `Class must be a descendant of CBIAbstractValue`），改用 `form.ListValue` 渲染为下拉框。
- **`o.rmempty = true`**：留空时**不写入** `option sfp_speed`，脚本里的 `case *) return 0` 会跳过，保持默认 10G 行为 —— 不显式配置就不会改变原有表现。

---

## 协同闭环

```
LuCI 下拉框 (network.js)
      │  写入 option sfp_speed = '1'/'2'/'10'
      ▼
UCI /etc/config/network
      │  procd reload trigger
      ▼
sfp_link_speed 脚本 ──► ssdk_sh interfaceMode set/apply ──► SerDes 切换到指定速率
                                                        │
                                                        ▼
qca-ssdk 补丁 ──► 无 RX_LOS GPIO 时正确上报 link 状态 ──► 内核/LuCI 显示正确链路
```

三者缺一不可：**脚本**负责执行、**补丁**保证执行结果能被正确识别、**LuCI** 让用户能操作。

---

## 使用方法（用户视角）

1. 进入 LuCI → 网络 → 接口，编辑 lan5（SFP1）或 lan6（SFP2）设备；
2. 在「高级设置」中找到「SFP link speed」，选择与光模块匹配的速率；
3. 保存并应用，链路会立即按指定速率重建，无需重启。

---

## 附录：完整 patch

```patch
diff --git a/package/kernel/qca-ssdk/patches/0013-sfp-ignore-missing-rx-los-gpio.patch b/package/kernel/qca-ssdk/patches/0013-sfp-ignore-missing-rx-los-gpio.patch
new file mode 100644
index 0000000000..18ce46843c
--- /dev/null
+++ b/package/kernel/qca-ssdk/patches/0013-sfp-ignore-missing-rx-los-gpio.patch
@@ -0,0 +1,17 @@
+--- a/src/hsl/phy/sfp_phy.c
++++ b/src/hsl/phy/sfp_phy.c
+@@ -123,8 +123,12 @@ sfp_port_status_get_from_uniphy(a_uint32_t dev_id, a_uint32_t port_id,
+ 		{
+ 			case PORT_SGMII_PLUS:
+ 			case PORT_10GBASE_R:
+-				sfp_phy_rx_los_status_get(dev_id, port_id, &rx_los_status);
+-				SSDK_DEBUG("port %d rx_los_status is %x\n", port_id, rx_los_status);
++				rv = sfp_phy_rx_los_status_get(dev_id, port_id, &rx_los_status);
++				SSDK_DEBUG("port %d rx_los_status is %x (rv %d)\n", port_id, rx_los_status, rv);
++				/*No valid RX_LOS GPIO on this port: trust the PCS/UNIPHY
++				link status instead of treating it as a fake link*/
++				if (rv == SW_NOT_SUPPORTED)
++					rx_los_status = A_FALSE;
+ 				/*if uniphy is link up and rx los is 0, then link up,
+ 				if uniphy is link up but rx los is 1, this is fake link*/
+ 				if(rx_los_status)

diff --git a/target/linux/qualcommax/ipq807x/base-files/etc/init.d/sfp_link_speed b/target/linux/qualcommax/ipq807x/base-files/etc/init.d/sfp_link_speed
new file mode 100755
index 0000000000..1dca472102
--- /dev/null
+++ b/target/linux/qualcommax/ipq807x/base-files/etc/init.d/sfp_link_speed
@@ -0,0 +1,69 @@
+#!/bin/sh /etc/rc.common
+
+START=15
+STOP=90
+
+USE_PROCD=1
+
+# SFP 接口名与 SSDK 端口号的对应关系（来自 DTS 的 port_id）。
+# lan5 = dp6_syn = SSDK port 6
+# lan6 = dp5_syn = SSDK port 5
+sfp_speed_device_cb() {
+	local name speed mode port
+
+	config_get name "$1" name
+	[ -n "$name" ] || name="$1"
+	[ -n "$name" ] || return 0
+
+	config_get speed "$1" sfp_speed
+	case "$speed" in
+	1) mode="sgmii_fiber" ;;
+	2) mode="sgmii_plus" ;;
+	10) mode="10gbase_r" ;;
+	*) return 0 ;;
+	esac
+
+	case "$name" in
+	lan5) port=6 ;;
+	lan6) port=5 ;;
+	*) return 0 ;;
+	esac
+
+	sfp_commands="$sfp_commands\n$name $port $mode"
+}
+
+start_service() {
+	[ "$(board_name)" = "tplink,tl-er2260t" ] || return 0
+
+	sfp_commands=""
+	config_load network
+	config_foreach sfp_speed_device_cb device
+
+	[ -n "$sfp_commands" ] || return 0
+
+	local ifname port mode applied=0
+
+	while read -r ifname port mode; do
+		[ -n "$ifname" ] || continue
+		if ssdk_sh port interfaceMode set "$port" "$mode" 2>/dev/null; then
+			logger -t "SFP Speed" "Set $ifname (SSDK port $port) to $mode."
+			applied=1
+		else
+			logger -t "SFP Speed" "Failed to set $ifname (SSDK port $port) to $mode."
+		fi
+	done <<EOF
+$(printf '%b' "$sfp_commands")
+EOF
+
+	[ "$applied" -eq 1 ] || return 0
+
+	if ssdk_sh port interfaceMode apply 2>/dev/null; then
+		logger -t "SFP Speed" "Interface mode applied."
+	else
+		logger -t "SFP Speed" "Failed to apply interface mode."
+	fi
+}
+
+service_triggers() {
+	procd_add_reload_trigger network
+}

diff --git a/feeds/luci/modules/luci-mod-network/htdocs/luci-static/resources/tools/network.js b/feeds/luci/modules/luci-mod-network/htdocs/luci-static/resources/tools/network.js
index c96e268..7957aaa 100644
--- a/feeds/luci/modules/luci-mod-network/htdocs/luci-static/resources/tools/network.js
+++ b/feeds/luci/modules/luci-mod-network/htdocs/luci-static/resources/tools/network.js
@@ -577,6 +577,17 @@ return baseclass.extend({
 		o.depends('type', '8021q');
 		o.depends('type', '8021ad');
 
+		o = this.replaceOption(s, 'devadvanced', form.ListValue, 'sfp_speed', _('SFP link speed'),
+			_('Force the SFP host-side SerDes mode. This is only effective on devices with an SFP port (e.g. TP-Link TL-ER2260T). Leaving it unset keeps the default 10GBASE-R mode.'));
+		o.value('1', _('1 Gbps (SGMII)'));
+		o.value('2', _('2.5 Gbps (SGMII+ / HSGMII)'));
+		o.value('10', _('10 Gbps (10GBASE-R)'));
+		o.rmempty = true;
+		o.depends('name_simple', 'lan5');
+		o.depends('name_simple', 'lan6');
+		o.depends('name_complex', 'lan5');
+		o.depends('name_complex', 'lan6');
+
 		o = this.replaceOption(s, 'devgeneral', widgets.DeviceSelect, 'ifname_multi-bond', _('Aggregation ports'));
 		o.size = 10;
 		o.rmempty = true;
```
