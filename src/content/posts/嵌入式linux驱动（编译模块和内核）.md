---
title: 嵌入式linux驱动（编译模块和内核）
published: 2026-07-08
pinned: false
description: 编译模块和内核
tags: [liunx,驱动]
category: 嵌入式
draft: false
---  


## 一、Linux驱动模块基础（Hello World示例）  
### 1. 驱动模块代码框架  
以“Hello World”驱动为例，核心代码结构如下：  

```c
#include <linux/init.h>   // 初始化/退出函数声明
#include <linux/module.h> // 模块相关宏（module_init/module_exit等）

// 模块初始化函数（insmod时调用）
static int hello_init(void) {
    printk("hello world \n"); // 内核打印（非用户空间printf）
    return 0; // 成功返回0，失败返回非0
}

// 模块退出函数（rmmod时调用）
static void hello_exit(void) {
    printk("byb byb \n");
}

// 注册初始化/退出函数
module_init(hello_init);  
module_exit(hello_exit);  

// 模块许可证（必须为GPL，否则insmod会报错）
MODULE_LICENSE("GPL");  
```  

### 2. 编译驱动模块（Makefile）  
驱动模块需通过`Makefile`编译，典型`Makefile`如下：  

```makefile
obj-m += helloworld.o  # 生成helloworld.ko模块（m表示模块，-m编译为模块）
KDIR:=/home/topeet/topeet/imx6ull/linux-tmx-rel_imx_4.1.15_2.0.0_ga  # 内核源码路径
PWD:=$(shell pwd)      # 当前目录（驱动源码所在路径）

all:
	make -C $(KDIR) M=$(PWD) modules  # 调用内核make，编译模块
```  

**编译依赖前提**：  
- 内核源码需**先编译通过**（确保`.config`、头文件等准备就绪）；  
- 编译驱动的内核源码，必须与**开发板运行的内核镜像一致**（否则insmod会因版本不匹配失败）；  
- Ubuntu环境需支持`arm`交叉编译（若开发板是ARM架构，需安装`arm-linux-gnueabihf-*`工具链）。  

### 3、驱动加载与卸载  
编译生成`.ko`后，通过以下命令操作：  
- 加载：`insmod helloworld.ko`（执行`hello_init`）；  
- 查看：`lsmod`（列出已加载模块）；  
- 卸载：`rmmod helloworld`（执行`hello_exit`）；  
- 内核打印查看：`dmesg`（查看`printk`输出）。


## 二、内核配置：`make menuconfig`  
### 1. 进入`menuconfig`图形界面  
进入**内核源码根目录**，执行命令：  
```bash
make menuconfig
```  

### 2. `menuconfig`操作技巧  
- **搜索功能**：按 `/` 键，输入关键词（如“LED”），快速定位配置项；  
- **配置驱动状态**：按 `空格` 切换三种状态：  
  - `<*>`：编译进内核（开机自动加载）；  
  - `<M>`：编译为模块（需`insmod`手动加载）；  
  - `< >`：不编译；  
- **退出方式**：  
  - 保存退出：选 `<Yes>`（会更新`.config`）；  
  - 不保存退出：选 `<No>`（`.config`不变）。  


### 3. 与`menuconfig`相关的文件  
| 文件       | 作用                                                                 | 类比               |  
|------------|----------------------------------------------------------------------|--------------------|  
| `Makefile` | 编译规则，定义“如何编译”（如`obj-m += xxx.o`）                       | 菜谱               |  
| `Kconfig`  | 内核配置选项（菜单结构、依赖关系）                                   | 饭店菜单           |  
| `.config`  | 编译后生成的配置（记录“选了哪些菜”）                                 | 已点的菜           |  


### 4. `menuconfig`读取的`Kconfig`路径  
默认从 `Arch/$ARCH/Kconfig` 开始（`$ARCH`为架构，如`arm`），再递归包含子目录的`Kconfig`。  
- 例：ARM架构下，会从 `arch/arm/Kconfig` 启动，包含`drivers/`、`fs/`等子目录的`Kconfig`；  
- 自定义驱动的`Kconfig`可放在驱动目录（如`drivers/redled/Kconfig`），通过`source "drivers/redled/Kconfig"`被主`Kconfig`包含。  


### 5. `Kconfig`语法（以LED驱动为例）  
```kconfig
source "drivers/redled/Kconfig"  # 包含子目录的Kconfig

config LED__4412                 # 配置项名称（最终宏为CONFIG_LED__4412）
    tristate "Led Support for GPIO Led"  # 三态（*、M、空）
    depends on LEDS_CLASS          # 依赖：只有选了LEDS_CLASS，才能选LED__4412
    help                          # 帮助信息
      This option enable support for led
```  

#### 关键语法说明：  
- `tristate`：支持`<*>`（内核）、`<M>`（模块）、`< >`（不编译）；  
- `bool`：仅支持`<*>`（内核）、`< >`（不编译）；  
- `depends on`：**正向依赖**（选A的前提是选B）；  
- `select`：**反向依赖**（选A时，自动选B）；  
- `help`：配置项的说明文字（编译后可在`include/generated/autoconf.h`中看到宏定义）。  


### 6. 配置的“落地”：`autoconf.h`  
`make menuconfig`保存退出后，内核会生成 `include/generated/autoconf.h`，将配置项以**宏定义**形式记录（如`#define CONFIG_LED__4412_M 1`）。  
驱动代码中可通过 `#ifdef CONFIG_XXX` 判断是否编译某段代码。  


## 三、Linux内核添加新驱动全流程


> **目标**：添加 `drivers/hello/` 驱动，并将最终配置固化到编译脚本中。


### 第一步：创建驱动源文件
**动作**：编写具体的驱动逻辑。

```c
// File: drivers/hello/hello.c
#include <linux/module.h>
#include <linux/init.h>

static int __init hello_init(void)
{
    printk(KERN_INFO "hello driver init\n");
    return 0;
}

static void __exit hello_exit(void)
{
    printk(KERN_INFO "hello driver exit\n");
}

module_init(hello_init);
module_exit(hello_exit);
MODULE_LICENSE("GPL");
```

---

### 第二步：编写子目录 Makefile
**动作**：告诉编译系统**如何编译**这个文件。
**关键点**：使用 `$(CONFIG_HELLO)` 进行条件编译。

```makefile
# File: drivers/hello/Makefile
# 如果 .config 中 CONFIG_HELLO=y 或 =m，则编译 hello.o
obj-$(CONFIG_HELLO) += hello.o
```

---

### 第三步：编写子目录 Kconfig
**动作**：告诉编译系统**有哪些配置选项**（供 `menuconfig` 显示）。

```kconfig
# File: drivers/hello/Kconfig
config HELLO
    tristate "Hello Driver support" # tristate 表示支持 Y / M / N
    help
      This is a basic hello world driver for testing.
```

---

### 第四步：修改上级 Makefile
**动作**：告诉编译系统**去哪里找**子目录的代码。
**关键点**：使用 `obj-y`（无条件进入目录），具体编不编由子目录 Makefile 决定。

```makefile
# File: drivers/Makefile (在末尾添加)
# 强制进入 hello 目录
obj-y += hello/
```

---

### 第五步：修改上级 Kconfig
**动作**：将子菜单挂载到内核配置树中，使其能在 `menuconfig` 中被看到。

```kconfig
# File: drivers/Kconfig (在末尾添加)
source "drivers/hello/Kconfig"
```

---

### 第六步：生成基础配置（打地基）
**动作**：加载板级默认配置，确保内核能跑起来。
**原因**：`imx_v7_defconfig` 包含了 SoC、串口、内存等必需配置，比从零开始 `menuconfig` 高效且不易出错。

```bash
# 在内核根目录执行
make imx_v7_defconfig
```

---

### 第七步：开启新驱动（装修）
**动作**：在基础配置上，勾选刚才添加的 `HELLO` 驱动。

```bash
make menuconfig
```
**操作路径**：
```
Device Drivers  --->
    [*] Hello Driver support  (选择 M 编译成模块，或 * 编译进内核)
```
**保存退出**，此时当前目录生成了包含 `CONFIG_HELLO=m` 的 `.config` 文件。

---

### 第八步：导出最终配置
**动作**：备份经过验证的 `.config`，作为后续编译的蓝本。

```bash
cp .config config_hello_ok
```

---

### 第九步：编写/修改内核编译脚本
**动作**：将新配置固化到自动化编译流程中。
**关键点**：必须先 `cp` 替换配置，再执行 `make oldconfig` 同步依赖关系。

```bash
#!/bin/bash
# File: build_kernel.sh

KERNEL_DIR="/home/user/linux-imx"
CONFIG_FILE="config_hello_ok"

# 1. 将新配置放入内核源码目录
cp ${CONFIG_FILE} ${KERNEL_DIR}/.config

# 2. 同步依赖（非常重要！处理新增的 Kconfig 选项）
make -C ${KERNEL_DIR} ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- oldconfig

# 3. 开始编译
make -C ${KERNEL_DIR} ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j4 modules

# 4. 验证结果
ls ${KERNEL_DIR}/drivers/hello/hello.ko
```



## 四、扩展：驱动编译的“坑”与解决思路  
1. **内核版本不匹配**：  
   - 现象：`insmod`时报`version mismatch`；  
   - 解决：确保编译驱动的内核源码，与开发板运行的`zImage/uImage`是**同一套**（内核版本、配置完全一致）。  

2. **交叉编译环境**：  
   - 若开发板是ARM（如IMX6ULL），Ubuntu需安装`arm-linux-gnueabihf-`工具链，并在`Makefile`中指定`CROSS_COMPILE=arm-linux-gnueabihf-`；  
   - 例：`make CROSS_COMPILE=arm-linux-gnueabihf- -C $(KDIR) M=$(PWD) modules`。  

3. **直接修改`.config`的风险**：  
   - 图中提到“想去掉LED相关，直接改`.config`可以吗？可以，但不推荐”；  
   - 原因：`.config`依赖`Kconfig`的联动逻辑，直接修改可能破坏依赖关系；  
   - 推荐：通过`make menuconfig`交互式修改。  


## 五、总结流程  
1. 准备**内核源码**（编译通过，与开发板内核一致）；  
2. 编写**驱动代码**（如`helloworld.c`）；  
3. 编写**Makefile**（指定内核源码路径、编译模块）；  
4. （可选）通过`make menuconfig`配置内核（决定驱动是否编译/如何编译）；  
5. 编译驱动：`make`（生成`.ko`）；  
6. 加载/测试：`insmod`/`rmmod` + `dmesg`验证。  


## 六、在正点原子RK3588上的实践

- 为什么 SDK 和教程不一样

教程是**直接操作内核源码树**的通用 Linux 流程。你的 RK3588 SDK 在它之上加了一层 **Rockchip 构建封装**，通过 `./build.sh kernel` 统一管理。

但两者**底层完全打通**——内核源码的 Kconfig、Makefile、`.config` 机制是一模一样的。区别仅在于**配置文件的存放位置和流程**：

| 对比项 | 通用教程 | 你的 RK3588 SDK |
|--------|----------|-----------------|
| 编译命令 | `make ARCH=arm ...` | `./build.sh kernel` |
| 基础配置 | `xxx_defconfig` | `rockchip_linux_defconfig` |
| 覆盖配置 | 手动 `cp .config` | **config fragment**：`rk3588_linux.config` |
| 启用新驱动 | 手动 `cp .config` 备份 | **追加到 fragment 文件** 中固化 |

从你之前编译的输出可以看到：
```
Using .config as base
Merging ./arch/arm64/configs/rk3588_linux.config
```

SDK 的流程是：`rockchip_linux_defconfig`（基础）+ `rk3588_linux.config`（增量覆盖）→ 合并出最终 `.config`。

---

## 在你的 SDK 中添加 hello 驱动的完整流程

### 第1~5步：创建驱动文件（和教程完全一样）

这些步骤**直接在内核源码树** `kernel/` 目录下操作，不涉及 SDK 构建系统：

```bash
# 1. 创建驱动源码
mkdir -p kernel/drivers/hello
# 写入 kernel/drivers/hello/hello.c 和 Makefile

# 2. 写入 kernel/drivers/hello/Kconfig

# 3. 修改 kernel/drivers/Makefile：末尾加一行
echo 'obj-y += hello/' >> kernel/drivers/Makefile

# 4. 修改 kernel/drivers/Kconfig：末尾加一行
echo 'source "drivers/hello/Kconfig"' >> kernel/drivers/Kconfig
```

### 第6~8步：配置和固化（和你 SDK 的做法不同！）

这是最关键的区别。你**不需要**手动 `cp .config`，而是用 fragment 机制：

```bash
# 步骤A：生成基础配置
cd kernel/
make ARCH=arm64 rockchip_linux_defconfig

# 步骤B：合并现有 fragment
scripts/kconfig/merge_config.sh .config arch/arm64/configs/rk3588_linux.config

# 步骤C：用 menuconfig 开启 HELLO 驱动
make ARCH=arm64 menuconfig
# 路径：Device Drivers → Hello Driver support → 选 M 或 *

# 步骤D：将新增的 HELLO 配置导出到 fragment 文件
#         只提取 .config 中比 defconfig 多出来的 HELLO 相关项
grep "CONFIG_HELLO" .config >> arch/arm64/configs/rk3588_linux.config
```

### 第9步：编译

之后每次 `./build.sh kernel` 都会自动 merge fragment，包含 `CONFIG_HELLO`：

```bash
cd /home/huangzy/RK3588
./build.sh kernel
```

---

## 总结：你 SDK 的核心口诀

> **源码修改**（Kconfig、Makefile、.c）→ 在 `kernel/` 下操作，和通用教程一样  
> **配置固化** → 追加到 `kernel/arch/arm64/configs/rk3588_linux.config`，而不是备份 `.config`  
> **编译** → 回到 SDK 根目录，`./build.sh kernel`