---
title: opencv源码的编译和运行
published: 2026-04-06
pinned: false
description: opencv源码的编译和运行
tags: [opencv]
category: 嵌入式
draft: false
---


# OpenCV 编译与使用指南

---

## 目录

1. [准备工作](#准备工作)
2. [获取源码](#获取源码)
3. [Windows MinGW 编译](#windows-mingw-编译)
4. [Windows VS 编译](#windows-vs-编译)
5. [Linux 编译](#linux-编译)
6. [ARM 交叉编译](#arm-交叉编译)
7. [目录结构](#目录结构)
8. [CMake 使用](#cmake-使用)
9. [FAQ](#faq)

---

## 准备工作

| 软件 | 要求 | 说明 |
|------|------|------|
| **CMake** | 3.10+ | 编译配置工具，生成 Makefile 或 VS 项目 |
| **编译器** | MinGW/VS/GCC | 用于编译 C++ 代码 |
| **Git** | 可选 | 用于从 GitHub 下载源码 |

---

## 获取源码

```bash
# 克隆 OpenCV 主仓库（核心模块）
git clone https://github.com/opencv/opencv.git

# 克隆 OpenCV 额外模块（可选，包含 SIFT、SURF 等更多功能）
git clone https://github.com/opencv/opencv_contrib.git

# 切换到稳定版本（4.12.0 是一个 LTS 版本）
cd opencv
git checkout 4.12.0
cd ../opencv_contrib
git checkout 4.12.0
```

---

## Windows MinGW 编译

```bash
# 进入 build 目录（所有编译中间文件都在这里）
cd build

# 配置 CMake
cmake -G "MinGW Makefiles" ^
    # 编译 Release 版本（性能比 Debug 好很多）
    -D CMAKE_BUILD_TYPE=Release ^
    # 安装路径，编译完成后文件会安装到这里
    -D CMAKE_INSTALL_PREFIX=D:/opencv/install_mingw ^
    # 把所有模块合并成一个库文件（方便使用）
    -D BUILD_opencv_world=ON ^
    # 不编译示例程序（节省编译时间）
    -D BUILD_EXAMPLES=OFF ^
    # 不编译测试代码（节省编译时间）
    -D BUILD_TESTS=OFF ^
    # 源码路径（相对于 build 目录）
    ../sources

# 编译（-j8 表示用 8 个线程并行编译，根据 CPU 核心数调整）
mingw32-make -j8

# 安装（把编译好的文件复制到 CMAKE_INSTALL_PREFIX 指定的目录）
mingw32-make install
```

---

## Windows VS 编译

```bash
# 生成 Visual Studio 2022 解决方案（-A x64 表示 64 位）
cmake -G "Visual Studio 17 2022" -A x64 ^
    # 安装路径
    -D CMAKE_INSTALL_PREFIX=D:/opencv/install_msvc ^
    # 合并成一个库
    -D BUILD_opencv_world=ON ^
    # 关闭示例和测试
    -D BUILD_EXAMPLES=OFF ^
    -D BUILD_TESTS=OFF ^
    ../sources

# 编译 Release 版本（也可以在 VS IDE 中打开 OpenCV.sln 编译）
cmake --build . --config Release

# 安装（复制到安装目录）
cmake --build . --config Release --target INSTALL
```

---

## Linux 编译

```bash
# 安装编译依赖
sudo apt-get install build-essential cmake git libgtk-3-dev \
    libavcodec-dev libavformat-dev libswscale-dev \
    libjpeg-dev libpng-dev libtiff-dev

# 进入 build 目录
cd build

# 配置 CMake
cmake -D CMAKE_BUILD_TYPE=Release \
    # 安装到系统目录（默认位置，方便其他程序找到）
    -D CMAKE_INSTALL_PREFIX=/usr/local \
    # 关闭示例和测试
    -D BUILD_EXAMPLES=OFF \
    -D BUILD_TESTS=OFF \
    ../opencv

# 编译（$(nproc) 自动使用所有 CPU 核心）
make -j$(nproc)

# 安装到系统
sudo make install

# 更新动态链接库缓存（让系统找到新安装的库）
sudo ldconfig
```

---

## ARM 交叉编译

### 方法一：Linux 交叉编译（在 x86 电脑上编译 ARM 程序）

```bash
# 1. 安装 ARM 交叉编译工具链
sudo apt-get install gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf

# 2. 创建工具链配置文件 toolchain.cmake
# 告诉 CMake 我们要交叉编译到 ARM 平台
set(CMAKE_SYSTEM_NAME Linux)              # 目标系统是 Linux
set(CMAKE_SYSTEM_PROCESSOR arm)           # 目标 CPU 是 ARM
set(CMAKE_C_COMPILER arm-linux-gnueabihf-gcc)        # ARM C 编译器
set(CMAKE_CXX_COMPILER arm-linux-gnueabihf-g++)      # ARM C++ 编译器
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)          # 不要在主机系统找程序
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)           # 只在目标系统找库
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)           # 只在目标系统找头文件

# 3. 配置 CMake（使用上面的工具链文件）
cmake -G "Unix Makefiles" \
    -DCMAKE_TOOLCHAIN_FILE=../toolchain.cmake \    # 指定工具链配置
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/opt/opencv-arm \        # ARM 版本安装路径
    -DBUILD_opencv_world=ON \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_TESTS=OFF \
    -DWITH_GTK=OFF \             # 关闭 GTK（ARM 可能没有图形界面）
    -DWITH_FFMPEG=OFF \          # 关闭 FFmpeg（减少依赖）
    ../opencv

# 4. 编译
make -j8

# 5. 安装
sudo make install
```

### 方法二：ARM 设备直接编译（更简单，推荐）

如果可以直接在 ARM 设备（如树莓派）上操作，直接编译更简单：

```bash
# SSH 登录到 ARM 设备
ssh pi@raspberrypi

# 安装编译工具
sudo apt-get install build-essential cmake git

# 下载源码
git clone https://github.com/opencv/opencv.git
cd opencv && git checkout 4.12.0

# 创建 build 目录并编译
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release -DBUILD_EXAMPLES=OFF -DBUILD_TESTS=OFF
make -j4           # 树莓派4用 -j4，树莓派5用 -j8
sudo make install
sudo ldconfig
```

### 使用 ARM 版本

```bash
# 1. 将编译好的 install_arm 整个文件夹复制到 ARM 设备
scp -r install_arm pi@raspberrypi:/home/pi/

# 2. 在 ARM 设备上安装
ssh pi@raspberrypi
cd /home/pi/install_arm

# 复制库文件到系统库目录
sudo cp lib/libopencv_world.so* /usr/local/lib/

# 复制头文件
sudo cp -r include/opencv4 /usr/local/include/

# 更新动态链接库缓存
sudo ldconfig
```

---

## 目录结构

```
install_mingw/
├── bin/                          # DLL/可执行文件
│   ├── opencv_world4120.dll     # 主库文件（所有模块合并）
│   └── opencv_videoio_ffmpeg.dll  # FFmpeg 视频支持
├── include/                      # 头文件
│   └── opencv2/
│       ├── opencv.hpp            # 总头文件，包含所有模块
│       ├── core.hpp              # 核心模块
│       ├── imgproc.hpp           # 图像处理
│       ├── highgui.hpp           # 图形界面
│       └── objdetect.hpp         # 目标检测（人脸等）
├── lib/                          # 库文件
│   ├── libopencv_world4120.dll.a  # 导入库（MinGW 用）
│   └── cmake/
│       └── opencv4/
│           └── OpenCVConfig.cmake  # CMake 配置文件（find_package 用）
└── etc/                          # 配置文件和数据
    └── haarcascades/             # Haar 级联分类器（人脸检测用）
        ├── haarcascade_frontalface_default.xml
        └── ...
```

---

## CMake 使用

### CMakeLists.txt

```cmake
# 要求的最低 CMake 版本
cmake_minimum_required(VERSION 3.10)

# 项目名称
project(MyProject)

# 设置 C++ 标准（OpenCV 4 需要 C++11 或更高）
set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 如果 OpenCV 不在系统默认位置，需要指定路径
# 指向包含 OpenCVConfig.cmake 的目录
# set(OpenCV_DIR "D:/opencv/install_mingw/x64/mingw/lib")

# 查找 OpenCV 包（REQUIRED 表示必须找到，找不到就报错）
find_package(OpenCV REQUIRED)

# 打印 OpenCV 信息（可选，调试用）
message(STATUS "OpenCV version: ${OpenCV_VERSION}")
message(STATUS "OpenCV include dirs: ${OpenCV_INCLUDE_DIRS}")
message(STATUS "OpenCV libraries: ${OpenCV_LIBS}")

# 添加 OpenCV 头文件搜索路径
# 其实 find_package 已经自动处理了，但显式写出来更清楚
include_directories(${OpenCV_INCLUDE_DIRS})

# 编译可执行文件（从 main.cpp 编译出 myapp）
add_executable(myapp main.cpp)

# 链接 OpenCV 库
target_link_libraries(myapp ${OpenCV_LIBS})
```

### main.cpp

```cpp
// 包含 OpenCV 总头文件（包含所有常用模块）
#include <opencv2/opencv.hpp>
// 包含标准输入输出
#include <iostream>

// 使用 cv 和 std 命名空间，这样就不用每次写 cv:: 或 std::
using namespace cv;
using namespace std;

int main() {
    // 输出 OpenCV 版本
    cout << "OpenCV: " << CV_VERSION << endl;

    // 创建一个 400x600 的黑色图像
    // Mat 是 OpenCV 的核心类，表示矩阵/图像
    // CV_8UC3 = 8位无符号整数，3通道（BGR彩色）
    Mat img = Mat::zeros(400, 600, CV_8UC3);

    // 在图像中心画一个绿色实心圆
    // circle(图像, 圆心, 半径, 颜色(B,G,R), 线宽(-1表示填充))
    circle(img, Point(300, 200), 100, Scalar(0, 255, 0), -1);

    // 显示图像
    imshow("Test", img);

    // 等待按键（0表示无限等待）
    waitKey(0);

    return 0;
}
```

### 编译

```bash
# 创建 build 目录（编译中间文件都在这里，保持源码目录干净）
mkdir build && cd build

# 配置 CMake（-G 指定生成器）
cmake .. -G "MinGW Makefiles"

# 编译
mingw32-make

# 运行程序
./myapp
```

---

## FAQ

| 问题 | 解决方案 |
|------|---------|
| **找不到 OpenCVConfig.cmake** | 设置 `OpenCV_DIR` 变量指向包含该文件的目录<br>`set(OpenCV_DIR "path/to/lib/cmake/opencv4")` |
| **运行时找不到 DLL** | 方法1：将 OpenCV 的 `bin` 目录添加到 PATH<br>方法2：把 DLL 复制到程序所在目录 |
| **编译太慢** | 1. 使用 `-j8` 多线程编译<br>2. 关闭 `BUILD_EXAMPLES` 和 `BUILD_TESTS`<br>3. 使用 `BUILD_opencv_world=ON` 合并模块 |
| **如何切换 OpenCV 版本** | 用 `CMAKE_INSTALL_PREFIX` 安装到不同目录<br>使用时通过 `OpenCV_DIR` 切换 |

---

## 参考

- OpenCV 官网：https://opencv.org/
- OpenCV 文档：https://docs.opencv.org/
- OpenCV GitHub：https://github.com/opencv/opencv
