---
title: RK3588运行AIdemo过程记录
published: 2026-07-22
pinned: false
description: 在RK3588开发板上运行一个RKNN模型的完整流程。
tags: [RK3588, 实战记录, RKNN, 端侧AI]
category: 嵌入式
draft: false
---


这次完成的是一个完整的端侧 AI 部署闭环：把通用的 MobileNetV2 ONNX 模型转换成 RK3588 专用的 RKNN 模型，然后编译 ARM64 应用，最后在开发板 NPU 上完成图片分类。

整体链路是：

```text
通用 ONNX 模型
      ↓ RKNN-Toolkit2 转换、量化
RK3588 专用 .rknn 模型
      ↓ WSL 交叉编译
ARM64 Linux 推理程序
      ↓ SCP 传输
RK3588 开发板
      ↓ RKNN Runtime 调用
NPU 推理并输出分类结果
```

---

# 一、先分清两台“机器”的职责

这次工作涉及两个运行环境。

## 1. WSL Ubuntu：开发端

你的 WSL 是：

```text
Ubuntu 24.04
x86_64
Python 3.12
项目目录：~/rk3588-ai
```

它负责：

- 管理模型和代码；
- 运行 RKNN-Toolkit2；
- 将 ONNX 转为 RKNN；
- 模拟运行 RKNN；
- 编译开发板使用的 ARM64 程序；
- 将最终文件发送给开发板。

WSL 本身不是 RK3588，没有 RK3588 NPU，因此主要负责“开发和准备”。

## 2. RK3588 开发板：部署端

你的开发板是：

```text
ATK-DLRK3588
Buildroot Linux
aarch64
8 核 CPU
16 GB 内存
RK3588 NPU
IP：192.168.1.121
```

它负责：

- 加载 `.rknn` 模型；
- 通过 RKNN Runtime 调用 NPU；
- 执行真实硬件推理；
- 输出最终分类结果。

简而言之：

```text
WSL：制作模型和程序
开发板：运行模型和程序
```

---

# 二、建立项目和 Python 虚拟环境

项目目录是：

```text
~/rk3588-ai
```

虚拟环境是：

```text
~/rk3588-ai/.venv
```

进入项目并启用环境：

```bash
cd ~/rk3588-ai
source .venv/bin/activate
```

启用后，终端出现：

```text
(.venv)
```

## 为什么需要 `.venv`

RKNN-Toolkit2 对 Python 包版本比较敏感，例如它要求：

```text
numpy <= 1.26.4
protobuf <= 4.25.4
```

如果直接把这些包装到系统 Python 中，可能影响其他项目。因此使用 `.venv` 把依赖隔离在当前项目中：

```text
~/rk3588-ai/.venv/lib/python3.12/site-packages
```

`.venv` 隔离的是 Python 解释器和 Python 包，不负责隔离：

- GCC；
- CMake；
- Linux 系统库；
- 开发板驱动；
- RK3588 NPU。

这些仍属于系统级环境。

---

# 三、安装 RKNN-Toolkit2

你安装的是：

```text
RKNN-Toolkit2 2.3.2
```

验证命令：

```bash
python -m pip show rknn-toolkit2
```

以及：

```bash
python -c "from rknn.api import RKNN; print('导入成功')"
```

## RKNN-Toolkit2 是什么

RKNN-Toolkit2 是运行在开发电脑上的模型转换工具，主要功能包括：

- 读取 ONNX、TensorFlow、PyTorch等来源的模型；
- 对模型进行图优化；
- 对模型进行量化；
- 将模型转换成 `.rknn`；
- 在电脑端模拟推理；
- 对模型进行精度和性能分析。

它不是开发板上的 NPU 驱动，也不是板端 C++ 运行库。

三者关系如下：

| 组件 | 运行位置 | 主要作用 |
|---|---|---|
| RKNN-Toolkit2 | WSL/x86_64 | 转换和分析模型 |
| RKNN Runtime | RK3588/aarch64 | 板端加载和运行 RKNN |
| RKNPU 驱动 | RK3588 内核 | 控制实际 NPU 硬件 |

---

# 四、获取官方 RKNN Model Zoo

最开始下载的 `rknn-toolkit2` 仓库主要提供：

- Python 安装包；
- Runtime；
- API 文档；
-基础示例和工具。

为了获得完整模型、转换程序和 C++ Demo，我们又下载了：

```text
rknn_model_zoo 2.3.2
```

位置是：

```text
~/rk3588-ai/tools/rknn_model_zoo
```

## Model Zoo 是什么

它是瑞芯微提供的模型部署示例集合，包含：

- MobileNet；
- ResNet；
- YOLO；
- OCR；
- 图像分割；
-姿态识别等。

我们使用的 MobileNet 目录是：

```text
rknn_model_zoo/examples/mobilenet
```

主要结构为：

```text
mobilenet/
├── model/
│   ├── mobilenetv2-12.onnx
│   ├── bell.jpg
│   └── synset.txt
├── python/
│   └── mobilenet.py
└── cpp/
    ├── main.cc
    └── rknpu2/
```

各部分作用：

- `model`：原始模型、测试图片和类别标签；
- `python`：负责模型转换及电脑端模拟推理；
- `cpp`：负责开发板上的真实推理。

---

# 五、准备 MobileNetV2 ONNX 模型

使用的原始模型是：

```text
mobilenetv2-12.onnx
```

## ONNX 是什么

ONNX 是一种通用神经网络模型格式。

例如，一个模型最初可能来自：

- PyTorch；
- TensorFlow；
- PaddlePaddle。

将它导出成 ONNX 后，模型结构和参数可以交给其他推理框架处理。

ONNX 的优势是通用，但它不能直接充分利用 RK3588 NPU。因此需要进一步转换：

```text
ONNX → RKNN
```

## MobileNetV2 做什么

MobileNetV2 是一个图像分类网络：

```text
输入：一张图片
输出：图片属于1000个ImageNet类别的概率
```

它的输入形状是：

```text
1 × 224 × 224 × 3
```

含义是：

- `1`：一次输入一张图片；
- `224 × 224`：图片尺寸；
- `3`：RGB 三个颜色通道。

它的输出是：

```text
1 × 1000
```

即对 ImageNet 的 1000 个类别分别给出一个分数。

---

# 六、ONNX 转换成 RKNN

我们执行了：

```bash
cd ~/rk3588-ai/tools/rknn_model_zoo/examples/mobilenet/python

python mobilenet.py \
  --model ../model/mobilenetv2-12.onnx \
  --target rk3588 \
  --dtype i8 \
  --output_path ../model/mobilenetv2-12.rknn
```

## 参数分别代表什么

### `--model`

```text
../model/mobilenetv2-12.onnx
```

指定输入的通用 ONNX 模型。

### `--target rk3588`

告诉转换器：

```text
这个模型最终要在 RK3588 上运行
```

不同芯片的 NPU：

- 支持的算子可能不同；
- 内存布局可能不同；
- 优化策略可能不同；
- NPU 核心结构可能不同。

所以转换时必须明确目标平台。

### `--dtype i8`

表示将模型量化成 INT8。

模型原始参数通常使用 FP32，即32位浮点数。INT8 只使用8位整数。

量化的主要效果：

- 模型更小；
- 内存占用更低；
- NPU 推理更快；
- 功耗通常更低；
- 可能产生少量精度损失。

这次生成的 RKNN 模型约为：

```text
4.0 MB
```

### `--output_path`

指定输出文件：

```text
mobilenetv2-12.rknn
```

这就是最终交给 RK3588 Runtime 加载的模型。

---

# 七、转换脚本内部做了什么

`mobilenet.py` 主要完成以下步骤。

## 1. 创建 RKNN 对象

概念上相当于：

```python
rknn = RKNN()
```

这个对象用于控制整个模型转换过程。

## 2. 配置预处理参数

脚本配置了 MobileNet 所需的均值和标准差。

图片原始像素通常是：

```text
0～255
```

而模型训练时使用了归一化数据，因此推理前必须用同样的方式处理。

如果训练和推理的预处理不一致，即使模型运行成功，分类结果也会错误。

## 3. 加载 ONNX

```python
rknn.load_onnx(...)
```

这个步骤读取：

- 网络结构；
- 卷积层；
- 激活函数；
- 权重参数；
- 输入和输出信息。

然后检查 RKNN-Toolkit2 是否支持模型使用的算子。

## 4. 构建和量化模型

```python
rknn.build(do_quantization=True, dataset=...)
```

该过程会：

- 优化计算图；
- 融合部分算子；
- 统计校准图片的数据分布；
- 将浮点权重和中间数据量化成 INT8；
- 生成适合 RK3588 NPU 的内部结构。

## 5. 导出 RKNN

```python
rknn.export_rknn(...)
```

最终生成：

```text
mobilenetv2-12.rknn
```

---

# 八、解决 ONNX 版本冲突

第一次转换时出现：

```text
AttributeError: module 'onnx' has no attribute 'mapping'
```

原因不是模型错误，而是：

```text
RKNN-Toolkit2 2.3.2
```

内部仍调用 `onnx.mapping`，但新版 ONNX 已删除或改变了这个接口。

因此把版本调整为：

```text
onnx 1.18.0
onnxruntime 1.18.0
```

但 pip 在降级时又自动安装了过新的：

```text
numpy 2.5.1
protobuf 7.35.1
```

它们又不符合 RKNN-Toolkit2 的要求，所以最终修正为：

```text
numpy 1.26.4
protobuf 4.25.4
onnx 1.18.0
onnxruntime 1.18.0
rknn-toolkit2 2.3.2
```

这个过程说明了一个重要问题：

> Python 包不是版本越新越好，而是整套依赖需要彼此兼容。

可以用下面的命令检查依赖关系：

```bash
python -m pip check
```

---

# 九、在 WSL 中模拟推理

转换完成后，官方 `mobilenet.py` 继续执行了模拟推理。

它读取：

```text
bell.jpg
```

然后：

1. 将图片缩放到 `224×224`；
2. 根据模型要求进行归一化；
3. 送入 RKNN 模拟器；
4. 得到 1000 个类别分数；
5. 选出分数最高的5个类别；
6. 使用 `synset.txt` 将类别编号转换为文字。

WSL 结果为：

```text
[494] score=0.98 class="chime, bell, gong"
```

这说明：

- ONNX 模型读取正常；
- RKNN 转换正常；
- INT8 量化没有导致严重精度损失；
- 图片预处理正常；
- 输出后处理正常。

但这里仍属于电脑端模拟，不代表已经使用 RK3588 NPU。

---

# 十、为什么还需要编译 C++ Demo

`.rknn` 文件只保存模型本身，它不能自己运行。

还需要一个应用程序完成：

1. 读取图片；
2. 加载 `.rknn`；
3. 初始化 RKNN Runtime；
4. 分配输入输出内存；
5. 把图片交给模型；
6. 启动 NPU 推理；
7. 读取输出；
8. 查找 Top-5 类别；
9. 打印结果。

这个应用就是：

```text
rknn_mobilenet_demo
```

源代码在：

```text
examples/mobilenet/cpp
```

---

# 十一、为什么使用交叉编译

WSL 是：

```text
x86_64
```

RK3588 开发板是：

```text
aarch64
```

普通的 WSL GCC 默认生成 x86_64 程序，放到开发板上不能运行。

因此使用：

```text
aarch64-linux-gnu-gcc
aarch64-linux-gnu-g++
```

它们运行在 x86_64 WSL 中，但生成 ARM64 程序，这就是交叉编译：

```text
编译器运行平台：x86_64
生成程序平台：aarch64
```

你安装的版本是：

```text
aarch64-linux-gnu-g++ 13.3.0
```

---

# 十二、编译 Linux ARM64 Demo

执行：

```bash
cd ~/rk3588-ai/tools/rknn_model_zoo

./build-linux.sh \
  -t rk3588 \
  -a aarch64 \
  -d mobilenet
```

参数含义：

- `-t rk3588`：选择 RK3588 的 Runtime 和编译配置；
- `-a aarch64`：生成64位 ARM 程序；
- `-d mobilenet`：编译 MobileNet 示例。

## 脚本内部做了什么

脚本设置：

```text
CC=aarch64-linux-gnu-gcc
CXX=aarch64-linux-gnu-g++
```

然后调用：

```text
CMake → Make → Make Install
```

具体过程：

1. CMake 分析项目和依赖；
2. GCC/G++ 编译 `.c` 和 `.cc` 文件；
3. 链接 RKNN Runtime、RGA 等库；
4. 生成 ARM64 可执行程序；
5. 整理板端安装目录。

最终产生：

```text
install/rk3588_linux_aarch64/rknn_mobilenet_demo
```

## 编译警告为什么没有影响

编译中出现过：

```text
implicit declaration of function cos
implicit declaration of function sin
```

以及一些指针类型警告。

但最终出现：

```text
[100%] Built target rknn_mobilenet_demo
```

这说明编译和链接已经完成。警告表示代码存在不够严谨的写法，但不是阻止生成程序的错误。

一般判断规则是：

- `warning`：需要关注，但不一定失败；
- `error`：通常会中断编译；
- `Built target`：目标已经生成。

---

# 十三、为什么模型没有自动进入安装目录

编译完成后提示：

```text
The RKNN model can not be found in .../model
```

这不是 C++ 编译失败。

原因是构建系统没有自动匹配到我们指定名称的 RKNN 文件，于是我们手动复制：

```bash
cp \
  examples/mobilenet/model/mobilenetv2-12.rknn \
  install/rk3588_linux_aarch64/rknn_mobilenet_demo/model/
```

最终部署包包含：

```text
rknn_mobilenet_demo/
├── rknn_mobilenet_demo
├── lib/
│   ├── librknnrt.so
│   └── librga.so
└── model/
    ├── mobilenetv2-12.rknn
    ├── bell.jpg
    └── synset.txt
```

## 每个文件的作用

### `rknn_mobilenet_demo`

ARM64 C++ 应用，负责组织整个推理流程。

### `librknnrt.so`

RKNN Runtime 动态库，负责：

- 加载 RKNN；
- 创建运行上下文；
- 调用 NPU；
- 管理输入输出。

### `librga.so`

Rockchip 图像加速库，可用于：

- 图片缩放；
- 格式转换；
- 图像裁剪。

### `mobilenetv2-12.rknn`

已经转换并量化好的 NPU 模型。

### `bell.jpg`

测试图片。

### `synset.txt`

ImageNet 1000 个类别的名称。

---

# 十四、开发板联网与地址确认

开发板通过 Wi-Fi 获得：

```text
192.168.1.121
```

WSL 在相同局域网中的地址是：

```text
192.168.1.39
```

两者都属于：

```text
192.168.1.0/24
```

因此可以直接通过局域网通信。

之前开发板 Wi-Fi 被 RF-kill 软件阻止，我们执行过：

```sh
rfkill unblock 2
ip link set wlan0 up
```

又启动了 ConnMan：

```sh
/etc/init.d/S45connman start
```

最终 `wlan0` 进入：

```text
UP, LOWER_UP
```

并获得 IP，说明无线链路和 DHCP 都已成功。

---

# 十五、为什么使用 SCP

我们使用：

```bash
scp -r \
  install/rk3588_linux_aarch64/rknn_mobilenet_demo \
  root@192.168.1.121:/rknn_test/
```

或者传到：

```text
/userdata/
```

SCP 基于 SSH，作用是把 WSL 文件安全复制到开发板。

参数含义：

- `scp`：复制文件；
- `-r`：递归复制整个目录；
- 本地路径：已经准备好的部署包；
- `root@192.168.1.121`：开发板账户和 IP；
- 最后路径：开发板保存位置。

为什么要传整个目录，而不是只传 `.rknn`：

因为板端运行还需要：

- 可执行程序；
- RKNN Runtime；
- RGA；
- 测试图片；
- 分类标签。

---

# 十六、开发板上启动 Demo

开发板中的实际目录是：

```text
/rknn_test/rknn_mobilenet_demo
```

进入目录：

```sh
cd /rknn_test/rknn_mobilenet_demo
```

增加执行权限：

```sh
chmod +x rknn_mobilenet_demo
```

Linux 文件除了具有内容，还具有权限属性。没有 `x` 权限时，即使它是正确的 ARM64 程序也不能直接启动。

设置动态库搜索路径：

```sh
export LD_LIBRARY_PATH=/rknn_test/rknn_mobilenet_demo/lib
```

## 为什么设置 `LD_LIBRARY_PATH`

程序运行时需要找到：

```text
librknnrt.so
librga.so
```

这些库不一定安装在 Buildroot 的系统库目录，所以需要明确告诉动态链接器：

```text
优先从当前 Demo 的 lib 目录寻找动态库
```

这个环境变量只对当前终端及其子进程生效，重启或退出终端后通常需要重新设置。

---

# 十七、在 RK3588 上执行真实 NPU 推理

运行命令：

```sh
./rknn_mobilenet_demo \
  model/mobilenetv2-12.rknn \
  model/bell.jpg
```

两个参数分别是：

1. RKNN 模型路径；
2. 输入图片路径。

程序输出了模型信息：

```text
model input num: 1, output num: 1
```

表示模型有：

- 一个输入；
- 一个输出。

输入信息：

```text
dims=[1, 224, 224, 3]
fmt=NHWC
```

含义：

```text
批数量 × 高度 × 宽度 × 通道
1 × 224 × 224 × 3
```

输出信息：

```text
dims=[1, 1000]
```

表示输出1000个类别分数。

随后出现：

```text
rknn_run
```

这表示程序通过 RKNN Runtime 启动了模型推理。

最终结果：

```text
[494] score=0.993227 class=chime, bell, gong
```

测试图片本身是一口钟，因此结果正确。

这一步才证明：

- ARM64 程序可以运行；
- RKNN Runtime 可以加载；
- `.rknn` 模型兼容开发板；
- NPU 驱动可以工作；
- 模型成功在 RK3588 上推理；
- 输出结果正确。

---

# 十八、关于 RGA 对齐提示

运行时出现：

```text
src width is not 4/16-aligned, convert image use cpu
```

原始图片尺寸是：

```text
500 × 333
```

RGA 对部分图像格式和操作有宽度、步长对齐要求。宽度500在当前处理方式下不满足所需对齐，所以程序自动退回 CPU 进行图片转换。

这表示：

```text
图片预处理：CPU
神经网络推理：NPU
```

它不会导致模型错误，只是图片缩放和格式转换没有使用 RGA 加速。

对于单张 MobileNet 图片，影响很小。以后做摄像头实时 YOLO 时，才需要更认真地处理：

- RGA 对齐；
- 零拷贝；
- DMA Buffer；
- 图像格式；
-预处理耗时。

---

# 十九、这次结果证明了什么

你已经验证了端侧 AI 部署中的完整关键环节：

1. WSL 开发环境可用；
2. Python 虚拟环境可用；
3. RKNN-Toolkit2 2.3.2 可用；
4. ONNX 模型有效；
5. INT8 量化成功；
6. RKNN 模型生成成功；
7. WSL 模拟推理结果正确；
8. ARM64 交叉编译成功；
9. SCP 网络传输成功；
10. 板端动态库加载成功；
11. RK3588 NPU 推理成功；
12. 分类结果正确。

这已经不是单纯“把一个文件放到板子里”，而是完成了一次标准的模型部署工程。

---

# 二十、以后部署其他模型也遵循同一套思路

无论以后是：

- ResNet；
- YOLOv5；
- YOLOv8；
- 车牌识别；
- 人脸检测；
- 图像分割；
- 自己训练的模型；

主流程都不会发生根本变化：

```text
1. 获得训练完成的模型
2. 导出为 ONNX
3. 确认输入输出和预处理
4. 准备量化校准数据
5. 使用 RKNN-Toolkit2 转换
6. 在电脑端验证 RKNN 结果
7. 编写或修改板端推理程序
8. 交叉编译为 ARM64
9. 打包模型、程序和动态库
10. 传输到开发板
11. 初始化 RKNN Runtime
12. 通过 NPU执行推理
13. 后处理并验证结果
14. 测量性能和优化
```

MobileNet 的后处理只是找 Top-5，因此很简单。YOLO 的主要区别是输出后还需要：

- 解析检测框；
- 置信度过滤；
- NMS 非极大值抑制；
- 坐标映射；
- 在图片上绘制框。

但从 ONNX 转 RKNN、编译、传输到 NPU 运行的主线完全相同。