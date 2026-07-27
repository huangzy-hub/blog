---
title: CCS/MSPM0 链接过程及 Flash 分区笔记
published: 2026-07-27
pinned: false
description: 从目标文件、符号解析、段分配和重定位出发，理解 MSPM0 工程的链接过程，以及自定义 Flash 参数区时为什么要管理自动链接脚本。
tags: [MSPM0, CCS, 链接器, Flash]
category: 嵌入式
draft: false
---

# CCS/MSPM0 链接过程及 Flash 分区笔记

链接可以理解为：

> **把许多带有“待定地址”的代码模块，合并成一个地址完全确定的 MCU 映像。**

在 CCS/MSPM0 工程中，自己划分 Flash 时关闭或排除自动链接脚本，主要不是因为“手动脚本更高级”，而是因为自动脚本会按照芯片默认布局声明整块 Flash，甚至可能在构建时重新生成。它并不知道我们想永久保留参数区，因此可能与手动脚本冲突、覆盖修改，或者继续把程序放进原本计划预留的区域。

> 本文中的段名、地址和脚本内容用于说明概念。实际工程应以具体 MSPM0 型号、编译器、SDK、完整链接脚本以及最终生成的 `.map` 文件为准。

## 一、编译阶段产生的目标文件

假设工程中有两个源文件：

```c
// main.c
#include <stdint.h>

extern void LED_Toggle(void);

uint32_t count = 10;
uint32_t buffer[100];

int main(void)
{
    LED_Toggle();
}
```

```c
// led.c
void LED_Toggle(void)
{
    // ...
}
```

编译后得到：

```text
main.c → main.o
led.c  → led.o
```

此时 `main.o` 还不是可以烧录的程序，其内部大致包含：

```text
main.o
├── .text.main       main() 的机器码
├── .data.count      count 的初始数据
├── .bss.buffer      buffer 所需的空间
├── 符号表
│   ├── main：已定义
│   ├── count：已定义
│   ├── buffer：已定义
│   └── LED_Toggle：未定义
└── 重定位表
    └── main 中调用 LED_Toggle 的位置需要后续修正
```

编译 `main.c` 时，编译器只知道 `LED_Toggle()` 是一个外部函数，并不知道它最终位于哪个地址，所以会留下一条待修正记录，也就是“重定位项”。

## 二、链接器会收到哪些输入

一个 MSPM0 工程的链接器通常会接收到：

```text
应用代码目标文件：
    main.o
    motor.o
    uart.o

启动代码：
    startup_mspm0g350x.o

SysConfig 生成代码：
    ti_msp_dl_config.o

DriverLib：
    driverlib.a

C 运行库：
    libc.a
    compiler runtime library

链接脚本：
    device_linker.cmd
    或用户维护的 linker.cmd
```

其中：

- `.o` 是单个目标文件；
- `.a` 是由许多 `.o` 打包而成的静态库；
- `.cmd` 用来告诉链接器存储器范围和各个段的放置规则。

启动文件、运行库和部分段名会随编译器及工程模板变化，不能仅凭示例名称判断自己的工程。

## 三、链接器的主要工作过程

### 1. 收集输入段

每个目标文件都有自己的输入段：

```text
main.o
├── .text.main
├── .data.count
└── .bss.buffer

led.o
└── .text.LED_Toggle

startup.o
├── .intvecs
└── .text.Reset_Handler
```

链接器会根据脚本规则，把性质相同的输入段收集到输出段中：

```text
所有 .text.*   → 输出段 .text
所有 .rodata.* → 输出段 .const
所有 .data.*   → 输出段 .data
所有 .bss.*    → 输出段 .bss
中断向量表     → 输出段 .intvecs
```

输入段和输出段的关系可以理解为：

```text
main.o 中的 .text.main      ┐
uart.o 中的 .text.UART_Init ├── 合并 ──> 最终输出段 .text
motor.o 中的 .text.PID_Run  ┘
```

### 2. 解析符号

链接器会建立全局符号表：

| 符号 | 来源 | 状态 |
|---|---|---|
| `main` | `main.o` | 已定义 |
| `LED_Toggle` | `led.o` | 已定义 |
| `DL_GPIO_init` | DriverLib 或生成代码 | 已定义 |
| `Reset_Handler` | 启动代码 | 已定义 |
| `missing_function` | 无 | 未定义，链接报错 |

如果多个目标文件同时定义同一个非弱符号，例如：

```text
main.o：定义 UART_Init
uart.o：也定义 UART_Init
```

链接器通常会报告符号重复定义。如果某个符号没有任何实现，则会出现类似错误：

```text
unresolved symbol
undefined reference
```

静态库的处理稍有不同。链接器通常不会把整个 `driverlib.a` 全部放进固件，而是根据尚未解析的符号，从库中抽取真正需要的目标模块：

```text
程序引用某个 DriverLib 符号
        ↓
链接器搜索 driverlib.a
        ↓
找到包含该符号的目标模块
        ↓
将该模块加入链接
        ↓
继续处理该模块引入的新符号
        ↓
直到没有未解析符号
```

### 3. 读取存储器布局

概念化的 TI `.cmd` 文件可能包含：

```text
MEMORY
{
    FLASH (RX)  : origin = 0x00000000, length = 0x0001F000
    PARAM (R)   : origin = 0x0001F000, length = 0x00001000
    SRAM  (RWX) : origin = 0x20000000, length = 0x00008000
}
```

`MEMORY` 负责声明：

- 存储器区域的名称；
- 起始地址；
- 长度；
- 大致访问权限。

随后由 `SECTIONS` 决定输出段的放置位置：

```text
SECTIONS
{
    .intvecs : {} > FLASH
    .text    : {} > FLASH
    .const   : {} > FLASH

    .data    : {} > SRAM
    .bss     : {} > SRAM
    .stack   : {} > SRAM

    .param   : {} > PARAM
}
```

可以概括为：

```text
.intvecs、.text、.const → FLASH
.data、.bss、.stack     → SRAM
.param                  → PARAM
```

### 4. 为每个段分配地址

链接器会维护一个“当前位置计数器”。假设 Flash 从 `0x00000000` 开始，最终布局可能类似：

```text
0x00000000  中断向量表 .intvecs
0x00000100  启动代码
0x00000400  main()
0x00000480  LED_Toggle()
0x00000500  其他函数
0x00008000  只读常量
...
0x0001F000  参数区开始
```

分配过程中还会处理对齐要求。假如前一个对象结束于 `0x00000481`，下一个对象要求 4 字节对齐，那么它会被补齐到 `0x00000484`，而不是直接接在后面。

这个阶段会检查：

- `.text` 是否超出 Flash；
- `.bss`、堆和栈是否超出 SRAM；
- 存储区域是否重叠；
- 对齐是否满足；
- 固定地址段是否能够成功放置。

如果程序区长度为：

```text
FLASH length = 0x1F000
```

那么普通程序只能占用：

```text
0x00000000 ～ 0x0001EFFF
```

当内容装不下时，链接器应该报错，而不是自动侵占 `0x0001F000` 之后的参数区。

### 5. 执行重定位

完成符号解析和段分配后，链接器已经知道每个符号的最终地址，例如：

```text
main            = 0x00000400
LED_Toggle      = 0x00000480
count           = 0x20000000
buffer          = 0x20000004
```

原来目标文件中“调用 `LED_Toggle`，但地址待定”的指令，现在可以按照 ARM Thumb 指令编码填入目标地址或相对偏移。变量访问中的待定地址也会在这个阶段得到修正。

链接的核心可以归纳为：

> **符号解析决定“它是谁”，段分配决定“它在哪里”，重定位负责把最终地址写入机器指令和数据。**

### 6. 生成 Flash 加载映像和 RAM 运行映像

这一部分最容易让人困惑的是 `.data`。

```c
uint32_t speed = 100;
```

运行时，`speed` 位于 SRAM：

```text
运行地址 VMA：0x20000000
```

但 SRAM 掉电后数据会丢失，所以初始值 `100` 必须保存在 Flash：

```text
加载地址 LMA：Flash 中的某个地址
```

可以理解为：

```text
Flash：保存 speed 的初始值 100
         │
         │ 复位启动时复制
         ↓
SRAM：真正运行时的 speed
```

而未显式初始化的数组：

```c
uint32_t buffer[100];
```

通常属于 `.bss`。固件中不需要保存 400 字节的零，只需为它在 SRAM 中预留空间，启动代码复位时再将这片区域清零。

概念化的启动过程如下：

```c
void Reset_Handler(void)
{
    // 将 .data 初始值从 Flash 复制到 SRAM
    copy_data_from_flash_to_ram();

    // 将 .bss 清零
    clear_bss();

    // 初始化系统
    SystemInit();

    // 进入用户程序
    main();
}
```

### 7. 生成输出文件

链接结束后通常会生成：

```text
project.out / project.elf
project.map
project.hex（如果工程配置生成）
```

它们的作用分别是：

- `.out/.elf`：包含机器码、地址、符号和调试信息；
- `.hex`：主要描述需要向哪些地址写入什么数据；
- `.map`：详细描述链接后的内存布局、段和符号。

`.map` 文件中通常可以检查：

```text
Memory Configuration

FLASH  origin=0x00000000 length=0x0001F000
PARAM  origin=0x0001F000 length=0x00001000
SRAM   origin=0x20000000 length=0x00008000
```

以及：

```text
.text          0x00000100  size ...
.const         0x00008000  size ...
.data          0x20000000  size ...
.bss           0x20000100  size ...
.param         0x0001F000  size ...
```

因此判断 Flash 是否真正预留成功，不能只看 `.cmd`，还应检查 `.map` 和最终 `.hex/.out` 是否包含预留地址范围。

## 四、为什么自定义 Flash 时要管理自动链接脚本

### 1. 默认脚本可能声明完整 Flash

自动生成的脚本可能类似：

```text
MEMORY
{
    FLASH (RX) : origin = 0x00000000, length = 整块 Flash 大小
}
```

而自定义脚本可能写成：

```text
MEMORY
{
    FLASH_CODE : origin = 0x00000000, length = 程序区大小
    PARAM      : origin = 参数区地址, length = 参数区大小
}
```

如果两份脚本同时参与链接，可能产生两类问题。

#### 同名区域重复定义

两份文件都定义 `FLASH`、`SRAM`，链接器可能直接报告区域重复定义或段规则冲突。

#### 不同名称但物理地址重叠

即使区域名称不同，物理地址也可能重叠：

```text
自动 FLASH  ──────────────────────────┐
手动 APP_FLASH ───────────┐            │
手动 PARAM                 └───────────┤
                                      └─ 地址重叠
```

此时即便链接器没有立即报错，普通代码仍可能按照自动脚本被放入本来计划预留的区域。

### 2. 自动生成文件可能被覆盖

一些 CCS/SysConfig 工程会生成类似 `device_linker.cmd` 的文件。其内容可能由以下信息共同决定：

- 芯片型号；
- Flash 和 RAM 容量；
- SDK 元数据；
- 编译器；
- 工程配置。

如果直接修改这个生成文件，下一次运行 SysConfig、清理构建或重新生成工程时，修改可能恢复为默认值。

更稳妥的做法是：

1. 从当前工程复制与芯片、SDK 和编译器匹配的完整脚本；
2. 将副本作为用户维护的 `.cmd` 文件；
3. 在用户维护版本上修改 `MEMORY` 和必要的 `SECTIONS`；
4. 从工程链接输入中排除原自动生成脚本；
5. 确保只有一套权威存储器布局；
6. 重新构建并用 `.map` 文件验证。

> 不要直接手改 SysConfig 或构建过程生成的 `device_linker.cmd`，也不要让自动布局与自定义布局同时描述同一块物理 Flash。

### 3. 不是所有多个 `.cmd` 文件都冲突

多个 `.cmd` 文件共同参与链接本身没有问题，例如：

```text
memory.cmd      定义 MEMORY
sections.cmd    定义 SECTIONS
libraries.cmd   指定库
```

真正的问题是：

> **两份脚本都试图描述同一块物理 Flash，却给出了不同的边界或放置规则。**

所以“关闭自动链接脚本”不是绝对的语法要求，而是工程管理要求。默认自动布局和自定义 Flash 布局只能有一个作为最终物理内存布局的权威来源。

## 五、手动脚本不能只改 Flash 长度

完整链接脚本除了普通 `.text`、`.data` 外，还可能包含：

- 中断向量表；
- 复位入口；
- C/C++ 初始化数组；
- 异常展开信息；
- TI 运行库需要的段；
- 芯片配置区；
- 安全或启动相关段；
- SRAM、堆和栈定义；
- `.data` 的加载地址信息；
- 未初始化段；
- 特定 DriverLib/SysConfig 段。

因此不要从空文件开始随意编写一个过度简化的脚本。推荐流程是：

```text
复制当前工程匹配芯片和编译器的完整自动脚本
                       ↓
将副本变成用户维护文件
                       ↓
修改 MEMORY 中的 Flash 边界
                       ↓
增加参数区和必要的自定义段
                       ↓
排除原自动脚本
                       ↓
重新构建并检查 map 文件
```

否则可能出现：

- 程序能链接但无法启动；
- 中断向量表地址错误；
- 全局变量初值不正确；
- C++ 静态构造函数没有执行；
- 堆栈位置错误；
- 芯片配置段丢失。

## 六、参数区的两种定义方式

### 方式一：只预留地址，不把参数放进固件

这种方式适合保存运行时参数：

```text
MEMORY
{
    FLASH_APP   (RX) : origin = APP起始地址, length = APP长度
    FLASH_PARAM (R)  : origin = 参数区地址, length = 参数区长度
    SRAM       (RWX) : origin = SRAM起始地址, length = SRAM长度
}
```

普通段只放入 `FLASH_APP`：

```text
.text  : {} > FLASH_APP
.const : {} > FLASH_APP
```

不为 `FLASH_PARAM` 创建有内容的输出段。这样最终固件通常不会携带参数区数据，应用程序通过固定地址和 Flash API 访问参数区。

但是，烧录器是否保留该区域仍取决于烧录时采用的擦除策略。

### 方式二：定义自定义段并写入初始数据

这种方式适合保存出厂默认参数：

```text
.factory_param :
{
    KEEP(*(.factory_param))
} > FLASH_PARAM
```

在 C 文件中将对象放入对应段：

```c
#pragma DATA_SECTION(factoryParam, ".factory_param")
const ParameterBlock factoryParam = {
    .magic = 0x50415241,
    .version = 1,
};
```

这样参数数据会进入 `.out/.hex`，烧录固件时也会写入参数区。

如果要求固件升级时保留运行参数，就不要把运行时参数与每次烧录都会写入的出厂默认数据混在一起。可以采用类似布局：

```text
┌──────────────────────┐
│ 应用程序             │
├──────────────────────┤
│ 出厂默认参数（可选） │
├──────────────────────┤
│ 用户运行参数 A       │
├──────────────────────┤
│ 用户运行参数 B       │
└──────────────────────┘
```

## 七、最终验证清单

完成 Flash 分区后，至少检查以下内容：

- [ ] 工程中只有一套有效的物理存储器布局；
- [ ] 没有直接修改会被重新生成的链接脚本；
- [ ] 中断向量表、复位入口、运行库段、堆和栈仍然完整；
- [ ] `.map` 中程序区与参数区边界符合设计；
- [ ] 普通 `.text/.const` 没有进入参数区；
- [ ] `.out/.hex` 的实际地址范围符合预期；
- [ ] 如果参数区只用于运行时保存，固件映像没有写入该区域；
- [ ] CCS/UniFlash 使用的擦除和下载策略不会误擦参数区；
- [ ] 实际升级测试后，参数仍能正确保留并通过完整性校验。

最后强调：

> **链接脚本只决定固件占用哪些地址，不决定下载器擦除哪些地址。**

要可靠保留自定义参数区，必须同时检查链接 `.map`、输出映像的地址范围，以及 CCS/UniFlash 的 sector erase、program-only 或 mass erase 策略。
