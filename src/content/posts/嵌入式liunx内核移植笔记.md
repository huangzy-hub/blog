---
title: 嵌入式liunx内核移植笔记
published: 2026-02-10
pinned: false
description: nxp的liunx内核移植到正点原子i.mx6ull流程（基于正点原子的笔记）
tags: [liunx]
category: 嵌入式
draft: false
---

# Linux内核源码目录

![liunx内核源码1](/assets/images/liunx内核源码1.png)
![liunx内核源码2](/assets/images/liunx内核源码2.png)

# Linux内核移植

## 一、移植概述

本次Linux内核移植，以NXP官方I.MX6ULL EVK开发板的Linux源码为基础，将其适配移植到正点原子I.MX6U-ALPHA（EMMC版）开发板。

核心逻辑：NXP官方源码已完美适配自身EVK开发板，I.MX6U-ALPHA与EVK硬件架构一致（均为I.MX6ULL芯片），因此无需大幅修改内核源码，仅需完成「配置适配」「添加自定义开发板信息」「编译测试」三步，即可实现内核移植。

环境说明：

- 宿主系统：Ubuntu 18.04/20.04（64位）

- 交叉编译器：arm-linux-gnueabihf-（需提前安装并配置环境变量）

- 源码：NXP官方提供的I.MX6ULL Linux内核源码

- 开发板：正点原子I.MX6U-ALPHA EMMC版

- 调试方式：TFTP下载内核镜像+UBOOT命令行启动测试

## 二、前期准备

1.  确认交叉编译器可用：在Ubuntu终端输入命令 `arm-linux-gnueabihf-gcc -v`，若能显示编译器版本信息（如gcc version 7.5.0），说明配置成功。

2.  解压内核源码：将NXP官方Linux源码压缩包（如linux-imx-4.1.15-2.1.0.tar.xz）解压到Ubuntu自定义目录，示例命令：

```bash

tar -xvf linux-imx-4.1.15-2.1.0.tar.xz -C /home/xxx/linux/  # xxx替换为自身用户名

```

3.  配置TFTP服务（用于内核镜像和设备树文件下载）：确保Ubuntu已安装TFTP服务，且TFTP根目录（如/home/xxx/linux/tftpboot）权限设置为777（命令：chmod 777 /home/xxx/linux/tftpboot -R）。

4.  确认UBOOT正常：开发板已烧写适配I.MX6U-ALPHA的UBOOT，且能进入UBOOT命令行模式，可正常ping通Ubuntu（确保开发板与Ubuntu在同一局域网）。

## 三、第一步：编译NXP官方内核（验证兼容性）

先编译NXP官方I.MX6ULL EVK开发板的内核，测试其是否能在I.MX6U-ALPHA开发板上启动，排查硬件兼容性问题。

### 3.1 修改顶层Makefile（指定架构和交叉编译器）

进入内核源码根目录（如/home/xxx/linux/linux-imx-4.1.15-2.1.0），修改顶层Makefile，直接定义ARCH（架构）和CROSS_COMPILE（交叉编译器）变量，避免每次编译都输入繁琐参数。

操作步骤：

1.  打开顶层Makefile：使用vim编辑器，命令 `vim Makefile`。

2.  查找并修改第252、253行（不同源码版本行数可能略有差异，可通过vim搜索：输入 `/ARCH ?=` 快速定位）：

修改前：

```makefile

ARCH ?= $(SUBARCH)

CROSS_COMPILE ?= $(CONFIG_CROSS_COMPILE:"%"=%)

```

修改后：

```makefile

ARCH = arm

CROSS_COMPILE = arm-linux-gnueabihf-

```

3.  保存退出：按ESC，输入 `:wq` 保存并关闭Makefile。

### 3.2 配置Linux内核（加载官方默认配置）

每个开发板都有对应的内核默认配置文件，NXP官方为I.MX6ULL EVK提供了两个配置文件，均存放在 `arch/arm/configs` 目录下：

- imx_v7_defconfig：EVK开发板基础配置文件

- imx_v7_mfg_defconfig：推荐使用，默认支持I.MX6UL芯片，且编译产物（zImage）可通过NXP官方MfgTool工具烧写，适配后续调试。

配置命令（源码根目录下执行）：

```bash

make clean  # 第一次编译前必须清理工程，删除残留的编译文件和配置文件，避免冲突

make imx_v7_mfg_defconfig  # 加载EVK开发板默认配置

```

配置成功提示：终端会输出一系列配置日志，最终显示「# configuration written to .config」，说明配置文件已生成（.config文件是内核编译的核心配置文件）。

### 3.3 编译Linux内核

配置完成后，执行编译命令，开启多线程编译（提高编译速度，-j后数字根据Ubuntu CPU核心数调整，如4核输入-j4，8核输入-j8，16核输入-j16）：

```bash

make -j16  # 多线程编译内核，耗时约5-15分钟（取决于电脑配置）

```

编译注意事项：

- 若编译过程中提示「缺少某个依赖包」（如libssl-dev），执行命令 `sudo apt-get install 缺失的包名` 安装即可。

- 若出现编译报错，先执行 `make clean` 清理工程，再重新执行编译命令，若仍报错，排查交叉编译器配置或源码完整性。

编译成功标志：终端最后输出「Kernel: arch/arm/boot/zImage is ready」，说明内核镜像编译完成。

### 3.4 查看编译产物

编译完成后，会生成两个核心文件，后续用于开发板启动：

1.  内核镜像文件：`arch/arm/boot/zImage`（Linux内核核心镜像，是启动的核心文件）

2.  设备树文件：`arch/arm/boot/dts/imx6ull-14x14-evk.dtb`（EVK开发板对应的设备树，描述硬件资源分布，如GPIO、UART等）

### 3.5 内核启动测试（验证兼容性）

将编译生成的zImage和imx6ull-14x14-evk.dtb下载到开发板，测试EVK官方内核是否能在I.MX6U-ALPHA上启动。

操作步骤：

1.  复制编译产物到TFTP根目录（示例命令，路径替换为自身TFTP目录）：

```bash

cp arch/arm/boot/zImage /home/xxx/linux/tftpboot/ -f  # -f强制覆盖原有文件（若有）

cp arch/arm/boot/dts/imx6ull-14x14-evk.dtb /home/xxx/linux/tftpboot/ -f

```

2.  启动开发板，进入UBOOT命令行：开发板上电后，快速按键盘任意键（如空格键），阻止UBOOT自动启动，进入UBOOT命令行模式（终端显示「=>」提示符）。

3.  配置UBOOT环境变量（指定根文件系统路径，确保内核启动后能挂载根文件系统）：

```bash

setenv bootargs 'console=ttymxc0,115200 root=/dev/mmcblk1p2 rootwait rw'  # 关键配置

saveenv  # 保存环境变量，避免下次上电丢失

```

环境变量说明：

- console=ttymxc0,115200：指定串口控制台为ttymxc0（I.MX6ULL的UART1），波特率115200（与SecureCRT/putty配置一致）。

- root=/dev/mmcblk1p2：指定根文件系统存放在EMMC的第2个分区（正点原子EMMC版开发板出厂时，已在该分区烧写根文件系统）。

- rootwait rw：等待EMMC设备就绪，并以可读可写模式挂载根文件系统。

4.  通过TFTP下载内核和设备树，并启动：

```bash

tftp 80800000 zImage  # 将zImage下载到开发板内存地址0x80800000（I.MX6ULL常用内核加载地址）

tftp 83000000 imx6ull-14x14-evk.dtb  # 将设备树下载到内存地址0x83000000（设备树常用加载地址）

bootz 80800000 - 83000000  # 启动内核，格式：bootz 内核地址 - 设备树地址

```

测试结果：

- 若终端输出内核启动日志，最终显示「login:」（根文件系统登录提示符），说明EVK官方内核可在I.MX6U-ALPHA上正常启动，兼容性无问题。

- 若启动失败，先排查TFTP连接（确保开发板能ping通Ubuntu）、UBOOT环境变量配置、内存地址是否正确。

## 四、常见问题：根文件系统缺失错误

### 4.1 错误现象

若未配置UBOOT的bootargs环境变量（或未指定root参数），执行bootz命令启动后，内核会崩溃，终端输出：

```

Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)

```

### 4.2 错误原因

Linux内核启动后，必须挂载根文件系统（用于存放系统命令、应用程序、配置文件等），否则无法正常运行。上述错误表示：VFS（虚拟文件系统）无法挂载根文件系统，因为bootargs未指定根文件系统的存放路径（unknown-block(0,0)表示未找到根设备）。

### 4.3 解决方案

重新配置UBOOT的bootargs环境变量，指定正确的根文件系统路径（参考3.5.3步骤），保存后重新启动即可。

补充说明：若开发板未烧写根文件系统，需先制作并烧写根文件系统（如BusyBox制作最小根文件系统），再配置bootargs指定路径。

## 五、第二步：在Linux内核中添加自定义开发板（I.MX6U-ALPHA）

官方内核已能正常启动，但为了适配I.MX6U-ALPHA开发板的硬件细节（后续可修改设备树适配自定义硬件），需在Linux内核中添加该开发板的「默认配置文件」和「设备树文件」，实现专属适配。

### 5.1 添加开发板默认配置文件

以官方imx_v7_mfg_defconfig为模板，复制一份作为I.MX6U-ALPHA（EMMC版）的默认配置文件，并修改适配。

操作命令（源码根目录下执行）：

```bash

cd arch/arm/configs  # 进入配置文件目录

cp imx_v7_mfg_defconfig imx_alientek_emmc_defconfig  # 复制并命名为自定义配置文件（alientek对应正点原子）

```

修改自定义配置文件：

1.  打开文件：`vim imx_alientek_emmc_defconfig`。

2.  查找并屏蔽「CONFIG_ARCH_MULTI_V6=y」这一行：

修改前：`CONFIG_ARCH_MULTI_V6=y`

修改后：`# CONFIG_ARCH_MULTI_V6=y`（添加#号屏蔽）

3.  保存退出：`:wq`。

修改原因：I.MX6ULL芯片属于ARMv7架构，屏蔽ARMv6相关配置，可避免后续驱动开发时，驱动模块无法加载（架构不兼容）的问题。

后续配置I.MX6U-ALPHA内核时，直接使用命令：`make imx_alientek_emmc_defconfig`。

### 5.2 添加开发板对应的设备树文件

设备树（.dts文件）用于描述开发板的硬件资源，内核通过设备树识别硬件（如GPIO、SPI、I2C等）。同样以官方EVK开发板的设备树为模板，复制并修改为I.MX6U-ALPHA的设备树。

操作步骤：

1.  进入设备树源码目录，复制官方设备树文件：

```bash

cd arch/arm/boot/dts  # 设备树源码存放目录

cp imx6ull-14x14-evk.dts imx6ull-alientek-emmc.dts  # 复制并命名为自定义设备树（对应EMMC版）

```

2.  修改Makefile，确保编译内核时能生成自定义设备树的.dtb文件：

打开设备树目录的Makefile：`vim Makefile`。

查找「dtb-$(CONFIG_SOC_IMX6ULL) +=」配置项（该配置项用于指定I.MX6ULL芯片对应的设备树文件），在其中添加自定义设备树文件名「imx6ull-alientek-emmc.dtb」。

修改后示例（关键添加第422行）：

```makefile

dtb-$(CONFIG_SOC_IMX6ULL) += \

imx6ull-14x14-ddr3-arm2.dtb \

imx6ull-14x14-ddr3-arm2-adc.dtb \

...（省略中间官方设备树）...\

imx6ull-14x14-evk-usb-certi.dtb \

imx6ull-alientek-emmc.dtb \  # 新增：I.MX6U-ALPHA EMMC版设备树

imx6ull-9x9-evk.dtb \

```

3.  保存退出：`:wq`。

补充：后续若需修改I.MX6U-ALPHA的硬件适配（如修改GPIO引脚、添加外设驱动），可直接编辑「imx6ull-alientek-emmc.dts」文件，无需修改官方设备树。

### 5.3 编写编译脚本（简化编译操作）

为了避免每次编译都输入多条命令，可编写一个shell脚本，整合清理、配置、编译全流程。

操作步骤：

1.  回到内核源码根目录，创建编译脚本文件：

```bash

cd /home/xxx/linux/linux-imx-4.1.15-2.1.0  # 回到源码根目录

vim imx6ull_alientek_emmc.sh  # 创建脚本文件

```

2.  写入脚本内容（完整代码）：

```bash

#!/bin/sh

# 脚本功能：编译I.MX6U-ALPHA EMMC版Linux内核

# 第一步：清理工程（彻底删除之前的编译产物和配置文件）

make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- distclean

# 第二步：加载自定义开发板默认配置

make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- imx_alientek_emmc_defconfig

# 第三步：打开内核图形配置界面（可选，无需修改时可删除此行）

make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- menuconfig

# 第四步：多线程编译内核（-j16根据CPU核心数调整）

make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- all -j16

```

3.  保存退出：`:wq`。

4.  给予脚本可执行权限：

```bash

chmod 777 imx6ull_alientek_emmc.sh

```

脚本使用说明：后续编译内核时，仅需在源码根目录执行 `./imx6ull_alientek_emmc.sh`，即可自动完成清理、配置、编译全流程，大幅简化操作。

## 六、第三步：编译测试自定义开发板内核

完成自定义开发板的配置文件和设备树添加后，编译内核并测试，确认移植成功。

### 6.1 编译内核

源码根目录下执行编译脚本：

```bash

./imx6ull_alientek_emmc.sh

```

编译成功标志：终端输出「Kernel: arch/arm/boot/zImage is ready」，且在 `arch/arm/boot/dts` 目录下生成「imx6ull-alientek-emmc.dtb」文件。

### 6.2 启动测试

操作步骤与3.5节一致，仅需替换设备树文件为自定义版本：

1.  复制编译产物到TFTP根目录：

```bash

cp arch/arm/boot/zImage /home/xxx/linux/tftpboot/ -f

cp arch/arm/boot/dts/imx6ull-alientek-emmc.dtb /home/xxx/linux/tftpboot/ -f

```

2.  开发板上电，进入UBOOT命令行（若之前已配置bootargs，无需重新配置）。

3.  TFTP下载并启动：

```bash

tftp 80800000 zImage

tftp 83000000 imx6ull-alientek-emmc.dtb

bootz 80800000 - 83000000

```

### 6.3 移植成功标志

1.  内核启动日志正常，无报错；

2.  终端最终显示「login:」（根文件系统登录提示符），输入用户名（如root）和密码（正点原子出厂根文件系统密码通常为root），可进入Linux命令行模式；

3.  输入Linux基础命令（如ls、pwd、whoami），能正常执行，说明内核和根文件系统均正常工作。

## 七、移植总结

本次I.MX6U-ALPHA开发板Linux内核移植，核心是「复用官方源码，添加自定义适配」，全程无复杂的内核源码修改，关键步骤总结如下：

1.  前期准备：配置交叉编译器、TFTP服务，确认UBOOT正常；

2.  兼容性测试：编译NXP官方EVK内核，测试其能在I.MX6U-ALPHA上启动；

3.  自定义适配：添加开发板默认配置文件（屏蔽V6架构）、添加自定义设备树文件、编写编译脚本；

4.  最终测试：编译自定义内核，通过TFTP下载启动，确认移植成功。

### 注意事项

1.  交叉编译器版本需与内核源码适配（如内核4.1.15推荐使用gcc 7.5.0版本），版本不匹配会导致编译报错；

2.  设备树文件名必须在Makefile中添加，否则编译时无法生成对应的.dtb文件；

3.  UBOOT环境变量bootargs中的根文件系统路径，需与开发板实际烧写路径一致；

4.  每次修改内核配置或设备树后，建议先执行make clean清理工程，再重新编译，避免残留文件影响结果；

5.  若后续需添加外设驱动（如LED、按键），可修改自定义设备树文件，无需修改内核核心源码。




# sd卡烧录liunx内核方式

### 核心逻辑先理清
- 上位机（Ubuntu）端：直接把编译好的 `zImage` 和 `.dtb` 拷贝到 SD 卡的 FAT32 分区（无需通过 TFTP 中转）；
- U-Boot 端：配置自动启动脚本，上电后自动从 SD 卡读取内核/设备树到内存，然后启动（彻底摆脱手动输命令）。

## 一、第一步：Ubuntu 上位机将内核/设备树烧录到 SD 卡
这一步是直接在 Ubuntu 上操作 SD 卡，把文件写入 SD 卡的 FAT32 分区，无需开发板参与。

### 1.1 准备工作
1. **SD 卡分区**：确保 SD 卡已分好区（新手推荐用 Ubuntu 自带的 `gparted` 工具）：
   - 第 1 分区：FAT32 格式（大小建议 256MB+），用于存放 `zImage` 和 `.dtb`；
   - 第 2 分区：ext4 格式（剩余空间），用于存放根文件系统（可选，若仅测试内核启动可先不弄）。
2. **插入 SD 卡到 Ubuntu**：用读卡器把 SD 卡插到 Ubuntu 主机的 USB 口，Ubuntu 会自动挂载 SD 卡分区。

### 1.2 查看 SD 卡挂载路径
执行以下命令找到 SD 卡的挂载点（关键，避免写错路径）：
```bash
# 查看 SD 卡设备名（比如 /dev/sdb）
lsblk
# 示例输出（关注 NAME 列，SD 卡通常是 sdb，分区是 sdb1、sdb2）：
# NAME   MAJ:MIN RM   SIZE RO TYPE MOUNTPOINT
# sda      8:0    0 465.8G  0 disk 
# └─sda1   8:1    0 465.8G  0 part /
# sdb      8:16   1  14.9G  0 disk 
# ├─sdb1   8:17   1   256M  0 part /media/xxx/boot  # FAT32 分区（挂载点记下来）
# └─sdb2   8:18   1  14.6G  0 part /media/xxx/rootfs  # ext4 分区
```
记住 FAT32 分区的挂载点（比如 `/media/xxx/boot`），后续要把文件拷贝到这里。

### 1.3 拷贝内核/设备树到 SD 卡
进入 Linux 内核源码根目录，执行以下命令把编译好的 `zImage` 和 `.dtb` 拷贝到 SD 卡的 FAT32 分区：
```bash
# 拷贝 zImage（替换挂载点为你自己的）
cp arch/arm/boot/zImage /media/xxx/boot/ -f

# 拷贝自定义设备树（替换为你的 .dtb 文件名）
cp arch/arm/boot/dts/imx6ull-alientek-emmc.dtb /media/xxx/boot/ -f
```

### 1.4 安全卸载 SD 卡
拷贝完成后，必须卸载 SD 卡再拔读卡器，避免文件损坏：
```bash
# 卸载 FAT32 分区（替换挂载点）
umount /media/xxx/boot

# 若有 ext4 分区也卸载（可选）
umount /media/xxx/rootfs
```
然后拔下读卡器，SD 卡就烧录好了。

## 二、第二步：配置 U-Boot 自动加载 SD 卡中的内核启动
把烧好的 SD 卡插入开发板的 SD 卡槽，进入 U-Boot 命令行，配置自动启动脚本，上电后 U-Boot 会自动从 SD 卡读内核/设备树并启动。

### 2.1 确认 SD 卡可被 U-Boot 识别
```bash
# 列出所有 mmc 设备（IMX6ULL 中 SD 卡通常是 mmc 0，EMMC 是 mmc 1）
mmc list
# 示例输出：
# mmc0: SD/MMC card at 0  <-- 这是 SD 卡
# mmc1: eMMC card at 1    <-- 这是 EMMC

# 切换到 SD 卡
mmc dev 0
```

### 2.2 配置 U-Boot 环境变量（核心步骤）
```bash
# 1. 设置 bootargs（指定根文件系统路径，若 SD 卡有根文件系统则填 mmc 0:2，否则用 EMMC 的 mmc 1:2）
setenv bootargs 'console=ttymxc0,115200 root=/dev/mmcblk0p2 rootwait rw'
# 解释：
# console=ttymxc0,115200：串口控制台（和之前一致）
# root=/dev/mmcblk0p2：根文件系统在 SD 卡（mmcblk0）的第 2 分区（p2）
# 若根文件系统在 EMMC，改为 root=/dev/mmcblk1p2

# 2. 设置 bootcmd（自动启动命令：从 SD 卡读内核/设备树到内存，然后启动）
setenv bootcmd 'mmc dev 0; fatload mmc 0:1 80800000 zImage; fatload mmc 0:1 83000000 imx6ull-alientek-emmc.dtb; bootz 80800000 - 83000000'
# 命令拆解：
# mmc dev 0：切换到 SD 卡
# fatload mmc 0:1 80800000 zImage：从 SD 卡第 1 分区（0:1）读 zImage 到内存 0x80800000
# fatload mmc 0:1 83000000 imx6ull-alientek-emmc.dtb：读设备树到内存 0x83000000
# bootz 80800000 - 83000000：启动内核

# 3. 保存环境变量（关键！否则重启后配置丢失）
saveenv

# 4. 测试启动（可选，验证配置是否正确）
run bootcmd
```

### 2.3 验证自动启动
重启开发板（执行 `reset` 命令或断电重启），U-Boot 会自动执行 `bootcmd` 中的命令：
1. 自动切换到 SD 卡；
2. 自动读取 `zImage` 和 `.dtb` 到内存；
3. 自动启动内核，最终进入 Linux 命令行（若根文件系统正常）。

## 三、常见问题排查
1. **U-Boot 识别不到 SD 卡**：
   - 检查 SD 卡是否插紧，读卡器是否正常；
   - 执行 `mmc rescan` 重新扫描 SD 卡；
   - 确认 `mmc dev 0` 是 SD 卡（部分开发板 SD 卡设备号是 1，EMMC 是 0，以 `mmc list` 输出为准）。
2. **提示“File not found”**：
   - 检查 SD 卡中 `zImage`/`.dtb` 的文件名是否和 `bootcmd` 中一致（区分大小写！）；
   - 确认文件确实在 SD 卡的 FAT32 分区（第 1 分区）。
3. **内核启动后提示根文件系统挂载失败**：
   - 检查 `bootargs` 中的 `root=/dev/mmcblkXpX` 是否正确（SD 卡是 mmcblk0，EMMC 是 mmcblk1）；
   - 确认 SD 卡/EMMC 的对应分区有根文件系统。

### 总结
1. 上位机烧录：Ubuntu 中把 `zImage`/`.dtb` 直接拷贝到 SD 卡的 FAT32 分区（无需 TFTP 中转）；
2. U-Boot 配置：设置 `bootcmd` 自动从 SD 卡读文件到内存，设置 `bootargs` 指定根文件系统路径；
3. 核心命令：
   - 上位机拷贝：`cp zImage/.dtb 到 SD 卡 FAT32 挂载点`；
   - U-Boot 自动启动：`setenv bootcmd 'mmc dev 0; fatload ...; bootz ...' && saveenv`。