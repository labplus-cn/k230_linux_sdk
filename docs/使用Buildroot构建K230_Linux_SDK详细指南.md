# 使用 Buildroot 构建 K230 Linux SDK 详细指南

> 本文档基于当前 SDK 源码（Buildroot 2025.02.1）编写，详细讲解如何使用 Buildroot 构建 K230/K230D Linux 系统镜像，包括构建原理、常用命令、定制方法与常见问题。

## 1. 概述

K230 Linux SDK 采用 **"原始 Buildroot + overlay 覆盖"** 的方式组织：

- 官方仓库中**不包含** Buildroot 本体和 U-Boot/Linux/OpenSBI 完整源码，只包含：
  - `buildroot-overlay/`：所有对 Buildroot 的修改（板级配置、包、脚本、U-Boot/OpenSBI overlay 源码）
  - `Makefile` + `tools/sync.mk`：顶层构建驱动
  - `dl/`：预下载的源码包缓存
- 首次执行 `make` 时，自动下载 `buildroot-2025.02.1.tar.xz` 解压到 `output/buildroot-2025.02.1/`，再用 rsync 将 overlay 覆盖进去，形成完整的定制版 Buildroot，然后按指定 defconfig 完成编译。

## 2. 环境准备

### 2.1 系统要求

- 推荐宿主机系统：**Ubuntu 22.04 / 24.04**（原生 Linux、虚拟机、WSL2、Docker 均可）
- 磁盘空间：≥ 30 GB（源码 + 编译输出 + 镜像）
- 内存：≥ 4 GB（并行编译建议 8 GB+）

### 2.2 一键安装依赖与工具链（推荐）

```bash
cd k230_linux_sdk
sudo make toolchain_and_depend
```

该命令执行 `tools/install_toolchain_and_depend.sh`，完成两件事：

1. `apt-get install` 全部构建依赖（git、make、gcc、rsync、cpio、bc、cmake、bison、flex、libssl-dev 等）
2. 自动下载玄铁 RISC-V 交叉工具链并解压到 `/opt/toolchain/`：

```
/opt/toolchain/Xuantie-900-gcc-linux-6.6.0-glibc-x86_64-V3.0.2/
└── bin/riscv64-unknown-linux-gnu-gcc  (gcc 14.1.1)
```

脚本会从以下镜像源自动选择可用的一个下载工具链：

- `https://ai.b-bug.org/k230/downloads/dl/gcc`
- `https://kendryte-download.canaan-creative.com/k230/downloads/dl/gcc`

### 2.3 手动安装（可选）

```bash
# 依赖包
sudo apt-get install -y git sed make binutils build-essential diffutils gcc g++ \
    bash patch gzip bzip2 perl tar cpio unzip rsync file bc findutils wget \
    libncurses-dev python3 libssl-dev gawk cmake bison flex bash-completion \
    parted curl xz-utils

# 工具链（手动下载后解压）
mkdir -p /opt/toolchain
tar -zxvf Xuantie-900-gcc-linux-6.6.0-glibc-x86_64-V3.0.2-*.tar.gz -C /opt/toolchain
```

> 仅 `k230d_canmv_ilp32_defconfig` / `BPI-CanMV-K230D-Zero_ilp32_defconfig`（32 位 rootfs）需要额外安装 ruyisdk 的 rv64ilp32 工具链，普通 64 位配置无需。

### 2.4 Docker 环境（可选）

```bash
# 构建镜像
docker build -f tools/docker/Dockerfile -t wjx/d tools/docker

# 运行（挂载 home 与工具链）
docker run -it --rm -h k230 \
    -e uid=$(id -u) -e gid=$(id -g) -e user=${USER} \
    -v $HOME:$HOME -v /opt/toolchain:/opt/toolchain \
    -w $(pwd) wjx/d:latest
```

### 2.5 WSL 用户注意事项

WSL 默认把 Windows PATH（含 `Program Files` 等带空格路径）混入 Linux 环境，Buildroot 会报 `Your PATH contains spaces` 而终止。解决方案：

1. `/etc/wsl.conf` 添加以下内容后执行 `wsl --shutdown` 重启 WSL：
   ```ini
   [interop]
   appendWindowsPath = false
   ```
2. 或在 `~/.bashrc` 末尾追加过滤函数兜底：
   ```bash
   _clean_path() {
       local p=() entry
       IFS=: read -ra entry <<< "$PATH"
       for e in "${entry[@]}"; do [[ "$e" != *" "* && "$e" != *$'\t'* ]] && p+=("$e"); done
       export PATH="$(IFS=:; echo "${p[*]}")"
   }
   _clean_path
   ```

## 3. 获取 SDK 源码

```bash
git clone git@github.com:kendryte/k230_linux_sdk.git
# 或 gitee 镜像：git clone git@gitee.com:kendryte/k230_linux_sdk.git
cd k230_linux_sdk
```

### SDK 目录结构

```
k230_linux_sdk/
├── Makefile                  # 顶层构建入口
├── buildroot-overlay/        # 对 Buildroot 的全部修改（会覆盖到解压后的 buildroot）
│   ├── arch/Config.in.riscv  # RISC-V 架构选项
│   ├── board/canaan/k230-soc/# 板级脚本：post-build.sh / post-image.sh / genimage.cfg / rootfs_overlay/
│   ├── boot/
│   │   ├── opensbi/opensbi-1.4-overlay/   # OpenSBI 板级源码（单独 rsync 时机）
│   │   └── uboot/u-boot-2022.10-overlay/  # U-Boot 板级源码（defconfig、board 代码）
│   ├── configs/              # 各开发板 defconfig
│   ├── linux/                # 内核构建定义 linux.mk + 内核补丁
│   └── package/              # K230 私有包（vvcam、ai2d_kpu、ai_demo、lvgl、ffmpeg…）
├── dl/                       # 源码包缓存（buildroot/uboot/linux/各软件包 tarball）
├── docs/                     # 文档
├── output/                   # 构建输出（buildroot 本体 + 各配置的编译目录）
│   ├── buildroot-2025.02.1/  # 解压并覆盖 overlay 后的完整 Buildroot（BR_SRC_DIR）
│   └── <conf>/               # 每个配置一个独立输出目录（O= 目录）
└── tools/                    # 辅助脚本（下载、docker、ddr 测试镜像、工具链安装）
```

## 4. 构建原理详解

### 4.1 顶层 Makefile 关键变量

```makefile
BR_NAME      = buildroot-2025.02.1
BR_SRC_DIR   = output/buildroot-2025.02.1     # Buildroot 本体目录
BR_OVERLAY_DIR = buildroot-overlay            # overlay 目录
BRW_BUILD_DIR = output/$(CONF)                # 编译输出目录（O=）
```

`.last_conf` 文件记录最近一次使用的配置，`make` 不带参数时沿用该配置。

### 4.2 首次构建自动执行的步骤（make CONF=xxx）

1. **下载解压 Buildroot**（`tools/sync.mk`）
   - 通过 `tools/download/dl-wrapper` 从 `BR2_PRIMARY_SITE` 或 buildroot.org 下载 `buildroot-2025.02.1.tar.xz` 到 `dl/`
   - 解压到 `output/buildroot-2025.02.1/`，并删除其中的 `package/python3`、`package/ffmpeg`（用 overlay 中定制版替换）
2. **同步 overlay**
   ```bash
   rsync -a buildroot-overlay/ output/buildroot-2025.02.1/ --exclude "*-overlay" --exclude "linux-6.6.22"
   ```
   注意 U-Boot/OpenSBI 的 overlay 目录（`*-overlay`）**不会**在此步合入，而是在 Buildroot 编译 uboot/opensbi 包时由各自的 `.mk` 文件 rsync 进解压后的源码树（见 `boot/uboot/uboot.mk` 的 `.overlay_sync` 规则），以保证 overlay 修改后能触发重新同步。
3. **配置 Buildroot**
   ```bash
   make -C output/buildroot-2025.02.1 <CONF> O=$PWD/output/<CONF>
   ```
4. **编译**
   ```bash
   make -C output/<CONF> all
   ```

### 4.3 编译产物的生成（post-image 流程）

Buildroot 编译完成 toolchain → uboot → opensbi → linux → rootfs 各包后，`board/canaan/k230-soc/` 下的脚本接管镜像生成：

- `post-build.sh`：rootfs 收尾处理
- `post-image.sh`：调用 `genimage` 按 `genimage.cfg` 打包 SD 卡镜像

`genimage.cfg` 定义的 SD 卡 GPT 分区布局：

| 分区 | 偏移 | 内容 | 大小 |
|------|------|------|------|
| uboot_spl_1 | 1M | fn_u-boot-spl.bin | 512K |
| uboot_spl_2 | 1.5M | fn_u-boot-spl.bin（备份） | 512K |
| uboot_env | 0x1e0000 | env.env | 128K |
| uboot | 2M | fn_ug_u-boot.bin | 1.5M |
| env | 0x380000 | env.env（备份） | 128K |
| boot | 30M | boot.ext4（内核、dtb） | 80M |
| rootfs | 128M | rootfs.ext4 | 剩余空间 |

## 5. 支持的开发板配置

`make list_def` 可查看全部配置。常用配置（位于 `buildroot-overlay/configs/`）：

| 配置文件 | 开发板 |
|----------|--------|
| `k230_canmv_defconfig` | CanMV-K230 1.0/1.1 |
| `k230_canmv_v3_defconfig` | CanMV-K230 V3 |
| `k230_canmv_01studio_defconfig` | 01Studio |
| `k230_canmv_dongshanpi_defconfig` | 东山派 |
| `k230_canmv_lckfb_defconfig` | 立创·庐山派（嘉立创） |
| `k230_canmv_labplus_1956_defconfig` | Labplus 1956 |
| `k230d_canmv_defconfig` | K230D-CanMV（64 位） |
| `k230d_canmv_ilp32_defconfig` | K230D-CanMV（32 位 rootfs，PLCT） |
| `BPI-CanMV-K230D-Zero_defconfig` | 香蕉派 K230D-Zero |
| `BPI-CanMV-K230D-Zero_ilp32_defconfig` | 香蕉派 K230D-Zero（32 位） |
| `k230_evb_defconfig` | K230 EVB |

> k230 与 k230d 的区别：k230d 片内多集成一颗 128MB LPDDR4。

## 6. 编译完整流程

### 6.1 标准编译

```bash
# 首次编译：指定配置（以 labplus 1956 为例）
make CONF=k230_canmv_labplus_1956_defconfig

# 后续编译：直接
make            # 等价于 make all → make buildroot
make -j20       # 也可显式指定并行度
```

首次全量编译约 30 分钟～2 小时（取决于网络与机器性能）；增量编译只执行变更部分。

如需在内网/加速环境下载源码包，可指定主下载站：

```bash
make CONF=k230_canmv_labplus_1956_defconfig \
     BR2_PRIMARY_SITE=https://kendryte-download.canaan-creative.com/k230/downloads/dl/
```

### 6.2 只下载源码不编译

```bash
make dl    # 预取所有软件包源码到 dl/
```

### 6.3 编译输出

产物位于 `output/<CONF>/images/`：

| 文件 | 说明 |
|------|------|
| `sysimage-sdcard.img.gz` | **最终 SD 卡烧录镜像**（压缩包，烧录前需解压） |
| `sysimage-sdcard.img` | 同上（未压缩） |
| `rootfs.ext4` | 根文件系统镜像（约 2GB） |
| `boot.ext4` | 启动分区镜像（内核 + dtb，约 80MB） |
| `rootfs.tar.xz` | 根文件系统 tar 包 |
| `uboot/` | SPL、U-Boot、env 等中间产物 |

## 7. 常用构建命令

所有命令在 SDK 根目录执行，会自动透传到 `output/<CONF>`：

```bash
make menuconfig          # 打开 Buildroot 图形配置
make savedefconfig       # 保存配置（并自动拷回 buildroot-overlay/configs/）
make list_def            # 列出所有支持的配置及当前配置

make uboot-rebuild       # 重新编译 U-Boot
make uboot-dirclean      # 彻底清除 U-Boot 构建目录（下次全量重编）
make linux-rebuild       # 重新编译内核
make linux-dirclean      # 彻底清除内核构建目录
make linux-menuconfig    # 内核 menuconfig
make linux-savedefconfig # 保存内核配置（自动拷回 arch/riscv/configs/k230_defconfig）

make clean               # 清除当前配置的输出
make distclean           # 清除输出目录及 .config（慎用）

make toolchain_and_depend  # 安装工具链与依赖

# 发行版 rootfs（先构建 buildroot，再调用 distribution.sh 替换 rootfs）
make debian
make ubuntu
make openouler

# DDR 测试镜像（容量可选 128/512/1024/2048 MB）
make ddr_test_img_128
```

### 7.1 修改源码后如何重新生效

| 修改位置 | 生效方式 |
|----------|----------|
| `buildroot-overlay/boot/uboot/u-boot-2022.10-overlay/` 下的 U-Boot 源码 | `make uboot-dirclean && make`（overlay 变更会触发 rsync 重新同步） |
| 内核源码（由 `linux/linux.mk` + 补丁从 dl 包展开） | 改 overlay 补丁后 `make linux-dirclean && make`；或直接改 `output/<CONF>/build/linux-6.6.22/` 后 `make linux-rebuild` |
| `buildroot-overlay/` 其它文件（脚本、包定义、配置） | 依赖 `.overlay_sync` 时间戳自动重新同步，再次 `make` 即可 |
| defconfig 本身 | `make CONF=<新配置>` 重新初始化 |

> 注意：overlay 的重新同步依赖文件时间戳，若改了 overlay 但 `make` 未触发重编，执行 `rm output/.overlay_sync output/.uboot_overlay_sync output/.oepnsbi_overlay_sync`（或对应包 `-dirclean`）强制刷新。

## 8. 烧录与运行

### 8.1 镜像烧录

**Linux（dd）：**

```bash
# 先 ls -l /dev/sd* 确认 TF 卡设备节点（假设 /dev/sdc）
gunzip sysimage-sdcard.img.gz
sudo dd if=sysimage-sdcard.img of=/dev/sdc bs=1M oflag=sync
```

**Windows：** 使用 [rufus](http://rufus.ie/downloads/)，选择解压后的 `sysimage-sdcard.img` 写入 TF 卡。

### 8.2 启动验证

1. TF 卡插入开发板，Type-C 连接 PC
2. 串口软件（putty 等），参数：**115200 8N1 无流控**
   - Windows：CH342 串口 A（如 COM80）为调试串口
   - Linux：`/dev/ttyACM0` 为调试串口
3. 上电（可按 reset），串口看到 U-Boot → OpenSBI → 内核启动日志，最终进入：

```
[root@canaan ~]#
```

### 8.3 板上常用配置

```bash
# Wi-Fi（wpa 环境变量方式）
fw_setenv wlanssid <你的SSID>
fw_setenv wlanpass <你的密码>
```

## 9. 定制开发指南

### 9.1 修改 rootfs（rootfs_overlay）

板级根文件系统覆盖目录：`buildroot-overlay/board/canaan/k230-soc/rootfs_overlay/`。往该目录添加的文件/目录会在构建时按相同路径覆盖进 rootfs。例如添加开机脚本：

```
buildroot-overlay/board/canaan/k230-soc/rootfs_overlay/etc/init.d/S99myapp
```

> 修改后执行 `make` 即可（rootfs 相关步骤会重建）；确保脚本有可执行权限位（git 中 `update-index --chmod=+x`）。

### 9.2 添加自己的软件包

参考 `buildroot-overlay/package/helloworld_cmake/` 的结构：

```
package/myapp/
├── Config.in         # menuconfig 菜单项：config BR2_PACKAGE_MYAPP
├── myapp.mk          # 定义 MYAPP_SITE / _SITE_METHOD / _INSTALL_TARGET_STAGING 等
└── src/              # 源码（或改用 git 仓库拉取）
```

- 在 `package/Config_canaan.in`（或 `Config.in`）中 source 该 `Config.in`
- `make menuconfig` 勾选 `Target packages → myapp`
- `make savedefconfig` 保存到 defconfig

### 9.3 修改 U-Boot

U-Boot 板级源码就在 overlay 中（`buildroot-overlay/boot/uboot/u-boot-2022.10-overlay/`），直接修改后：

```bash
make uboot-dirclean
make
```

单独手动验证编译（不进 Buildroot 流程）：

```bash
cp -r output/<CONF>/build/uboot-2022.10 /tmp/uboot-test
cd /tmp/uboot-test
export CROSS_COMPILE=/opt/toolchain/Xuantie-900-gcc-linux-6.6.0-glibc-x86_64-V3.0.2/bin/riscv64-unknown-linux-gnu-
make k230_canmv_labplus_1956_defconfig   # 或 *_burntool_defconfig（烧录模式）
make -j$(nproc)
```

> `*_burntool_defconfig` 是配合 PC 端 K230 BurnTool 通过 USB DFU 烧写 eMMC/NAND/NOR 的精简版 U-Boot（裁剪启动/网络，保留 DFU + USB Gadget），日常 TF 卡烧录用不到。

### 9.4 应用程序交叉编译

```bash
export PATH=/opt/toolchain/Xuantie-900-gcc-linux-6.6.0-glibc-x86_64-V3.0.2/bin:$PATH

# 普通 C 程序
riscv64-unknown-linux-gnu-gcc hello.c -o hello

# RVV 向量程序（大核 C908 支持 RVV1.0）
riscv64-unknown-linux-gnu-gcc -march=rv64gcv_xtheadc rvv.c -o rvv
```

拷贝到板子（scp/rz）运行。注意：若放在 FAT32 分区执行报 `Permission denied`，先 `chmod +x`；FAT 分区不支持权限位时拷到 `/root` 等 ext4 路径再执行。

## 10. 常见问题（FAQ）

**Q1：`Your PATH contains spaces ...`**
WSL 环境混入 Windows PATH 所致，见 2.5 节。

**Q2：首次编译卡在下载某个源码包**
使用 `make CONF=xxx BR2_PRIMARY_SITE=https://kendryte-download.canaan-creative.com/k230/downloads/dl/` 走嘉楠镜像；或配置代理后重试。dl/ 目录已有预置缓存，多数包无需联网。

**Q3：改了 overlay 里的 U-Boot 代码但没生效**
`make uboot-dircclean && make`，必要时删除 `output/.uboot_overlay_sync` 强制重新 rsync。

**Q4：想看完整编译流程但只跑了 Finalizing**
增量编译只执行变更阶段，`make clean` 后重新 `make` 可看全流程。

**Q5：板上运行程序提示 `Permission denied`**
依次检查：文件名是否正确（区分大小写）→ `ls -l` 是否有 x 位 → 所在分区是否 noexec/FAT32 → `file` 确认是 RISC-V ELF。

**Q6：磁盘空间不足**
`output/<CONF>/build/` 下是各包解压构建目录，可用 `make <pkg>-dirclean` 清理单个包；`make clean` 清理整个配置输出（保留 .config）。

## 11. 参考资料

- Buildroot 官方手册：<https://buildroot.org/downloads/manual/manual.html>
- 嘉楠 K230 开发者文档：<https://developer.canaan-creative.com/>
- SDK 仓库：<https://github.com/kendryte/k230_linux_sdk> / <https://gitee.com/kendryte/k230_linux_sdk>
- 本仓库快速入门：`docs/linux_sdk快速入门指南.md`
