---
title: u-boot移植流程
published: 2026-02-08
pinned: false
description: nxp的u-boot移植到正点原子i.mx6ull流程（基于正点原子的笔记）
tags: [liunx, u-boot]
category: 嵌入式
draft: false
---


# 编译u-boot
## 一、编译前准备
### 1. 环境依赖安装
编译U-Boot需先安装`ncurses`库（否则会因缺少终端交互依赖报错），执行命令：
```bash
sudo apt-get install libncurses5-dev
```

### 2. 源码准备
- **创建目录**：在Ubuntu中新建U-Boot存放目录（示例：`/home/$USER/linux/uboot/alientek_uboot`）。
- **拷贝源码**：通过FileZilla将正点原子提供的U-Boot源码压缩包（`uboot-imx-2016.03-2.1.0-ge468cdc-v1.5.tar.bz2`）拷贝到上述目录。
- **解压源码**：执行解压命令，得到完整U-Boot源码：
  ```bash
  tar -vxjf uboot-imx-2016.03-2.1.0-g8b546e4.tar.bz2
  ```

## 二、核心编译流程（分核心板版本）
### 1. EMMC版（512MB DDR3 + 8GB EMMC）
#### 手动编译命令（分步执行）
```bash
# 1. 清理工程（首次编译必做，避免旧配置干扰）
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- distclean

# 2. 配置U-Boot（指定EMMC版配置文件）
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- mx6ull_14x14_ddr512_emmc_defconfig

# 3. 多核编译（-j12表示用12核编译，根据虚拟机/主机核心数调整）
make V=1 ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j12
```

#### 简化编译（Shell脚本）
新建`mx6ull_alientek_emmc.sh`脚本，内容如下：
```bash
#!/bin/bash
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- distclean
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- mx6ull_14x14_ddr512_emmc_defconfig
make V=1 ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j12
```
赋予执行权限并运行：
```bash
chmod +x mx6ull_alientek_emmc.sh  # 仅需执行一次
./mx6ull_alientek_emmc.sh         # 一键编译
```

### 2. NAND版（256MB DDR3 + 512MB NAND）
#### Shell脚本（`mx6ull_alientek_nand.sh`）
仅需替换配置文件，其余与EMMC版一致：
```bash
#!/bin/bash
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- distclean
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- mx6ull_14x14_ddr256_nand_defconfig
make V=1 ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j12
```
赋予权限并运行：
```bash
chmod +x mx6ull_alientek_nand.sh
./mx6ull_alientek_nand.sh
```

### 3. 编译参数说明
| 参数 | 作用 |
|------|------|
| `ARCH=arm` | 指定目标架构为ARM |
| `CROSS_COMPILE=arm-linux-gnueabihf-` | 指定ARM交叉编译器前缀 |
| `distclean` | 彻底清理工程（删除编译产物和配置文件） |
| `xxx_defconfig` | 加载预设配置文件（不同核心板对应不同配置） |
| `V=1` | 显示编译详细过程（便于排查编译错误） |
| `-jN` | 多核编译，N为核心数（提升编译速度） |

## 三、编译产物说明
编译完成后，源码目录新增核心文件：
- `u-boot.bin`：纯二进制U-Boot镜像（裸机程序，无法直接在I.MX6ULL运行）。
- `u-boot.imx`：**最终烧写文件**（在`u-boot.bin`头部添加IVT、DCD等I.MX6ULL启动必需的头部信息）。

## 四、U-Boot烧写与启动
### 1. SD卡烧写（最便捷的测试方式）
```bash
chmod 777 imxdownload  # 赋予烧写工具可执行权限（仅需一次）
./imxdownload u-boot.bin /dev/sdd  # 烧写到SD卡（注意：/dev/sdd为SD卡设备，切勿写/dev/sda）
```

### 2. 启动验证
1. 将烧写好的SD卡插入开发板，设置BOOT拨码开关为SD卡启动。
2. 连接USB-TTL串口到电脑，打开MobaXterm（串口参数：115200 8N1）。
3. 复位开发板，在`Hit any key to stop autoboot: `倒计时（默认3秒）内按回车，进入U-Boot命令行（提示符`=>`）。

### 3. 启动信息解读（核心内容）
| 输出行 | 关键信息 |
|--------|----------|
| `DRAM: 512 MiB` | 内存大小（EMMC版512MB，NAND版256MB） |
| `MMC: FSL_SDHC: 0, FSL_SDHC: 1` | MMC控制器：0=SD卡，1=EMMC |
| `Display: ATK-LCD-7-1024x600 (1024x600)` | LCD屏幕型号与分辨率 |
| `Net: FEC1` | 网口信息（FEC1未设置MAC地址会提示报错） |
| `Hit any key to stop autoboot: 0` | 倒计时结束未按回车则自动启动Linux内核 |

## 五、总结
1. 编译U-Boot的核心步骤是**清理工程→加载配置→多核编译**，不同核心板仅需替换`defconfig`配置文件。
2. Shell脚本可简化重复编译操作，需注意赋予脚本可执行权限。
3. `u-boot.imx`是最终烧写文件，需通过`imxdownload`工具烧写到SD卡/EMMC/NAND。
4. 启动后按回车进入U-Boot命令行，可执行各类调试/配置命令；未按回车则自动引导Linux内核。



# u-boot源码目录分析
## 一、整体目录结构（编译前后对比）

![编译后的u-boot源码文件1](/assets/images/编译后的u-boot源码文件1.png)
![编译后的u-boot源码文件2](/assets/images/编译后的u-boot源码文件2.png)

---

## 二、核心目录详解
### 1. `arch`：架构相关代码（图31.1.3~31.1.5）
存放与CPU架构相关的底层代码，I.MX6ULL属于**ARMv7架构**，重点关注：
- `arch/arm/`：ARM架构通用代码
  - `cpu/`：CPU核心架构代码
    - `armv7/`：Cortex-A7（I.MX6ULL内核）架构相关代码，是启动流程分析核心
    - `u-boot.lds`：ARM架构通用链接脚本，根目录`u-boot.lds`由此生成
  - `imx-common/`：I.MX系列芯片通用代码（I.MX6ULL专属）
  - `mach-xxx/`：不同厂商SoC的平台相关代码（如`mach-exynos`对应三星Exynos）

### 2. `board`：开发板定制代码（图31.1.6~31.1.7）
存放与具体开发板相关的驱动、配置，I.MX系列归属于`board/freescale/`（原Freescale后被NXP收购）：
- `mx6ullevk/`：NXP官方I.MX6ULL EVK开发板的板级文件，是移植正点原子开发板的参考模板
- `mx6ull_alientek_emmc/`：正点原子I.MX6ULL EMMC版开发板的板级文件夹（移植后新增）
  - 核心文件：`mx6ull_alientek_emmc.c`（板级初始化、LCD/网络等驱动实现）、`Makefile`、`Kconfig`、`imximage.cfg`（镜像头部配置）

### 3. `configs`：默认配置文件（图31.1.8）
存放各开发板的**默认配置文件**（`xxx_defconfig`格式），编译前需用`make xxx_defconfig`加载配置：
- 正点原子核心文件：
  - `mx6ull_14x14_ddr512_emmc_defconfig`：EMMC版（512MB DRAM）配置
  - `mx6ull_14x14_ddr256_nand_defconfig`：NAND版（256MB DRAM）配置
- 作用：快速加载厂商预设的uboot功能配置，避免手动逐项配置

### 4. `include`：头文件目录
存放所有头文件，核心子目录：
- `configs/`：开发板专属头文件（如`mx6ull_alientek_emmc.h`，通过`CONFIG_SYS_CONFIG_NAME`关联）
- `asm/`：架构相关汇编头文件
- `linux/`：Linux内核兼容头文件

### 5. 其他关键目录
| 目录 | 作用 |
|------|------|
| `cmd` | uboot命令实现（如`mmc`、`ping`、`bootm`等命令的源码） |
| `common` | 与硬件无关的通用代码（如主循环、环境变量处理） |
| `drivers` | 外设驱动（MMC、LCD、网络、USB、I2C等） |
| `dts` | 设备树文件（部分uboot版本支持设备树） |
| `net` | 网络协议栈相关代码（DHCP、TFTP、Ping等） |
| `tools` | 辅助工具（如`mkimage`，用于生成`u-boot.imx`） |

---

## 三、核心文件详解
### 1. `.config`：自动生成的配置文件
- 来源：执行`make xxx_defconfig`后自动生成
- 内容：以`CONFIG_`开头的配置项，控制功能使能/裁剪（如`CONFIG_CMD_BOOTM=y`表示使能`bootm`命令）
- 作用：Makefile根据这些配置项决定编译哪些文件、使能哪些功能

### 2. `Makefile`：顶层构建脚本
- 核心作用：
  1. 定义`ARCH`、`CROSS_COMPILE`等环境变量（可直接修改简化编译）
  2. 嵌套调用子目录Makefile，管理整个项目的编译链接
  3. 根据`.config`中的配置项，筛选需要编译的文件（`obj-y`/`obj-n`）

### 3. `.u-boot.xxx.cmd`：编译命令脚本
- 作用：记录各uboot镜像的生成规则，是分析镜像来源的关键
- 核心示例：
  - `.u-boot.bin.cmd`：`cp u-boot-nodtb.bin u-boot.bin` → `u-boot.bin`是`u-boot-nodtb.bin`的拷贝
  - `.u-boot-nodtb.bin.cmd`：用`arm-linux-gnueabihf-objcopy`将ELF格式`u-boot`转为二进制`u-boot-nodtb.bin`
  - `.u-boot.cmd`：用`arm-linux-gnueabihf-ld`链接各`built-in.o`生成ELF格式`u-boot`
  - `.u-boot.imx.cmd`：用`tools/mkimage`工具，结合`imximage.cfg`，为`u-boot.bin`添加NXP专属头部，生成`u-boot.imx`（用于NXP芯片启动）

### 4. `u-boot.xxx`：编译输出镜像
| 文件 | 格式/用途 |
|------|-----------|
| `u-boot` | ELF格式，包含调试信息，用于调试分析 |
| `u-boot.bin` | 纯二进制可执行文件，通用uboot镜像 |
| `u-boot.imx` | NXP专用镜像，含启动头部信息，用于I.MX6ULL芯片启动 |
| `u-boot.lds` | 链接脚本，定义代码/数据段的内存布局 |
| `u-boot.map` | 符号映射表，可查看函数/变量的链接地址 |

---

## 四、目录结构与移植/分析的关联
### 1. 移植时的核心修改点
- `configs/`：新增`xxx_defconfig`（复制官方模板并修改）
- `include/configs/`：新增开发板头文件（`xxx.h`，配置uboot功能）
- `board/freescale/xxx/`：新增板级文件夹（复制官方模板，修改驱动、初始化代码）
- `arch/arm/cpu/armv7/mx6/Kconfig`：添加新开发板的配置选项，使其能被`make menuconfig`识别

### 2. 启动流程分析的核心路径
- 启动入口：`arch/arm/cpu/armv7/start.S`（汇编入口）
- 架构初始化：`arch/arm/cpu/armv7/`下的相关文件
- 板级初始化：`board/freescale/mx6ull_alientek_emmc/mx6ull_alientek_emmc.c`（`board_init_f`/`board_init_r`等函数）
- 链接布局：`arch/arm/cpu/u-boot.lds`（根目录`u-boot.lds`的来源）

---

## 五、总结
U-Boot目录结构遵循**“架构-平台-板级”**分层设计：
1. **`arch`** 负责CPU架构通用底层代码
2. **`board`** 负责具体开发板的定制驱动与初始化
3. **`configs` + `.config`** 负责功能配置与裁剪
4. 编译产物（`.u-boot.xxx.cmd`、`u-boot.xxx`）清晰展示了从源码到可执行镜像的生成过程

这种结构既保证了跨平台兼容性，又为特定开发板的移植提供了便捷的扩展入口，是分析uboot启动流程、驱动移植的核心框架。

---

如果你需要，我可以帮你整理一份**U-Boot启动流程与目录对应关系表**，把每个启动阶段对应的源码文件和目录都标出来，方便你后续深入分析。需要吗？




# U-Boot 移植到正点原子I.MX6ULL开发板笔记
## 一、移植前提
正点原子I.MX6ULL开发板参考NXP官方I.MX6ULL EVK开发板硬件设计，因此以NXP官方uboot（版本：uboot-imx-rel_imx_4.1.15_2.1.0_ga）为蓝本，移植到正点原子EMMC版本开发板（NAND版本流程类似）。

## 二、前期准备：编译测试NXP官方uboot
### 1. 解压官方uboot源码
将NXP官方uboot包`uboot-imx-rel_imx_4.1.15_2.1.0_ga.tar.bz2`发送到Ubuntu并解压，创建VSCode工程。

### 2. 编译官方EVK开发板uboot
#### （1）直接编译（临时方式）
```bash
# 配置默认配置文件（EMMC版本）
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- mx6ull_14x14_evk_emmc_defconfig
# 编译，-j16根据CPU核心数调整
make V=1 ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j16
```

#### （2）简化编译（可选）
- 方式1：修改顶层Makefile，直接赋值ARCH和CROSS_COMPILE（250、251行）：
  ```makefile
  ARCH ?= arm
  CROSS_COMPILE ?= arm-linux-gnueabihf-
  ```
  简化编译命令：
  ```bash
  make mx6ull_14x14_evk_emmc_defconfig
  make V=1 -j16
  ```
- 方式2：创建编译脚本`mx6ull_14x14_emmc.sh`：
  ```bash
  #!/bin/bash
  make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- distclean
  make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- mx6ull_14x14_evk_emmc_defconfig
  make V=1 ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j16
  ```
  赋予执行权限并运行：
  ```bash
  chmod 777 mx6ull_14x14_emmc.sh
  ./mx6ull_14x14_emmc.sh
  ```

### 3. 烧写验证官方uboot
```bash
# 拷贝imxdownload工具到uboot根目录，赋予执行权限
chmod 777 imxdownload
# 烧写u-boot.bin到SD卡（/dev/sdd为SD卡设备，需替换）
./imxdownload u-boot.bin /dev/sdd
```
将SD卡插入开发板，设置SD卡启动，验证：
- uboot能正常启动，DRAM识别为512MB（EMMC版本）；
- SD卡/EMMC驱动：`mmc list`、`mmc dev 0/1`+`mmc info`验证；
- LCD：默认4.3寸480x272屏可显示NXP logo，其他屏需后续修改；
- 网络：提示“Board Net Initialization Failed”，需后续修改。

## 三、添加自定义开发板（正点原子I.MX6ULL EMMC）
### 1. 添加默认配置文件
```bash
cd configs
cp mx6ull_14x14_evk_emmc_defconfig mx6ull_alientek_emmc_defconfig
```
修改`mx6ull_alientek_emmc_defconfig`内容：
```config
CONFIG_SYS_EXTRA_OPTIONS="IMX_CONFIG=board/freescale/mx6ull_alientek_emmc/imximage.cfg,MX6ULL_EVK_EMMC_REWORK"
CONFIG_ARM=y
CONFIG_ARCH_MX6=y
CONFIG_TARGET_MX6ULL_ALIENTEK_EMMC=y
CONFIG_CMD_GPIO=y
```

### 2. 添加开发板头文件
```bash
cp include/configs/mx6ullevk.h include/configs/mx6ull_alientek_emmc.h
```
修改头文件开头宏定义：
```c
#ifndef __MX6ULL_ALIENTEK_EMMC_CONFIG_H
#define __MX6ULL_ALIENTEK_EMMC_CONFIG_H
```
该文件核心是通过`CONFIG_`宏配置uboot功能（如串口、DRAM、MMC、网络、LCD等），需保留核心配置（如DRAM=512MB、串口1、MMC数量=2等）。

### 3. 添加板级文件夹
```bash
# 复制官方板级文件夹并改名
cd board/freescale/
cp mx6ullevk/ -r mx6ull_alientek_emmc
cd mx6ull_alientek_emmc
# 重命名核心板级文件
mv mx6ullevk.c mx6ull_alientek_emmc.c
```
修改文件夹内4个文件：
#### （1）Makefile
```makefile
# (C) Copyright 2015 Freescale Semiconductor, Inc.
#
# SPDX-License-Identifier: GPL-2.0+
#
obj-y := mx6ull_alientek_emmc.o

extra-$(CONFIG_USE_PLUGIN) := plugin.bin
$(obj)/plugin.bin: $(obj)/plugin.o
	$(OBJCOPY) -O binary --gap-fill 0xff $< $@
```

#### （2）imximage.cfg
修改PLUGIN路径：
```
PLUGIN board/freescale/mx6ull_alientek_emmc/plugin.bin 0x00907000
```

#### （3）Kconfig
```kconfig
if TARGET_MX6ULL_ALIENTEK_EMMC

config SYS_BOARD
	default "mx6ull_alientek_emmc"

config SYS_VENDOR
	default "freescale"

config SYS_SOC
	default "mx6"

config SYS_CONFIG_NAME
	default "mx6ull_alientek_emmc"

endif
```

#### （4）MAINTAINERS
```
MX6ULL_ALIENTEK_EMMC BOARD
M: Peng Fan <peng.fan@nxp.com>
S: Maintained
F: board/freescale/mx6ull_alientek_emmc/
F: include/configs/mx6ull_alientek_emmc.h
```

### 4. 修改图形界面配置文件
编辑`arch/arm/cpu/armv7/mx6/Kconfig`：
- 在207行添加：
  ```kconfig
  config TARGET_MX6ULL_ALIENTEK_EMMC
  	bool "Support mx6ull_alientek_emmc"
  	select MX6ULL
  	select DM
  	select DM_THERMAL
  ```
- 在最后一行`endif`前添加：
  ```kconfig
  source "board/freescale/mx6ull_alientek_emmc/Kconfig"
  ```

### 5. 编译自定义uboot
创建编译脚本`mx6ull_alientek_emmc.sh`：
```bash
#!/bin/bash
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- distclean
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- mx6ull_alientek_emmc_defconfig
make V=1 ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j16
```
赋予权限并编译：
```bash
chmod 777 mx6ull_alientek_emmc.sh
./mx6ull_alientek_emmc.sh
```
验证头文件引用：
```bash
grep -nR "mx6ull_alientek_emmc.h"
```
烧写测试：uboot可启动，但LCD/网络仍异常，需后续修改。

## 四、驱动修改
### 1. LCD驱动修改
#### （1）核心修改点
- IO配置：正点原子LCD IO与官方一致，无需修改；
- LCD参数：修改`mx6ull_alientek_emmc.c`中`displays`结构体（以7寸1024x600屏ATK7016为例）：
  ```c
  struct display_info_t const displays[] = {{
      .bus = MX6UL_LCDIF1_BASE_ADDR,
      .addr = 0,
      .pixfmt = 24,
      .detect = NULL,
      .enable = do_enable_parallel_lcd,
      .mode = {
          .name = "TFT7016",
          .xres = 1024,
          .yres = 600,
          .pixclock = 19531,  // 像素时钟=1/51.2MHz*10^12=19531皮秒
          .left_margin = 140,  // HBPD
          .right_margin = 160, // HFPD
          .upper_margin = 20,  // VBPD
          .lower_margin = 12,  // VFBD
          .hsync_len = 20,     // HSPW
          .vsync_len = 3,      // VSPW
          .sync = 0,
          .vmode = FB_VMODE_NONINTERLACED
      } } };
  ```
- 环境变量panel：修改`mx6ull_alientek_emmc.h`中所有`panel=TFT43AB`为`panel=TFT7016`。

#### （2）生效环境变量
烧写修改后的uboot，若LCD仍黑屏，在uboot命令行执行：
```bash
setenv panel TFT7016
saveenv
reset
```

### 2. 网络驱动修改（核心问题：复位引脚不一致）
#### （1）修改板级文件`mx6ull_alientek_emmc.c`
添加网络PHY复位引脚配置（正点原子网络芯片复位引脚与官方不同），核心步骤：
1. 定义复位引脚GPIO；
2. 在`board_early_init_f`函数中初始化复位引脚，并拉低/拉高完成复位；
3. 确认`mx6ull_alientek_emmc.h`中网络配置：
   ```c
   #define CONFIG_FEC_ENET_DEV 1  // 使用ENET2
   #define IMX_FEC_BASE ENET2_BASE_ADDR
   #define CONFIG_FEC_MXC_PHYADDR 0x1
   #define CONFIG_FEC_XCV_TYPE RMII
   ```

#### （2）验证网络
烧写后，uboot启动无网络错误提示，可通过`ping`命令验证与Ubuntu主机连通性。

## 五、最终验证
1. 烧写修改后的uboot到SD卡/EMMC；
2. 启动开发板，验证：
   - uboot正常启动，DRAM识别正确；
   - SD卡/EMMC驱动正常（`mmc`命令）；
   - LCD显示NXP logo（对应分辨率）；
   - 网络可ping通Ubuntu主机；
   - 其他外设（如USB、I2C）按需验证。

### 总结
1. U-Boot移植核心是**参考原厂开发板，添加自定义板级文件+修改适配驱动**，核心文件包括默认配置文件、板级头文件、板级文件夹；
2. 编译前需确认交叉编译器、ARCH等环境变量，可通过修改Makefile或脚本简化编译；
3. 驱动修改重点：LCD需匹配屏幕参数+环境变量，网络需修正PHY复位引脚+配置参数。


# U-Boot移植到正点原子I.MX6ULL（EMMC版）**所有修改位置汇总**
以NXP官方`uboot-imx-rel_imx_4.1.15_2.1.0_ga`为基础，按**添加自定义板文件、修改配置、驱动适配**分类，精准标注文件路径+修改内容，无冗余步骤。

## 一、添加自定义开发板核心文件（新建/拷贝重命名+修改）
### 1. 配置文件：`configs/mx6ull_alientek_emmc_defconfig`
- **操作**：拷贝`mx6ull_14x14_evk_emmc_defconfig`并重命名
- **修改**：
  1. `CONFIG_SYS_EXTRA_OPTIONS`中路径改为`board/freescale/mx6ull_alientek_emmc/imximage.cfg`
  2. `CONFIG_TARGET_MX6ULL_14X14_EVK_EMMC`改为`CONFIG_TARGET_MX6ULL_ALIENTEK_EMMC`

### 2. 板级头文件：`include/configs/mx6ull_alientek_emmc.h`
- **操作**：拷贝`mx6ullevk.h`并重命名
- **修改**：
  1. 开头保护宏：`__MX6ULLEVK_CONFIG_H` → `__MX6ULL_ALIENTEK_EMMC_CONFIG_H`
  2. 后续LCD/网络适配需在此文件补充（见下文）

### 3. 板级文件夹：`board/freescale/mx6ull_alientek_emmc/`
- **操作**：拷贝`mx6ullevk/`文件夹并重命名，进入该文件夹后将`mx6ullevk.c` → `mx6ull_alientek_emmc.c`
- **子文件修改（共4个）**：
  | 文件名         | 核心修改点                                                                 |
  |----------------|--------------------------------------------------------------------------|
  | `Makefile`     | `obj-y := mx6ullevk.o` → `obj-y := mx6ull_alientek_emmc.o`                |
  | `imximage.cfg` | `PLUGIN`路径改为`board/freescale/mx6ull_alientek_emmc/plugin.bin 0x00907000` |
  | `Kconfig`      | 所有`mx6ull_14x14_evk`相关改为`mx6ull_alientek_emmc`，匹配`TARGET_XXX`宏   |
  | `MAINTAINERS`  | 路径改为`board/freescale/mx6ull_alientek_emmc/`和`include/configs/mx6ull_alientek_emmc.h` |

### 4. 图形配置Kconfig：`arch/arm/cpu/armv7/mx6/Kconfig`
- **修改1**：在MX6ULL相关配置段添加自定义板配置：
  ```kconfig
  config TARGET_MX6ULL_ALIENTEK_EMMC
      bool "Support mx6ull_alientek_emmc"
      select MX6ULL
      select DM
      select DM_THERMAL
  ```
- **修改2**：在文件最后一行`endif`**前**添加板级Kconfig引用：
  ```kconfig
  source "board/freescale/mx6ull_alientek_emmc/Kconfig"
  ```

## 二、编译简化修改（可选，非必须，仅提升效率）
### 顶层Makefile：`Makefile`（250、251行）
- **修改**：直接赋值交叉编译工具链，避免每次编译输入参数
  ```makefile
  ARCH ?= arm
  CROSS_COMPILE ?= arm-linux-gnueabihf-
  ```

## 三、LCD驱动适配修改（必改，匹配正点原子屏幕）
### 1. 板级C文件：`board/freescale/mx6ull_alientek_emmc/mx6ull_alientek_emmc.c`
- **修改**：找到`displays`结构体（LCD参数），替换为对应屏幕参数（以7寸1024*600为例）：
  ```c
  struct display_info_t const displays[] = {{
      .bus = MX6UL_LCDIF1_BASE_ADDR,
      .addr = 0,
      .pixfmt = 24,
      .detect = NULL,
      .enable = do_enable_parallel_lcd,
      .mode = {
          .name = "TFT7016",  // 屏幕名称，需与panel环境变量一致
          .xres = 1024, .yres = 600,  // 分辨率
          .pixclock = 19531,  // 像素时钟（皮秒），51.2MHz对应19531
          .left_margin = 140, .right_margin = 160,  // HBPD、HFPD
          .upper_margin = 20, .lower_margin = 12,    // VBPD、VFBD
          .hsync_len = 20, .vsync_len = 3,          // HSPW、VSPW
          .sync = 0, .vmode = FB_VMODE_NONINTERLACED
      } } };
  ```

### 2. 板级头文件：`include/configs/mx6ull_alientek_emmc.h`
- **修改**：全局替换所有`panel=TFT43AB` → `panel=TFT7016`（与上述屏幕名称一致）

## 四、环境变量生效修改（烧写后板级操作，非源码修改）
若修改LCD后屏幕黑屏，烧写新uboot后在**uboot命令行**执行（必做）：
```bash
setenv panel TFT7016  # 与源码中屏幕name一致
saveenv              # 保存环境变量到EMMC/SD卡
reset                # 重启开发板，LCD生效
```

## 关键备注
1. 所有修改均基于**EMMC版本**，NAND版本仅需将上述`emmc`替换为`nand`，并调整DRAM大小（256MB）、MMC数量等配置；
2. 板级文件夹、配置文件、头文件的**命名需完全一致**（如`mx6ull_alientek_emmc`），避免编译时找不到文件；
3. 网络复位引脚需以**正点原子I.MX6ULL硬件原理图**为准，上述仅为示例；
4. 编译前需执行`distclean`清理工程，避免旧配置干扰。



# U-Boot 图形化配置（menuconfig）
## 一、配置前准备
### 1. 依赖安装
menuconfig 基于 `ncurses` 库实现文本图形界面，需先安装依赖：
```bash
sudo apt-get install build-essential  # 基础编译工具（可选，确保编译环境完整）
sudo apt-get install libncurses5-dev  # ncurses 核心库（必装）
```

### 2. 预配置（关键前提）
打开图形化界面前，需先加载开发板默认配置（仅需执行一次，`make clean` 后需重新执行）：
```bash
# 完整命令（未修改顶层Makefile时）
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- mx6ull_alientek_emmc_defconfig

# 简化命令（已在顶层Makefile定义ARCH和CROSS_COMPILE）
make mx6ull_alientek_emmc_defconfig
```

## 二、打开图形化配置界面
```bash
# 完整命令
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- menuconfig

# 简化命令
make menuconfig
```

## 三、核心操作规则
### 1. 基础导航
| 操作 | 功能 |
|------|------|
| ↑/↓ 键 | 选择菜单选项 |
| Enter 键 | 进入子菜单（带`--->`的选项）/确认选中 |
| 热键（菜单高亮字母） | 快速选中对应菜单 |
| Y 键 | 编译功能进U-Boot（选项前变为`[*]`/`<*>`） |
| N 键 | 不编译该功能（选项前为`[]`） |
| M 键 | 编译为模块（U-Boot中极少用，Linux内核常用，选项前变为`<M>`） |
| 两下Esc键 | 退出当前菜单/返回上一级 |
| ?/H 键 | 查看选中选项的帮助信息 |
| / 键 | 打开搜索框，搜索配置项 |

### 2. 界面底部按钮功能
| 按钮 | 功能 | 等效操作 |
|------|------|----------|
| <Select> | 选中菜单/进入子菜单 | Enter键 |
| <Exit> | 退出当前菜单 | 两下Esc键 |
| <Help> | 查看帮助信息 | ?/H键 |
| <Save> | 保存修改后的配置 | 退出时确认保存 |
| <Load> | 加载指定配置文件 | - |

## 四、实操示例：使能DNS命令
### 1. 配置步骤
1. 进入主界面 → 选中`Command line interface --->`（命令行接口配置）；
2. 进入子菜单 → 选中`Network commands --->`（网络命令配置）；
3. 找到`dns`选项 → 按Y键（选项前变为`[*]`）；
4. 多次按两下Esc键返回主界面 → 退出时选择“Yes”保存配置；
5. 查看`.config`文件，新增`CONFIG_CMD_DNS=y`（配置生效）。

### 2. 编译与验证
#### 编译（⚠️ 禁止用清理工程的shell脚本）
```bash
# 直接编译，保留修改后的.config文件
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j16
```
#### 验证（开发板端）
1. 烧写新编译的`u-boot.imx`到SD卡，启动进入U-Boot命令行；
2. 设置DNS服务器IP（需开发板连路由器通外网）：
   ```bash
   setenv dnsip 114.114.114.114  # 国内通用DNS
   saveenv                       # 保存环境变量
   ```
3. 执行DNS命令测试：
   ```bash
   dns www.baidu.com  # 输出百度IP，说明功能生效
   ```

## 五、关键注意事项
1. **配置优先级**：直接在板级头文件（如`mx6ull_alientek_emmc.h`）定义的宏（如`CONFIG_CMD_PING`），不会在menuconfig界面显示为`[*]`，但实际会编译进U-Boot（menuconfig仅读取`.config`文件）；
2. **编译避坑**：修改配置后，禁止执行带`distclean`的编译脚本（如`mx6ull_alientek_emmc.sh`），否则会删除`.config`，配置修改失效；
3. **网络验证前提**：开发板需连接到能访问外网的路由器（直连电脑无法解析外网域名）。

## 六、总结
1. U-Boot图形化配置核心依赖`.config`（配置存储）和`Kconfig`（界面描述），通过menuconfig可可视化裁剪/新增功能；
2. 操作核心是“选菜单→设Y/N→保存→编译”，需注意避免清理工程导致配置丢失；
3. 图形化配置无需手动找配置宏，是U-Boot功能裁剪的便捷方式，且仅影响U-Boot本身，与Linux内核无关。