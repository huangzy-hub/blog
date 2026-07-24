---
title: lvgl的移植
published: 2026-03-11
pinned: false
description: 给全志a133开发板移植lvgl项目，移植v8和v9的区别。
tags: [记录,liunx, lvgl]
category: 嵌入式
draft: false
---


# lvgl的移植
官方例程在乌班图编译不通过，官方例程在开发板上也编译不通过，ai修改cmake文件半天未果，原因是不会移植lv_port_liunx。

网上找的一直移植lvgl版本也不一样，或者没有教具体怎么移植，韦东山的lv9简称需要使用他提供的虚拟机、开发板和镜像，我没有同款开发板，并且有一部分教程是收费的。

后来试图从网上拉取移植好的项目，毕竟应用开发对环境的要求比较低。

在b站找到项目https://github.com/yicen-tech/lvgl_car.git
在乌班图24上编译显示没有sdl工具，试图用命令行下载，只能下载到x86的，下载不到arm的。试图直接在开发板上编译，项目中有不部分代码语法与开发板乌班图16操作系统不匹配，此开发板的官方镜像只有16，项目比较复杂我也不会改，方案卒。

在gitee找到项目https://gitee.com/chonglinzhu/intelligent_shopping_terminal
修改交叉编译器后再电脑编译，编译成功，上传开发板却无法运行，检查发现：
demo 依赖 armhf 硬浮点链接器：
我的编译器是 arm-linux-gnueabihf-gcc（硬浮点），编译出的 demo 要求动态链接器 /lib/ld-linux-armhf.so.3。
但我的开发板（aarch64）只提供了软浮点兼容的 /lib/ld-linux.so.3，找不到 armhf 版本，所以报错 No such file or directory。
framebuffer_test 依赖通用软浮点链接器：
它虽然也是 32 位 ARM，但动态链接器是 /lib/ld-linux.so.3，这是开发板系统自带的 32 位兼容链接器，所以能正常运行。

## 解决方案
### 方案 1：让 demo 也使用开发板兼容的链接器（推荐）
在你的 Makefile 中添加链接参数，强制使用开发板兼容的软浮点链接器：
```makefile
# 在 LDFLAGS 后添加 --dynamic-linker
LDFLAGS ?= -lm -Wl,--dynamic-linker=/lib/ld-linux.so.3
```
然后重新编译：
```bash
make clean && make -j$(nproc)
```
新编译的 demo 会和 framebuffer_test 一样，使用 /lib/ld-linux.so.3，即可在开发板正常运行。

### 方案 2：在开发板安装 armhf 兼容库（临时方案）
在开发板终端执行：
```bash
dpkg --add-architecture armhf
apt update
apt install -y libc6:armhf
```
安装后，系统会自动创建 /lib/ld-linux-armhf.so.3，demo 也能直接运行。

### 方案 3：彻底解决：编译为 64 位 aarch64 版本
如果你的开发板是 aarch64，最根本的方法是用 64 位编译器重新编译：
```bash
# 安装 64 位编译器
sudo apt install -y gcc-aarch64-linux-gnu
# 修改 Makefile 编译器
CC = aarch64-linux-gnu-gcc
# 重新编译
make clean && make -j$(nproc)
```
生成的 64 位 demo 会直接匹配开发板架构，无需任何兼容库。

## 选择方案一
运行后：
从 file demo 输出可以看到：

```plaintext
interpreter /lib/ld-linux.so.3
```

链接器已经成功修改，和能正常运行的 framebuffer_test 完全一致。
但运行时仍报错找不到 ld-linux-armhf.so.3，这说明：
程序本身的链接器配置是对的。
但它依赖的 其他共享库（如 libc、libm 等）仍然是 armhf 版本，这些库在你的 aarch64 开发板上不存在，所以系统在加载时仍会尝试寻找对应的 armhf 链接器。

## 解决方法：
静态编译，LDFLAGS ?= -lm -static -Wl,--dynamic-linker=/lib/ld-linux.so.3

上传开发板，终于屏幕上显示画面了（开发板直接编译也行）。

但是：
触摸，没反应；点击屏幕会被桌面覆盖

解决：
找到触摸事件输入节点event5，临时关闭桌面
```bash
systemctl stop lightdm
```

至此，一个lvgl项目终于可以在我的开发板上运行了！

接下来分析make和config.h，学会移植，并加上自己的代码。


## 关于软硬浮点链接器

1. **编译器与浮点模式绑定**：你用`arm-linux-gnueabihf-gcc`（ARM32硬浮点编译器），编译出的程序「默认要求硬浮点运行环境」；
2. **架构兼容但浮点模式不兼容**：你的开发板是aarch64（64位），能兼容运行32位ARM程序，但系统只预装了「ARM32软浮点」的库/链接器（`/lib/ld-linux.so.3`），没有「ARM32硬浮点」的库/链接器（`/lib/ld-linux-armhf.so.3`）；
3. **最终冲突**：程序想找硬浮点的运行环境，但开发板只有软浮点的，所以报错「找不到ld-linux-armhf.so.3」。
4. **架构是基础**：aarch64（64位）可以兼容运行ARM32程序，但需要对应32位的库；
5. **浮点模式是「运行环境」**：ARM32程序分软/硬浮点，必须匹配开发板上的库/链接器类型；
6. **编译器决定程序属性**：
   - 用`arm-linux-gnueabihf-gcc` → 生成ARM32硬浮点程序 → 需开发板装armhf库；
   - 用`arm-linux-gnueabi-gcc` → 生成ARM32软浮点程序 → 开发板原生兼容；
   - 用`aarch64-linux-gnu-gcc` → 生成aarch64程序 → 完全匹配开发板，无需兼容。

# lvgl8移植到lvgl9

经过一天的研究，分析lvgl8项目的源码，我也是成功让lvgl9项目在我的开发板上跑起来了啊！下面来记录一下具体的细节。

## 移植lvgl的核心通用步骤

1. 配置comfig.h，开启触摸等宏定义，关闭电脑用宏定义。
2. 使用正确的api连接正确的事件和触屏输入节点。
3. 适配设备屏幕属性。
4. 编译查找问题

## lvgl8移植到lvgl9的区别

1. **构建方式**：v8 要手动引入 `lv_drivers.mk`/`lv_draw_sw.mk` 等多个编译文件，v9 只需要引入核心 `lvgl.mk`，驱动/绘制的编译规则都自动合并进去了，Makefile 只需删冗余、加 `LV_CONF_INCLUDE_SIMPLE=1` 宏；
2. **硬件配置**：v8 在 `lv_drv_conf.h` 里写死 `/dev/fb0`/`event0` 等硬件路径，v9 不用改配置文件，直接在代码里用 API 传参（比如 `lv_fbdev_set_file`），灵活度更高；
3. **驱动管理**：v8 的 `lv_drivers` 是独立文件夹，v9 把驱动内置到 `lvgl/src/drivers`，只需手动加 `fbdev.c`/`evdev.c` 到编译列表，不用单独引驱动文件夹；
4. **配置文件**：v8 要分 `lv_conf.h` 和 `lv_drv_conf.h` 配置，v9 合并到一个 `lv_conf.h`，还新增 `lv_conf_defaults.h` 提供默认配置，只需改差异化参数；
5. **API 风格**：v8 手动填 `lv_disp_drv_t`/`lv_indev_drv_t` 结构体配置屏幕/触摸，v9 改成对象化 API（比如 `lv_fbdev_create`），一行代码搞定初始化；
8. **文件更名**：有一些文件名的简单修改；



