---
title: 嵌入式liunx应用开发笔记-进阶篇（四）
published: 2026-02-20
pinned: false
description: cmake入门与进阶。
tags: [liunx, 应用, cmake]
category: 嵌入式
draft: false
---



# CMake 入门与进阶
## 一、cmake 简介
CMake 是一款跨平台的构建系统生成工具，它不直接构建项目，而是根据配置文件（CMakeLists.txt）生成对应的构建文件（如 Makefile、Visual Studio 解决方案等），再通过构建工具（如 make、Visual Studio 编译器）完成项目编译。其核心优势是跨平台兼容性强，能适配 Linux、Windows、macOS 等多种操作系统，同时简化了复杂项目的构建配置流程，广泛应用于开源项目和商业项目中。

## 二、cmake 和 Makefile
- **Makefile**：是针对 Unix/Linux 系统的构建脚本，直接定义了源文件、编译规则、链接规则等，需手动编写，语法复杂，跨平台性差，仅适用于单一操作系统。
- **CMake**：是更高层次的构建系统生成工具，通过简洁的 CMakeLists.txt 配置项目，自动生成适配不同平台的 Makefile 或其他构建文件。无需关注底层构建脚本的语法差异，降低了跨平台项目的配置难度，同时支持更复杂的项目结构（如多目录、多库依赖）。

简单来说，CMake 是 Makefile 等构建文件的“生成器”，屏蔽了不同平台构建脚本的差异，提升了项目构建的可移植性和维护性。

## 三、cmake 的使用方法

### 示例一：单个源文件（Hello World）
#### 核心目标
用CMake构建最简单的单文件C程序，掌握基础的CMakeLists.txt编写和out-of-source构建方式。

#### 1. 源码文件
##### main.c
```c
#include <stdio.h>  

int main() 
{ 
    printf("Hello World!\n"); 
    return 0; 
} 
```

##### 基础版 CMakeLists.txt
```cmake
project(HELLO) 
add_executable(hello ./main.c) 
```

#### 2. 目录结构（初始）
```
├── CMakeLists.txt 
└── main.c 
```

#### 3. 构建命令（基础方式，文件混杂）
```bash
# 工程目录下直接执行cmake
cmake ./
# 编译生成可执行文件
make
# 运行可执行文件
./hello
```

#### 4. out-of-source构建（推荐，分离源码与构建文件）
##### 目录结构（优化后）
```
├── build  # 新建构建目录
├── CMakeLists.txt 
└── main.c 
```

##### 构建命令
```bash
# 进入build目录
cd build/
# 指向上级目录的CMakeLists.txt
cmake ../
# 编译
make
# 运行（可执行文件在build目录下）
./hello
```

#### 关键命令说明
- `project(HELLO)`：设置工程名称为HELLO（非强制，但建议添加）；
- `add_executable(hello ./main.c)`：生成名为`hello`的可执行文件，依赖源文件`main.c`。

### 示例二：多个源文件
#### 核心目标
处理同一目录下的多源文件项目，掌握`set`命令定义源文件列表。

#### 1. 源码文件
##### hello.h
```c
#ifndef __TEST_HELLO_ 
#define __TEST_HELLO_ 

void hello(const char *name); 

#endif //__TEST_HELLO_ 
```

##### hello.c
```c
#include <stdio.h> 
#include "hello.h" 

void hello(const char *name) 
{ 
    printf("Hello %s!\n", name); 
} 
```

##### main.c
```c
#include "hello.h" 

int main(void) 
{ 
    hello("World"); 
    return 0; 
} 
```

##### CMakeLists.txt
```cmake
project(HELLO) 
# 定义变量SRC_LIST，存储源文件列表
set(SRC_LIST main.c hello.c) 
# 引用变量生成可执行文件
add_executable(hello ${SRC_LIST}) 

# 也可直接写源文件列表，无需变量
# add_executable(hello main.c hello.c)
```

#### 2. 目录结构
```
├── build 
├── CMakeLists.txt 
├── hello.c 
├── hello.h 
└── main.c 
```

#### 3. 构建命令
```bash
cd build/
cmake ../
make
./hello
```

#### 关键命令说明
- `set(SRC_LIST main.c hello.c)`：创建变量`SRC_LIST`，存储`main.c`和`hello.c`两个源文件；
- `${SRC_LIST}`：引用变量，等价于直接写`main.c hello.c`。

### 示例三：生成库文件（静态/动态库）
#### 核心目标
将部分代码编译为库文件（静态/动态），并链接到可执行文件，掌握`add_library`、`target_link_libraries`等命令。

#### 1. 基础版 CMakeLists.txt（生成默认静态库）
```cmake
project(HELLO) 
# 生成库文件（默认静态库），库名libhello（自动加lib前缀）
add_library(libhello hello.c) 
# 生成可执行文件
add_executable(hello main.c) 
# 链接库文件到可执行文件
target_link_libraries(hello libhello) 
```

#### 2. 优化版 CMakeLists.txt（修改库名+指定cmake版本）
```cmake
# 设置cmake最低版本要求
cmake_minimum_required(VERSION 3.5) 
project(HELLO) 
# 生成动态库（SHARED），静态库用STATIC
add_library(libhello SHARED hello.c) 
# 修改库输出名称为hello（最终生成libhello.so/libhello.a）
set_target_properties(libhello PROPERTIES OUTPUT_NAME "hello") 
add_executable(hello main.c) 
target_link_libraries(hello libhello) 
```

#### 3. 目录结构
```
├── build 
│   ├── hello  # 可执行文件
│   └── libhello.so  # 动态库（或libhello.a静态库）
├── CMakeLists.txt 
├── hello.c 
├── hello.h 
└── main.c 
```

#### 4. 构建命令
```bash
cd build/
cmake ../
make
```

#### 关键命令说明
- `add_library(libhello hello.c)`：生成库文件，默认静态库（STATIC），动态库需加`SHARED`；Linux下库名自动加`lib`前缀，后缀`.a`（静态）/`.so`（动态）；
- `target_link_libraries(hello libhello)`：将`libhello`库链接到`hello`可执行文件；
- `set_target_properties(libhello PROPERTIES OUTPUT_NAME "hello")`：修改库输出名称，解决`liblibhello.a`的命名问题；
- `cmake_minimum_required(VERSION 3.5)`：设置cmake最低版本要求（非强制，建议添加）。

### 示例四：源文件组织到不同目录
#### 核心目标
处理多目录项目，掌握`add_subdirectory`、`include_directories`命令，以及多级CMakeLists.txt的编写。

#### 1. 目录结构
```
├── build 
├── CMakeLists.txt  # 顶层
├── libhello  # 库文件目录
│   ├── CMakeLists.txt 
│   ├── hello.c 
│   └── hello.h 
└── src  # 主程序目录
    ├── CMakeLists.txt 
    └── main.c 
```

#### 2. 各目录CMakeLists.txt
##### 顶层 CMakeLists.txt
```cmake
cmake_minimum_required(VERSION 3.5) 
project(HELLO) 
# 解析子目录的CMakeLists.txt（先库后主程序）
add_subdirectory(libhello) 
add_subdirectory(src) 
```

##### libhello 目录 CMakeLists.txt
```cmake
add_library(libhello hello.c) 
set_target_properties(libhello PROPERTIES OUTPUT_NAME "hello") 
```

##### src 目录 CMakeLists.txt
```cmake
# 指定头文件路径（PROJECT_SOURCE_DIR为工程源码根目录）
include_directories(${PROJECT_SOURCE_DIR}/libhello) 
add_executable(hello main.c) 
target_link_libraries(hello libhello) 
```

#### 3. 构建命令
```bash
cd build/
cmake ../
make
```

#### 4. 构建结果目录
```
├── build 
│   ├── libhello 
│   │   └── libhello.a  # 库文件
│   └── src  
│       └── hello  # 可执行文件
├── CMakeLists.txt 
├── libhello 
│   ├── CMakeLists.txt 
│   ├── hello.c 
│   └── hello.h 
└── src 
    ├── CMakeLists.txt 
    └── main.c 
```

#### 关键命令说明
- `add_subdirectory(libhello)`：告诉cmake解析子目录`libhello`下的CMakeLists.txt；
- `include_directories(${PROJECT_SOURCE_DIR}/libhello)`：指定头文件搜索路径，让`src`目录的代码能找到`libhello`下的`hello.h`；
- `${PROJECT_SOURCE_DIR}`：cmake内置变量，指向工程源码根目录。

### 示例五：指定可执行文件/库文件输出目录
#### 核心目标
将可执行文件和库文件分别输出到`bin`、`lib`目录，分离构建产物，掌握`EXECUTABLE_OUTPUT_PATH`、`LIBRARY_OUTPUT_PATH`变量。

#### 1. 修改后的CMakeLists.txt
##### src 目录 CMakeLists.txt
```cmake
include_directories(${PROJECT_SOURCE_DIR}/libhello) 
# 设置可执行文件输出路径（PROJECT_BINARY_DIR为build目录）
set(EXECUTABLE_OUTPUT_PATH ${PROJECT_BINARY_DIR}/bin) 
add_executable(hello main.c) 
target_link_libraries(hello libhello) 
```

##### libhello 目录 CMakeLists.txt
```cmake
# 设置库文件输出路径
set(LIBRARY_OUTPUT_PATH ${PROJECT_BINARY_DIR}/lib) 
add_library(libhello hello.c) 
set_target_properties(libhello PROPERTIES OUTPUT_NAME "hello") 
```

#### 2. 最终目录结构
```
├── build 
│   ├── bin 
│   │   └── hello  # 可执行文件
│   └── lib 
│       └── libhello.a  # 库文件
├── CMakeLists.txt 
├── libhello 
│   ├── CMakeLists.txt 
│   ├── hello.c 
│   └── hello.h 
└── src 
    ├── CMakeLists.txt 
    └── main.c 
```

#### 3. 构建命令
```bash
cd build/
cmake ../
make
# 运行可执行文件
./bin/hello
```

#### 关键变量说明
- `EXECUTABLE_OUTPUT_PATH`：控制可执行文件的输出路径，`${PROJECT_BINARY_DIR}`指向build目录；
- `LIBRARY_OUTPUT_PATH`：控制库文件的输出路径。

### 核心总结
1. CMake的核心是编写`CMakeLists.txt`，通过命令定义项目规则，最终生成Makefile后用`make`编译；
2. 推荐使用`out-of-source`构建（新建build目录），分离源码与构建文件，便于清理；
3. 多目录项目通过`add_subdirectory`解析子目录的CMakeLists.txt，用`include_directories`指定头文件路径；
4. 库文件生成用`add_library`，链接用`target_link_libraries`，可通过`set_target_properties`修改库名；
5. 可通过`EXECUTABLE_OUTPUT_PATH`/`LIBRARY_OUTPUT_PATH`指定可执行文件/库文件的输出目录，规范构建产物结构。


## 四、CMakeLists.txt 语法规则
### 一、基础语法规范
1. **大小写不敏感**：`project()` 与 `PROJECT()`、`add_executable()` 与 `ADD_EXECUTABLE()` 功能完全一致，建议统一使用小写风格，提升代码可读性。
2. **命令格式**：命令名后紧跟参数，参数间用空格分隔，以换行结束；若参数过多需换行，用反斜杠 `\` 连接（例如多源文件指定时）。
3. **注释规则**：仅支持单行注释，以 `#` 开头，无多行注释语法，需在每一行注释前添加 `#`。
4. **变量操作**：
   - 定义变量：`set(变量名 变量值)`，变量值可为字符串、路径或列表（多个值用空格分隔）。
   - 引用变量：`${变量名}`，例如 `add_executable(myapp ${SRC_LIST})`。

### 二、核心常用命令
| 命令 | 说明 | 典型示例 |
| :--- | :--- | :--- |
| `add_executable` | 定义可执行程序目标 | `add_executable(demo main.c utils.c)` |
| `add_library` | 定义库文件目标（静态库或动态库） | `add_library(mylib STATIC math.c)` |
| `add_subdirectory` | 进入指定目录，寻找并构建该目录下的 `CMakeLists.txt` | `add_subdirectory(./lib)` |
| `aux_source_directory` | 收集指定目录下的所有源文件名，并将其赋值给变量 | `aux_source_directory(./src SRC_FILES)` |
| `cmake_minimum_required` | 设置构建项目所需的 CMake 最低版本号 | `cmake_minimum_required(VERSION 3.5)` |
| `get_target_property` | 获取指定目标的属性值 | `get_target_property(OUTPUT_NAME demo PROPERTY OUTPUT_NAME)` |
| `include_directories` | 设置所有目标的头文件搜索路径，等效于 GCC 的 `-I` 选项 | `include_directories(./include ./third_party)` |
| `link_directories` | 设置所有目标的库文件搜索路径，等效于 GCC 的 `-L` 选项 | `link_directories(./lib)` |
| `link_libraries` | 设置所有目标需要链接的库文件 | `link_libraries(mylib pthread)` |
| `list` | 用于对列表（List）进行各种操作（如追加、删除、查找等） | `list(APPEND SRC_FILES ./src/extra.c)` |
| `message` | 用于在构建过程中打印、输出信息（如状态、警告或错误） | `message(STATUS "Build type: ${CMAKE_BUILD_TYPE}")` |
| `project` | 设置工程名称，并可指定工程支持的语言 | `project(MyProject C)` |
| `set` | 定义或修改变量的值 | `set(EXECUTABLE_OUTPUT_PATH ./bin)` |
| `set_target_properties` | 设置目标的属性（如输出名称、版本号、编译选项等） | `set_target_properties(demo PROPERTIES OUTPUT_NAME "my_demo")` |
| `target_include_directories` | 仅设置**指定目标**的头文件搜索路径（推荐优先使用） | `target_include_directories(demo PUBLIC ./include)` |
| `target_link_libraries` | 为**指定目标**设置需要链接的库文件（推荐优先使用） | `target_link_libraries(demo mylib pthread)` |
| `target_sources` | 为**指定目标**添加所需的源文件 | `target_sources(demo PRIVATE ./src/feature.c)` |


### 三、关键常用变量
| 变量名 | 功能说明 | 应用场景 |
|--------|----------|----------|
| `CMAKE_C_COMPILER` | 指定 C 编译器路径 | 切换自定义编译器（如交叉编译场景） |
| `CMAKE_CXX_COMPILER` | 指定 C++ 编译器路径 | 同上，针对 C++ 项目 |
| `CMAKE_BUILD_TYPE` | 指定构建类型 | 可选 Debug（调试模式，含调试信息）、Release（发布模式，优化编译） |
| `EXECUTABLE_OUTPUT_PATH` | 可执行文件输出目录 | `set(EXECUTABLE_OUTPUT_PATH ./bin)` 指定输出到 bin 目录 |
| `LIBRARY_OUTPUT_PATH` | 库文件输出目录 | `set(LIBRARY_OUTPUT_PATH ./lib)` 指定库文件输出到 lib 目录 |
| `PROJECT_NAME` | 由 `project()` 定义的项目名称 | 动态引用项目名，如 `add_executable(${PROJECT_NAME} main.c)` |
| `CMAKE_CURRENT_SOURCE_DIR` | 当前 CMakeLists.txt 所在目录路径 | 引用当前目录下的文件，如 `include_directories(${CMAKE_CURRENT_SOURCE_DIR}/include)` |
| `CMAKE_CURRENT_BINARY_DIR` | 当前构建目录路径 | 指向编译生成文件的目录（如 build 目录） |
| `CMAKE_INSTALL_PREFIX` | 安装目录前缀 | 默认 `/usr/local`，可通过 `-DCMAKE_INSTALL_PREFIX=./install` 修改安装路径 |
| `CMAKE_C_FLAGS` | 指定 C 编译器额外选项 | 添加编译警告（-Wall）、优化级别（-O2）等 |
| `CMAKE_CXX_FLAGS` | 指定 C++ 编译器额外选项 | 同上，针对 C++ 项目 |
| `CMAKE_MODULE_PATH` | 指定 CMake 模块查找路径 | 引入自定义 FindXXX.cmake 模块时 |
| `PROJECT_SOURCE_DIR` | 项目根目录（包含顶层 CMakeLists.txt） | 引用根目录下的公共文件（如 `include`） |
| `PROJECT_BINARY_DIR` | 项目构建目录 | 指向编译生成文件的根目录（如 `build`） |

### 四、双引号的作用
1. **包裹含空格的字符串**：当路径或变量值包含空格时，必须用双引号包裹，避免被解析为多个参数。例如：`set(PATH "C:/Program Files/MyLib")`。
2. **保留变量引用**：在字符串中引用变量时，双引号可确保变量被正确解析，尤其是变量值为列表或含特殊字符时。例如：`message("Project Name: ${PROJECT_NAME}")`。
3. **注意事项**：无空格的普通字符串可省略双引号，但为了统一风格和避免潜在问题，建议关键路径和变量引用时都添加双引号。

### 五、条件判断语法
CMake 支持通过条件判断实现不同场景的动态配置，核心命令包括 `if()`、`elseif()`、`else()`、`endif()`。

#### 1. 常用判断条件

| 表达式 | 为 `true` 的条件 | 为 `false` 的条件 | 说明 |
|--------|------------------|------------------|------|
| `<constant>` | constant 为 1、ON、YES、TRUE、Y 或非零数（大小写不敏感） | constant 为 0、OFF、NO、FALSE、N、IGNORE、NOTFOUND、空字符串或以后缀 NOTFOUND 结尾（大小写不敏感） | 若与上述常量均不匹配，则视为变量或字符串 |
| `<variable|string>` | 已经定义且值不为 false 的变量 | 未定义或值为 false 的变量 | 变量本质为字符串 |
| `NOT <expression>` | expression 为 false | expression 为 true | 逻辑非运算 |
| `<expr1> AND <expr2>` | expr1 和 expr2 同时为 true | expr1 和 expr2 至少有一个为 false | 逻辑与运算 |
| `<expr1> OR <expr2>` | expr1 和 expr2 至少有一个为 true | expr1 和 expr2 均为 false | 逻辑或运算 |
| `COMMAND name` | name 是已定义的命令、宏或函数 | name 未定义 | - |
| `TARGET name` | name 是通过 `add_executable()`、`add_library()` 或 `add_custom_target()` 定义的目标 | name 未定义 | - |
| `TEST name` | name 是由 `add_test()` 命令创建的现有测试名称 | name 未创建 | - |
| `EXISTS path` | path 指定的文件或目录存在 | path 指定的文件或目录不存在 | 仅适用于完整路径 |
| `IS_DIRECTORY path` | path 指定的路径为目录 | path 指定的路径不为目录 | 仅适用于完整路径 |
| `IS_SYMLINK path` | path 为符号链接 | path 不是符号链接 | 仅适用于完整路径 |
| `IS_ABSOLUTE path` | path 为绝对路径 | path 不是绝对路径 | - |
| `<variable|string> MATCHES regex` | variable 与正则表达式 regex 匹配成功 | variable 与正则表达式 regex 匹配失败 | - |
| `<variable|string> IN_LIST <variable>` | 右边列表变量中包含左边的元素 | 右边列表变量中不包含左边的元素 | - |
| `DEFINED <variable>` | 给定的变量已定义（无论值为真或假） | 给定的变量未定义 | 宏不属于变量范畴 |
| `<variable|string> LESS <variable|string>` | 左侧字符串/变量的值为有效数字且小于右侧数字 | 左侧数字大于或等于右侧数字 | 仅对有效数字生效 |
| `<variable|string> GREATER <variable|string>` | 左侧字符串/变量的值为有效数字且大于右侧数字 | 左侧数字小于或等于右侧数字 | 仅对有效数字生效 |
| `<variable|string> EQUAL <variable|string>` | 左侧字符串/变量的值为有效数字且等于右侧数字 | 左侧数字不等于右侧数字 | 仅对有效数字生效 |


#### 2. 语法格式
```cmake
if(条件)
    # 条件成立时执行的配置（如设置编译选项、添加源文件等）
elseif(另一条件)
    # 另一条件成立时执行的配置
else()
    # 所有条件均不成立时执行的配置
endif(条件)  # 结尾需与开头 if 的条件对应，可省略重复条件，直接写 endif()
```

#### 3. 应用示例
```cmake
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    add_definitions(-DDEBUG)  # 调试模式下定义 DEBUG 宏
elseif(CMAKE_BUILD_TYPE STREQUAL "Release")
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -O2")  # 发布模式下添加优化选项
else()
    message(WARNING "Build type not specified, using default Debug")
    set(CMAKE_BUILD_TYPE "Debug")
endif()
```

### 六、循环语句
CMake 支持 `foreach()` 循环，用于遍历列表或范围，语法格式如下：
```cmake
# 遍历列表
foreach(变量 IN ITEMS 列表项1 列表项2 ...)
    # 循环体操作
endforeach(变量)

# 遍历范围（从 start 到 end，步长为 step，step 可选，默认 1）
foreach(变量 RANGE 开始值 结束值 [步长])
    # 循环体操作
endforeach(变量)
```

#### 应用示例
1. 遍历源文件列表，添加编译选项：
```cmake
set(SRC_LIST main.c utils.c math.c)
foreach(src IN ITEMS ${SRC_LIST})
    message("Source file: ${src}")
endforeach(src)
```

2. 遍历数字范围，生成多个目标：
```cmake
foreach(num RANGE 1 3)
    add_executable(demo_${num} demo_${num}.c)
endforeach(num)
```
（将生成 demo_1、demo_2、demo_3 三个可执行文件）

### 七、数学运算（math 命令）
通过 `math()` 命令可执行整数运算，语法格式：
```cmake
math(EXPR 结果变量 运算表达式 [OUTPUT_FORMAT 格式])
```
- 运算表达式支持 `+`、`-`、`*`、`/`、`%`（取模）、`&`（按位与）、`|`（按位或）等运算。
- 格式可选 DECIMAL（十进制，默认）、HEXADECIMAL（十六进制）、OCTAL（八进制）。

#### 应用示例
```cmake
math(EXPR SUM "10 + 20")  # SUM = 30
math(EXPR PRODUCT "5 * 6")  # PRODUCT = 30
math(EXPR MOD "10 % 3")  # MOD = 1
math(EXPR HEX "255" OUTPUT_FORMAT HEXADECIMAL)  # HEX = FF
message("SUM: ${SUM}, HEX: ${HEX}")
```