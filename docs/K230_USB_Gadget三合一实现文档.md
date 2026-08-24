# K230 USB Gadget 三合一实现文档

## CDC ACM 串口 + RNDIS 虚拟网卡 + UMS U 盘

---

## 1. 架构概述

K230 通过 **USB Composite Gadget** 方案，在单个 UDC 上同时提供三种功能：

| 功能 | 内核模块 | 设备节点 | PC 端表现 |
|------|----------|----------|-----------|
| CDC ACM 串口 | `usb_f_acm` | `/dev/ttyGS0`（板端） | COM 口 / `/dev/ttyACM0` |
| RNDIS 虚拟网卡 | `usb_f_rndis` | `usb0`（板端） | 以太网适配器（自动获取 IP） |
| UMS 大容量存储 | `usb_f_mass_storage` | LUN `lun.0` | 可移动 U 盘 |

### 为什么用组合 Gadget

K230 只有一个 UDC 控制器（`91500000.usb` / `91540000.usb`），**一个 UDC 只能绑定一个 gadget**。  
旧方案使用两个独立 gadget 互斥切换，导致切换时串口断线、UDC 解绑/绑定路径多坑。  
组合 gadget 方案让三个功能在同一 gadget 下永久共存，PC 端即插即用。

### 端点资源约束

K230 dwc2 控制器 DTS 配置 `g-tx-fifo-size = <166x10>`（10 个 TX FIFO = 10 个 IN 端点）：

| 功能 | IN 端点需求 |
|------|-------------|
| ACM | 1（interrupt） |
| MSC | 1（bulk） |
| RNDIS | 2（interrupt + bulk） |
| **合计** | **4 个 IN ep** |

当前 4 个 IN ep 在 10 个 FIFO 限制内，余量充足。

> **注意**：若改用 NCM 协议，NCM 需要 2 个 IN ep（interrupt + bulk），总计仍为 4 个 IN ep。  
> 但 NCM 在 Windows 10 上存在 Code 10 兼容问题，因此选用 RNDIS。

---

## 2. 内核配置

文件：`buildroot-overlay/board/canaan/k230-soc/linux.fragment`

```kconfig
CONFIG_CONFIGFS_FS=y              # configfs 文件系统
CONFIG_USB_CONFIGFS=y             # USB configfs gadget 框架
CONFIG_USB_LIBCOMPOSITE=y         # gadget composite 库
CONFIG_USB_F_ACM=y                # CDC ACM 串口功能
CONFIG_USB_F_RNDIS=y              # RNDIS 网卡功能
CONFIG_USB_F_MASS_STORAGE=y       # 大容量存储功能
CONFIG_USB_CONFIGFS_ACM=y         # configfs ACM 接口
CONFIG_USB_CONFIGFS_RNDIS=y       # configfs RNDIS 接口
CONFIG_USB_CONFIGFS_MASS_STORAGE=y # configfs Mass Storage 接口
CONFIG_USB_CONFIGFS_F_FS=y        # FunctionFS（备用）
CONFIG_USB_USBNET=y               # USB 网络设备支持
```

所有 USB gadget 功能模块均编入内核（`=y`），确保开机即可用，无需等待模块加载。

---

## 3. 设备树配置

以 labplus 板型为例（`k230_canmv_labplus_1956.dts`）：

```dts
&usbotg1 {
    status = "okay";
};
```

DTS 中 dwc2 控制器定义（`k230.dtsi`）：

```dts
usbotg1: usb-otg@91540000 {
    compatible = "snps,dwc2";
    reg = <0x0 0x91540000 0x0 0x40000>;
    g-tx-fifo-size = <166 166 166 166 166 166 166 166 166 166>;
    dr_mode = "otg";
    status = "disabled";  /* 各板型 dts 中 enable */
};
```

---

## 4. 文件清单

| 文件路径 | 作用 |
|----------|------|
| `rootfs_overlay/bin/cdc_serial.sh` | 主脚本：创建/销毁组合 gadget，管理网络 |
| `rootfs_overlay/bin/ums.sh` | U 盘脚本：挂载/卸载 data 分区到 LUN |
| `rootfs_overlay/etc/init.d/S98usbserial` | 开机启动脚本，调用 `cdc_serial.sh start` |
| `rootfs_overlay/etc/init.d/S02data` | data 分区管理，默认不挂载（留给 U 盘导出） |
| `rootfs_overlay/etc/udhcpd-usb.conf` | RNDIS DHCP 配置 |
| `rootfs_overlay/etc/ssh/sshd_config` | SSH 配置（允许 root 空密码登录） |
| `board/canaan/k230-soc/linux.fragment` | 内核 fragment，启用 gadget 模块 |
| `board/canaan/k230-soc/post-build.sh` | 构建后处理，注册 ttyGS0 到 inittab |

---

## 5. 核心脚本详解

### 5.1 cdc_serial.sh — 组合 Gadget 主控脚本

**职责**：通过 configfs 创建完整的 USB 复合设备，管理 RNDIS 网络和 DHCP。

#### 执行流程

```
start
 ├─ mount_configfs()          # 挂载 configfs
 ├─ wait_for_udc()            # 等待 dwc2 UDC 就绪（最多 20 秒）
 ├─ destroy_gadget()          # 清理残留旧 gadget
 ├─ create_gadget()           # 创建完整 gadget（见下文）
 ├─ ums.sh start              # 尝试挂载 data 分区到 LUN
 ├─ write_attr "$udc" UDC     # 绑定 UDC，设备枚举开始
 ├─ export_data_later &       # 后台：等 LUN 就绪后插入介质
 └─ net_up &                  # 后台：等 usb0 出现 → 配 IP → 起 DHCP
```

#### create_gadget() 关键配置

```bash
# USB 描述符
idVendor     = 0x0525    # Linux Foundation 通用 VID
idProduct    = 0xa4a8    # 自定义 PID
bcdUSB       = 0x0200    # USB 2.0
bDeviceClass = 0xef      # Miscellaneous（复合设备必须）
bDeviceSubClass = 0x02   # IAD
bDeviceProtocol = 0x01   # IAD

# 三个功能
functions/rndis.usb0        # RNDIS 网卡
functions/acm.GS0           # CDC ACM 串口
functions/mass_storage.data # 大容量存储

# RNDIS 特定配置
dev_addr    = 02:11:22:33:44:10  # 板端 MAC
host_addr   = 02:11:22:33:44:11  # PC 端 MAC
qmult       = 5                  # 队列乘数
os_desc     = RNDIS compatible_id # Windows RNDIS 兼容描述符

# Mass Storage 配置
stall       = 1
lun.0/removable = 1    # 可插拔介质语义
lun.0/cdrom     = 0
lun.0/ro        = 0
```

#### 网络配置（net_up）

```bash
# 等待 usb0 网络接口出现（最多 20 秒）
ifconfig usb0 10.0.10.1 netmask 255.255.255.0 up

# 关闭硬件卸载（RNDIS 兼容性）
ethtool -K usb0 rx off tx off
ethtool -K usb0 sg off tso off gso off gro off

# 启动 DHCP 服务
udhcpd /etc/udhcpd-usb.conf
```

#### 自愈设计

脚本在 `start` 时先 `destroy_gadget` 清理残留，再重新创建。  
如果 gadget 已存在且 UDC 已绑定，直接返回，不会重复创建。  
后台线程 `export_data_later` 最多重试 30 秒等待 LUN 就绪。

### 5.2 ums.sh — U 盘介质管理

**职责**：将 SD 卡的 `K230_DATA` 分区（第 3 分区）导出为 USB U 盘。

#### 核心机制

利用内核 `f_mass_storage` 的**可插拔介质语义**：

```bash
# 导出（插入介质）：将块设备路径写入 LUN file 节点
echo /dev/mmcblk0p3 > /sys/kernel/config/usb_gadget/k230usb/functions/mass_storage.data/lun.0/file

# 取消导出（弹出介质）：写入空字符串
echo "" > /sys/kernel/config/usb_gadget/k230usb/functions/mass_storage.data/lun.0/file
```

> **关键**：写空字符串解绑介质，**不需要解绑 UDC**。这保证了 U 盘插拔时串口和网卡不断。

#### 安全约束

- 导出前必须先 `umount /data`（板上不能同时挂载和导出同一分区）
- 导出后 PC 端独占访问，板上不可读写
- 取消导出后自动 `mount /data` 恢复板上访问

#### 数据分区查找逻辑

```
1. 按 LABEL="K230_DATA" 搜索 /dev/mmcblk*p3
2. 从 /proc/cmdline 的 root= 参数推断同设备的 p3
3. 兜底：取第一个找到的 /dev/mmcblk*p3
```

### 5.3 udhcpd-usb.conf — DHCP 配置

```
interface usb0          # 仅在 usb0 接口上提供 DHCP
start 10.0.10.100       # 分配池起始
end 10.0.10.200         # 分配池结束
max_leases 10           # 最多 10 个客户端
opt subnet 255.255.255.0
opt router 10.0.10.1    # 网关指向板子
opt lease 86400         # 租约 24 小时
```

---

## 6. 开机启动流程

```
内核启动
 │
 ├─ S02data start
 │   └─ data 分区不挂载（默认留给 U 盘导出）
 │
 ├─ S50sshd start
 │   └─ sshd 启动（PermitRootLogin yes, PermitEmptyPasswords yes）
 │
 ├─ S98usbserial start
 │   └─ cdc_serial.sh start &（后台异步执行）
 │       ├─ 挂载 configfs
 │       ├─ 等待 UDC 就绪
 │       ├─ 创建 gadget（ACM + RNDIS + MSC）
 │       ├─ ums.sh start → 导出 data 分区到 LUN
 │       ├─ 绑定 UDC → PC 开始枚举
 │       ├─ 后台：等 LUN 就绪后确认介质插入
 │       └─ 后台：等 usb0 出现 → 配 IP → 起 udhcpd
 │
 └─ post-build.sh 注册的 ttyGS0
     └─ inittab 中添加 getty，串口登录终端可用
```

PC 端插入 USB 后，操作系统依次识别：
1. **USB Composite Device**（VID=0x0525, PID=0xa4a8）
2. **CDC ACM** → 串口（Windows: COMx, Linux: /dev/ttyACM0）
3. **RNDIS** → 以太网适配器（自动 DHCP 获取 10.0.10.x）
4. **Mass Storage** → 可移动磁盘（K230_DATA 分区）

---

## 7. 网络与 SSH 访问

### IP 规划

| 设备 | IP | 获取方式 |
|------|-----|----------|
| 板端 usb0 | 10.0.10.1/24 | 静态配置 |
| PC 端 | 10.0.10.100~200 | DHCP 自动获取 |

### SSH 登录

```bash
ssh root@10.0.10.1
# 密码为空，直接回车
```

sshd 配置要点（`/etc/ssh/sshd_config`）：

```
PermitRootLogin yes
PermitEmptyPasswords yes
```

### 文件传输

```bash
# 从 PC 传文件到板端
scp local_file root@10.0.10.1:/root/

# 从板端传文件到 PC
scp root@10.0.10.1:/root/remote_file ./
```

> **优势**：通过 scp 传文件不占用 U 盘通道，U 盘可同时被 PC 访问。  
> 解决了旧方案中"PC 独占 U 盘时板端无法传文件"的冲突。

---

## 8. 运行模式切换

### 默认模式：USB 导出（data_mode=usb）

- 开机后 data 分区自动导出为 U 盘
- 板上不可访问 /data
- PC 端可直接读写 U 盘

### 板上使用模式

在板端执行：

```bash
# 取消 U 盘导出，恢复板上挂载
/bin/ums.sh stop

# 此时 /data 自动挂载，板上可读写
ls /data
```

恢复导出：

```bash
# 重新导出为 U 盘
/bin/ums.sh start
```

### 查看状态

```bash
/bin/ums.sh status
# 输出示例：
# media: /dev/mmcblk0p3
# gadget: UDC=91540000.usb
# data: exported or unmounted
```

---

## 9. 跨系统兼容性

### RNDIS 协议选择理由

| 协议 | Windows | Linux | macOS | 备注 |
|------|---------|-------|-------|------|
| **RNDIS**（当前方案） | Win7~11 全兼容 | 原生支持 | 10.15+ 已弃用 | 嵌入式首选 |
| NCM | Win10 1809+ (Code 10 风险) | 原生支持 | 原生支持 | Win10 挑驱动 |
| ECM | 无原生驱动 | 原生支持 | 原生支持 | Windows 需额外驱动 |

**选择 RNDIS 的原因**：
- Windows 全版本（Win7~11）原生兼容，无需安装额外驱动
- NCM 在 Windows 10 上存在 `usbncm.sys` Code 10 启动失败问题
- macOS 用户极少，且可通过有线网口或 SSH over IPv6 替代

### Windows 端表现

插入 USB 后，Windows 设备管理器中依次出现：
- **端口 (COM & LPT)** → USB Serial Device (COMx)
- **网络适配器** → Remote NDIS Compatible Device
- **磁盘驱动器** → USB Mass Storage Device

---

## 10. 常见问题

### Q: PC 端看不到 U 盘

检查 LUN 是否成功插入介质：

```bash
cat /sys/kernel/config/usb_gadget/k230usb/functions/mass_storage.data/lun.0/file
# 应输出 /dev/mmcblk0p3，若为空则介质未插入
```

手动重试：

```bash
/bin/ums.sh start
```

### Q: RNDIS 网卡未出现

```bash
# 检查 usb0 接口
ifconfig usb0
# 应显示 10.0.10.1

# 检查 DHCP 服务
ps | grep udhcpd
```

### Q: 串口 ttyGS0 无响应

```bash
# 检查 ACM 功能是否存在
ls /sys/kernel/config/usb_gadget/k230usb/functions/acm.GS0/

# 检查 UDC 绑定
cat /sys/kernel/config/usb_gadget/k230usb/UDC
# 应输出 91540000.usb（或 91500000.usb）
```

### Q: 重启 gadget

```bash
/bin/cdc_serial.sh restart
```

---

## 11. 构建与烧录

```bash
# 修改脚本后重新构建 rootfs
make

# 或仅重建内核（修改了 linux.fragment）
make linux-rebuild && make

# 烧录生成的镜像
# 镜像路径：output/images/sysimage-sdcard.img
```

脚本文件位于 rootfs overlay 中，Buildroot 会在构建时自动复制到 rootfs 对应路径。
