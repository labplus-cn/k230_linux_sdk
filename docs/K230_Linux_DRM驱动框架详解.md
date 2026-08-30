# K230 Linux DRM 驱动框架详解

## 1. 概述

K230 系列芯片的显示子系统基于 Linux DRM（Direct Rendering Manager）框架实现，采用 **Component 组件模型** 将 VO（Video Output）控制器和 MIPI DSI 控制器组合为统一的 DRM 设备。

驱动覆盖三个层次：

| 层次 | 位置 | 说明 |
| --- | --- | --- |
| 内核 DRM 驱动 | `drivers/gpu/drm/canaan/` | 硬件抽象，提供 `/dev/dri/card0` |
| 用户空间 libdrm 封装 | `buildroot-overlay/package/display/` | 高级 C API 封装库 |
| 应用集成层 | `package/vvcam/v4l2-drm/`、`package/display/` | 摄像头-显示流水线 |

---

## 2. 硬件架构

### 2.1 显示子系统框图

```
┌─────────────────────────────────────────────────────────────┐
│                     K230 SoC                                │
│                                                             │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐              │
│  │  Layer1   │    │  Layer2   │    │  Layer3   │  YUV视频层  │
│  │ (NV12)   │    │ (NV12)   │    │ (NV12)   │              │
│  └────┬─────┘    └────┬─────┘    └────┬─────┘              │
│       │               │               │                     │
│  ┌────┴─────┐    ┌────┴─────┐    ┌────┴─────┐              │
│  │  OSD0~2  │    │  OSD3~7  │    │  混合器   │  OSD/图形层  │
│  │ (ARGB)   │    │ (ARGB)   │    │ (Blender) │              │
│  └────┬─────┘    └────┬─────┘    └────┬─────┘              │
│       │               │               │                     │
│       └───────────────┼───────────────┘                     │
│                       ▼                                     │
│              ┌────────────────┐                             │
│              │  VO 控制器      │  基址: 0x90840000           │
│              │  (Video Output) │  时序生成 + 图层合成         │
│              └───────┬────────┘                             │
│                      │ RGB 像素流                            │
│                      ▼                                      │
│              ┌────────────────┐                             │
│              │  DWC MIPI DSI  │  基址: 0x90850000           │
│              │  Host 控制器   │  DesignWare IP              │
│              └───────┬────────┘                             │
│                      │                                      │
│              ┌────────────────┐                             │
│              │  MIPI D-PHY   │  基址: 0x90850400            │
│              │  (TX PHY)     │  可配 2/4 lane              │
│              └───────┬────────┘                             │
└──────────────────────┼──────────────────────────────────────┘
                       │ MIPI DSI 差分信号
                       ▼
              ┌────────────────┐
              │   LCD Panel    │
              │  (ST7701等)    │
              └────────────────┘
```

### 2.2 硬件资源

| 模块 | 寄存器基址 | 说明 |
| --- | --- | --- |
| VO 控制器 | `0x90840000` | 图层管理、时序、混合、DMA |
| DSI Host | `0x90850000` | Synopsys DWC MIPI DSI 控制器 |
| D-PHY | `0x90850400` | MIPI D-PHY TX |
| 时钟控制 | `0x91108000` | 像素时钟分频 |

### 2.3 VO 图层结构

VO 控制器支持 **7 个图层**（plane），分为两类：

| 图层 | 类型 | 格式 | 用途 |
| --- | --- | --- | --- |
| Layer1 ~ Layer3 | 视频层 | NV12 / NV21 (YUV420) | 摄像头预览、视频播放 |
| OSD0 ~ OSD2 | 图形层 | ARGB8888 / RGB565 | UI 叠加、OSD 字符 |
| OSD3 ~ OSD7 | 扩展图形层 | ARGB8888 | 额外 UI 叠加 |

每个图层支持：
- 双缓冲地址切换（ADDR0/ADDR1 + ADDR_SEL）
- 独立 stride、偏移、尺寸配置
- 位置控制（XCTL/YCTL 寄存器）
- Layer1~3 支持硬件旋转（0°/90°/180°/270°）

---

## 3. 内核 DRM 驱动详解

### 3.1 源码结构

内核驱动位于 `drivers/gpu/drm/canaan/`：

```
drivers/gpu/drm/canaan/
├── Kconfig              # 构建配置
├── Makefile             # 编译规则
├── canaan_drv.c         # DRM 设备注册、Component 框架、GEM/Dumb Buffer 管理
├── canaan_drv.h         # 导出 VO 和 DSI 驱动声明
├── canaan_vo.c          # VO 控制器：CRTC/Plane 的硬件操作实现
├── canaan_vo.h          # VO 接口声明
├── canaan_vo_regs.h     # VO 寄存器定义（偏移地址）
├── canaan_vo_table.h    # VO 查找表（时序参数等）
├── canaan_crtc.c        # CRTC 抽象层（Atomic 模式控制）
├── canaan_crtc.h        # CRTC 结构体定义
├── canaan_plane.c       # Plane 抽象层（图层原子操作）
├── canaan_plane.h       # Plane 结构体与配置定义
├── canaan_dsi.c         # MIPI DSI 控制器（Encoder + Connector）
├── canaan_dsi.h         # DSI 结构体定义
├── canaan_phy.c         # MIPI D-PHY 配置
```

### 3.2 驱动特性标志

```c
// canaan_drv.c
static struct drm_driver canaan_drm_driver = {
    .driver_features = DRIVER_GEM | DRIVER_MODESET | DRIVER_ATOMIC,
    .dumb_create = canaan_drm_dumb_create,
    .gem_prime_import_sg_table = drm_gem_dma_prime_import_sg_table_vmap,
    .fops = &canaan_drm_fops,
    .name = "canaan-drm",
    .desc = "Canaan K230 DRM driver",
};
```

- **DRIVER_GEM**：支持 GEM（Graphics Execution Manager）内存管理
- **DRIVER_MODESET**：支持 KMS 模式设置
- **DRIVER_ATOMIC**：支持 Atomic 模式设置（推荐的现代 API）

### 3.3 Component 组件模型

K230 DRM 驱动使用 Linux Component 框架将 VO 和 DSI 两个独立 platform driver 组合：

```
canaan_drm_init()
  ├── platform_register_drivers({canaan_vo_driver, canaan_dsi_driver})
  │     ├── canaan_vo_driver.probe()  → 注册为 component
  │     └── canaan_dsi_driver.probe() → 注册为 component
  └── platform_driver_register(&canaan_drm_platform_driver)
        └── canaan_drm_platform_probe()
              └── component_master_add_with_match()
                    └── canaan_drm_bind()         ← 所有组件就绪后调用
                          ├── drm_dev_alloc()
                          ├── drm_mode_config_init()
                          ├── component_bind_all()  ← 调用 VO/DSI 的 bind
                          ├── drm_vblank_init()
                          ├── drm_dev_register()    ← 创建 /dev/dri/card0
                          └── drm_fbdev_generic_setup()
```

DTS 匹配条件：`compatible = "canaan,display-subsystem"`

### 3.4 CRTC 实现

CRTC 代表显示控制器/时序引擎，负责将像素数据按正确的时序输出。

```c
// canaan_crtc.c
static const struct drm_crtc_helper_funcs canaan_crtc_helper_funcs = {
    .atomic_enable  = canaan_crtc_atomic_enable,   // 使能 CRTC + 配置时序
    .atomic_disable = canaan_crtc_atomic_disable,   // 关闭 CRTC
    .atomic_flush   = canaan_crtc_atomic_flush,     // 提交配置到硬件
};
```

关键流程：
- **atomic_enable**：调用 `canaan_vo_enable_crtc()` 配置 VO 时序寄存器（HSYNC/VSYNC/总尺寸），启动 vblank 计数
- **atomic_flush**：调用 `canaan_vo_flush_config()` 将软件配置写入硬件（REG_LOAD），并 arm vblank 事件
- **atomic_disable**：关闭 vblank，停止 CRTC，发送 flip 事件

CRTC 还支持 Gamma 校正（256 级）和颜色管理。

### 3.5 Plane 实现

每个 Plane 代表一个可独立配置的图层。

```c
// canaan_plane.c
static const struct drm_plane_helper_funcs canaan_plane_helper_funcs = {
    .atomic_check   = canaan_plane_atomic_check,    // 验证配置合法性
    .atomic_update  = canaan_plane_atomic_update,   // 更新图层参数
    .atomic_disable = canaan_plane_atomic_disable,  // 关闭图层
};
```

Plane 配置结构体：

```c
struct canaan_plane_config {
    char *name;                    // 图层名称
    uint32_t id;                   // 图层 ID
    uint32_t supported_rotations;  // 支持的旋转角度
    uint32_t possible_crtcs;       // 可绑定的 CRTC 掩码
    uint32_t num_formats;          // 支持的像素格式数量
    const uint32_t *formats;       // 像素格式数组（FourCC）
    enum drm_plane_type plane_type; // PRIMARY / OVERLAY / CURSOR
    uint32_t plane_offset;         // 寄存器基址偏移
    uint32_t plane_enable_bit;     // 使能位
    uint32_t xctl_reg_offset;      // X 位置控制寄存器偏移
    uint32_t yctl_reg_offset;      // Y 位置控制寄存器偏移
};
```

支持硬件旋转属性：

```c
if (config->supported_rotations) {
    drm_plane_create_rotation_property(&plane->base, DRM_MODE_ROTATE_0,
        DRM_MODE_ROTATE_0 | config->supported_rotations);
}
```

### 3.6 DSI Connector/Encoder

DSI 控制器同时充当 DRM Encoder 和 Connector：

```c
struct canaan_dsi {
    struct drm_connector connector;  // 连接器（面板接口）
    struct drm_encoder encoder;      // 编码器（RGB→DSI 转换）
    struct mipi_dsi_host host;       // DSI 主机

    struct clk *bus_clk;            // 总线时钟
    struct clk *mod_clk;            // 模块时钟
    struct phy *dphy;               // D-PHY
    struct drm_panel *panel;        // 面板驱动
    struct drm_bridge *bridge;      // 桥接器（可选）
    void __iomem *base;             // 寄存器基址
};
```

### 3.7 GEM 内存管理

K230 使用 DMA 一致性分配（`dma_alloc_coherent`）创建 GEM 对象：

```c
// canaan_drv.c
static struct drm_gem_dma_object *canaan_drm_gem_dma_create(struct drm_device *drm, size_t size)
{
    dma_obj->vaddr = dma_alloc_coherent(drm->dev, size,
                                         &dma_obj->dma_addr,
                                         GFP_KERNEL | __GFP_NOWARN);
    return dma_obj;
}
```

Dumb Buffer 创建流程：

```
用户空间 ioctl(DRM_IOCTL_MODE_CREATE_DUMB)
  → canaan_drm_dumb_create()
    → canaan_drm_gem_dma_create()     // DMA 一致性分配
    → drm_gem_handle_create()          // 创建用户空间 handle
```

mode_config 限制：
- 最小分辨率：16×16
- 最大分辨率：4096×4096

---

## 4. 用户空间 DRM 封装库

### 4.1 display 库

位于 `buildroot-overlay/package/display/`，提供高级 C API 封装 libdrm。

核心数据结构：

```c
struct display {
    int fd;                              // /dev/dri/card0 文件描述符
    uint32_t conn_id, enc_id, crtc_id;   // DRM 对象 ID
    drmModeModeInfo mode;                // 当前显示模式
    drmModeAtomicReqPtr req;             // Atomic 请求
    enum drm_rotation drm_rotation;      // 旋转设置
    struct display_plane* planes;        // Plane 链表
};

struct display_plane {
    struct display* display;
    drmModePlanePtr plane;
    uint32_t plane_id;
    unsigned int fourcc;                 // 像素格式
    struct display_buffer* buffers;      // Buffer 链表
};

struct display_buffer {
    uint32_t handle;                     // GEM handle
    uint32_t stride;                     // 行字节数
    int dmabuf_fd;                       // DMA-BUF fd（可共享）
    uint32_t id;                         // Framebuffer ID
    void* map;                           // mmap 映射地址
};
```

### 4.2 典型使用流程

```c
// 1. 初始化显示
struct display* display = display_init(0);  // 打开 /dev/dri/card0

// 2. 获取 Plane（指定像素格式）
struct display_plane* plane = display_get_plane(display, DRM_FORMAT_NV12);

// 3. 分配帧缓冲
struct display_buffer* buffer = display_allocate_buffer(plane, width, height);

// 4. 绘制内容到 buffer->map

// 5. 提交显示
display_commit_buffer(buffer, x, y);  // 设置 Plane 属性并提交
// 或
display_update_buffer(buffer, x, y);  // 仅更新属性
display_commit(display);              // 统一提交

// 6. 等待 vsync
display_wait_vsync(display);

// 7. 清理
display_free_buffer(buffer);
display_free_plane(plane);
display_exit(display);
```

### 4.3 Atomic Commit 详解

首次提交（Modeset）需要额外设置 Connector 和 CRTC 属性：

```c
if (plane->first) {
    // Connector: 绑定 CRTC
    drm_add_conn_property(display, req, "CRTC_ID", display->crtc_id);
    // CRTC: 设置显示模式并激活
    drm_add_crtc_property(display, req, "MODE_ID", display->blob_id);
    drm_add_crtc_property(display, req, "ACTIVE", 1);
    flags |= DRM_MODE_ATOMIC_ALLOW_MODESET;
    plane->first = false;
}
// Plane: 设置帧缓冲和位置
drm_add_plane_property(plane, req, "FB_ID", buffer->id);
drm_add_plane_property(plane, req, "CRTC_ID", display->crtc_id);
drm_add_plane_property(plane, req, "SRC_X", 0);      // 源区域（16.16 定点）
drm_add_plane_property(plane, req, "SRC_Y", 0);
drm_add_plane_property(plane, req, "SRC_W", width << 16);
drm_add_plane_property(plane, req, "SRC_H", height << 16);
drm_add_plane_property(plane, req, "CRTC_X", x);      // 屏幕位置
drm_add_plane_property(plane, req, "CRTC_Y", y);
drm_add_plane_property(plane, req, "CRTC_W", width);
drm_add_plane_property(plane, req, "CRTC_H", height);
// 旋转（如果 Plane 支持）
if (plane_has_property(plane, "rotation"))
    drm_add_plane_property(plane, req, "rotation", DRM_MODE_ROTATE_90);
```

### 4.4 支持的像素格式

| FourCC | 位深 | 说明 |
| --- | --- | --- |
| `DRM_FORMAT_NV12` | 8+4 | YUV420 半平面，视频常用 |
| `DRM_FORMAT_NV21` | 8+4 | YUV420 半平面（UV 互换） |
| `DRM_FORMAT_RGB565` | 16 | RGB565 |
| `DRM_FORMAT_BGR565` | 16 | BGR565 |
| `DRM_FORMAT_RGB888` | 24 | RGB888 |
| `DRM_FORMAT_BGR888` | 24 | BGR888 |
| `DRM_FORMAT_ARGB8888` | 32 | ARGB8888，OSD 常用 |
| `DRM_FORMAT_ABGR8888` | 32 | ABGR8888 |
| `DRM_FORMAT_RGBA8888` | 32 | RGBA8888 |
| `DRM_FORMAT_BGRA8888` | 32 | BGRA8888 |

---

## 5. V4L2-DRM 视频采集显示集成

### 5.1 架构

`v4l2-drm` 模块将 V4L2 视频采集与 DRM 显示通过 **DMA-BUF** 零拷贝连接：

```
┌──────────────┐    DMA-BUF     ┌──────────────┐
│  V4L2 采集    │ ──────────────→ │  DRM 显示     │
│  /dev/videoX  │   共享 fd      │  /dev/dri/card0│
│  (摄像头)     │               │  (LCD 屏)     │
└──────────────┘               └──────────────┘
```

### 5.2 数据流

```c
struct v4l2_drm_context {
    int video_fd;                        // V4L2 fd
    struct display_plane* plane;         // DRM Plane
    struct display_buffer** display_buffers;  // DRM 帧缓冲
    struct v4l2_drm_video_buffer* buffers;    // V4L2 缓冲
};
```

工作流程：
1. `display_allocate_buffer()` 创建 DRM dumb buffer → 获取 `dmabuf_fd`
2. V4L2 `VIDIOC_REQBUFS` 使用 `V4L2_MEMORY_DMABUF` 模式导入 DRM buffer
3. V4L2 `VIDIOC_QBUF` 入队 → `VIDIOC_STREAMON` 开始采集
4. 摄像头数据直接写入 DRM buffer 的物理内存（零拷贝）
5. `display_commit_buffer()` 将 buffer 提交给 DRM 显示

---

## 6. Pipeline 框架

`pipeline.hpp` 提供了 C++ 的流水线抽象，支持 Source → Sink 的 DMA-BUF 数据流：

```
VideoCapture (V4L2 Source)
    │
    │ DMA-BUF export/import
    ▼
Display (DRM Sink)
    │
    │ Atomic Commit
    ▼
LCD Panel
```

关键类：
- **DMABuffer**：DMA-BUF 封装（fd + mmap 地址）
- **Endpoint**：抽象端点（支持 import/export buffer）
- **VideoCapture**：V4L2 采集端点
- **Display**：DRM 显示端点
- **Pipeline**：调度器，基于 `select()` 的事件驱动循环

`Pipeline::link()` 自动协商 buffer 归属：优先从 Sink（Display）导出 buffer 给 Source（VideoCapture）导入。

---

## 7. U-Boot 阶段的裸机显示

在 Linux 启动前，U-Boot 通过直接操作寄存器显示开机 Logo：

```
U-Boot 显示流程：
vo_init()
  ├── k230_set_pixclk()          // 配置像素时钟
  ├── dwc_mipi_phy_config()      // 配置 D-PHY
  ├── dwc_dsi_init()             // 初始化 DSI Host
  ├── kd_vo_set_timing()         // 设置 VO 时序
  ├── kd_vo_set_layer()          // 配置图层（格式/地址/尺寸）
  └── kd_vo_enable()             // 使能显示输出
```

U-Boot 直接写入的寄存器（部分）：

| 寄存器 | 偏移 | 功能 |
| --- | --- | --- |
| `VO_DISP_ENABLE` | `0x118` | 显示使能 |
| `VO_DISP_CTL` | `0x114` | 显示控制 |
| `VO_DISP_HSYNC_CTL` | `0x100` | 行同步时序 |
| `VO_DISP_VSYNC1_CTL` | `0x108` | 场同步时序 |
| `VO_DISP_TOTAL_SIZE` | `0x11C` | 总尺寸 |
| `VO_LAYER1_CTL` | Layer1 偏移+0x0 | Layer1 格式控制 |
| `VO_LAYER1_Y_ADDR0` | Layer1 偏移+0xC | Y 分量地址 |

---

## 8. 数据通路总结

### 8.1 完整显示数据路径

```
应用层写入像素 → GEM Dumb Buffer (DMA 一致性内存)
    → drmModeAddFB2() 注册为 Framebuffer
    → drmModeAtomicCommit() 提交 Atomic 请求
        → CRTC atomic_flush → VO REG_LOAD
        → Plane atomic_update → VO 图层寄存器配置
    → VO DMA 读取内存数据
    → VO 图层混合（Blender）
    → RGB 像素流输出
    → DSI Host 打包
    → D-PHY 串行输出
    → LCD Panel 显示
```

### 8.2 多图层叠加示例

```
┌──────────────────────────────────┐
│  OSD0 (ARGB8888) - UI 图标      │  z-order 最高
├──────────────────────────────────┤
│  Layer1 (NV12) - 摄像头预览      │  z-order 中间
├──────────────────────────────────┤
│  背景色 (Background Color)       │  z-order 最低
└──────────────────────────────────┘
```

---

## 9. 关键配置

### 9.1 内核配置

```
CONFIG_DRM_CANAAN=y          # Canaan DRM 核心
CONFIG_DRM_CANAAN_DSI=y      # MIPI DSI 控制器支持
```

依赖：
- `DRM`、`DRM_KMS_HELPER`、`DRM_KMS_DMA_HELPER`、`DRM_GEM_DMA_HELPER`
- `DRM_MIPI_DSI`（DSI 子驱动）

### 9.2 Buildroot 包依赖

```
display 包 → 依赖 libdrm
vg_lite    → 依赖 libdrm
lvgl       → 依赖 libdrm + vg_lite
ffmpeg     → 可选依赖 libdrm
```

### 9.3 设备树要求

DRM 平台驱动匹配 `compatible = "canaan,display-subsystem"`，DTS 中需要：
- display-subsystem 节点
- VO 控制器节点（寄存器、中断）
- DSI 控制器节点（寄存器、面板引用）
- Panel 节点（DSI 连接、时序参数）

---

## 10. 常见问题

### 10.1 打开 /dev/dri/card0 失败

确认内核已加载 `canaan-drm` 驱动：
```bash
ls /dev/dri/card0
dmesg | grep canaan
```

### 10.2 Atomic Commit 返回 EINVAL

通常是 Plane 属性设置错误，检查：
- `SRC_W/SRC_H` 使用 16.16 定点格式（需 `<< 16`）
- Plane 的 `possible_crtcs` 掩码是否匹配当前 CRTC
- 像素格式是否被 Plane 支持

### 10.3 旋转不生效

不是所有 Plane 都支持旋转。需要通过 `plane_has_property(plane, "rotation")` 检查：
- Layer1~3（视频层）支持 90°/180°/270° 旋转
- OSD 层通常不支持硬件旋转

### 10.4 多 Plane 使用

通过 `display_get_plane()` 多次获取不同格式的 Plane，每次调用会在内部链表追加。提交时所有 Plane 的属性合并在同一个 Atomic Request 中一次性提交。
