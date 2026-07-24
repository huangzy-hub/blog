---
title: usb免驱摄像头在开发板上的使用
published: 2026-03-18
pinned: false
description: usb免驱摄像头在开发板上的使用.
tags: [liunx, 应用, 摄像头]
category: 嵌入式
draft: false
---



# 嵌入式Linux USB摄像头视频操作说明
## 一、文档说明
### 1.1 适用场景
基于嵌入式Linux开发板（如Kickpi）操作USB免驱UVC摄像头，通过`v4l2-ctl`/`ffmpeg`工具实现视频分辨率、帧率、像素格式、图像参数、显示尺寸等核心属性的查询、配置、验证与调优。
### 1.2 前置条件
- 开发板已识别摄像头（生成`/dev/video0`设备节点）；
- 已安装必备工具：`v4l-utils`（含`v4l2-ctl`）、`ffmpeg`；
- 摄像头兼容UVC协议（免驱）；
- 开发板与操作终端（电脑）处于同一局域网（可选，用于文件传输验证）。

## 二、核心工具与基础概念
### 2.1 核心工具
| 工具         | 核心用途                          | 优势                     |
|--------------|-----------------------------------|--------------------------|
| `v4l2-ctl`   | 视频属性底层查询/配置（基于V4L2） | 参数覆盖全、纯命令行、无图形依赖 |
| `ffmpeg`     | 格式转换/采集/显示/缩放          | 兼容多格式、支持远程推流/截图/画面缩放 |

### 2.2 关键视频属性说明
| 属性分类       | 具体属性         | 说明                                                                 | 常见取值                     |
|----------------|------------------|----------------------------------------------------------------------|------------------------------|
| 基础采集属性   | 像素格式         | 摄像头输出数据格式（压缩/原始）| MJPG（压缩，高帧率）、YUYV（原始，无损） |
|                | 采集分辨率       | 摄像头输出的原始视频尺寸（宽×高），硬件级基础分辨率                   | 320×240、640×480、1280×720（720P） |
|                | 帧率（fps）      | 每秒采集的帧数（越高画面越流畅）| 15/30/60fps（MJPG）、10/30fps（YUYV） |
| 图像调优属性   | 亮度/对比度/锐度 | 调整画面明暗、层次感、细节锐度，提升主观清晰度                       | 亮度：0-255、对比度：0-255、锐度：0-100 |
|                | 白平衡/曝光      | 调整画面色彩还原度、进光量，避免偏色/忽明忽暗                         | 色温：2000-6500K、曝光值：1-10000 |
| 显示适配属性   | 显示尺寸（缩放） | 对采集的视频画面缩放后显示，不改变原始采集分辨率                     | 按需求缩放（如720P→480P、480P→240P） |

## 三、视频属性操作步骤
### 3.1 基础操作：查询摄像头支持的所有属性
#### 3.1.1 查询支持的格式/分辨率/帧率（硬件能力）
```bash
v4l2-ctl --device=/dev/video0 --list-formats-ext
```
**输出解读**：
- `[0]: 'YUYV' (YUYV 4:2:2)`：原始像素格式；
- `[1]: 'MJPG' (Motion-JPEG)`：压缩像素格式；
- `Size: Discrete 640x480 + Interval: Discrete 0.033s (30.000 fps)`：支持的分辨率+帧率组合。

#### 3.1.2 查询可调节的图像参数
```bash
v4l2-ctl --device=/dev/video0 --list-ctrls
```
**输出解读**：
```
brightness 0x00980900 (int)    : min=0 max=255 step=1 default=128 value=128
contrast 0x00980901 (int)      : min=0 max=255 step=1 default=128 value=128
sharpness 0x0098091b (int)     : min=0 max=100 step=1 default=50 value=50
white_balance_temperature_auto 0x0098090c (bool) : default=1 value=1
```
- `min/max`：参数可调范围；`default`：出厂默认值；`bool`类型：1=开启（自动）、0=关闭（手动）。

### 3.2 核心配置：采集属性（分辨率/帧率/像素格式）
#### 3.2.1 设置像素格式+分辨率+帧率（推荐MJPG高帧率）
```bash
# 方案1：640×480 + MJPG + 60fps（平衡清晰+流畅）
v4l2-ctl --device=/dev/video0 \
  --set-fmt-video=width=640,height=480,pixelformat=MJPG \
  --set-parm=60

# 方案2：1280×720 + MJPG + 30fps（最高清，硬件上限）
v4l2-ctl --device=/dev/video0 \
  --set-fmt-video=width=1280,height=720,pixelformat=MJPG \
  --set-parm=30

# 方案3：320×240 + MJPG + 60fps（流畅优先，低功耗）
v4l2-ctl --device=/dev/video0 \
  --set-fmt-video=width=320,height=240,pixelformat=MJPG \
  --set-parm=60
```
**参数说明**：
- `pixelformat`：MJPG（压缩）/YUYV（原始）；
- `--set-parm`：指定帧率（需摄像头硬件支持）。

#### 3.2.2 仅修改采集分辨率（保留现有格式/帧率）
```bash
# 仅设置为720P采集分辨率
v4l2-ctl --device=/dev/video0 --set-fmt-video=width=1280,height=720
```

#### 3.2.3 验证采集配置是否生效
```bash
# 方式1：查询当前生效的采集格式
v4l2-ctl --device=/dev/video0 --get-fmt-video

# 方式2：通过ffmpeg验证
ffmpeg -f v4l2 -list_formats all -i /dev/video0
```

### 3.3 进阶配置：图像参数调优（提升清晰度/色彩）
#### 3.3.1 核心参数调优（按优先级）
```bash
# 1. 亮度：适中（避免过亮/过暗丢失细节），范围0-255，推荐150-170
v4l2-ctl --device=/dev/video0 --set-ctrl=brightness=160

# 2. 对比度：提升层次感（核心提升清晰度），范围0-255，推荐180-200
v4l2-ctl --device=/dev/video0 --set-ctrl=contrast=190

# 3. 锐度：强化边缘细节，范围0-100，推荐50-80
v4l2-ctl --device=/dev/video0 --set-ctrl=sharpness=70

# 4. 饱和度：增强色彩鲜艳度，范围0-255，推荐150-180
v4l2-ctl --device=/dev/video0 --set-ctrl=saturation=160

# 5. 关闭自动白平衡/曝光（避免画面波动）
v4l2-ctl --device=/dev/video0 --set-ctrl=white_balance_temperature_auto=0
v4l2-ctl --device=/dev/video0 --set-ctrl=white_balance_temperature=4500  # 4500K中性色温
v4l2-ctl --device=/dev/video0 --set-ctrl=exposure_auto=1  # 1=手动曝光
v4l2-ctl --device=/dev/video0 --set-ctrl=exposure_absolute=200  # 曝光值150-300
```

#### 3.3.2 恢复默认图像参数
```bash
# 重置所有图像参数为出厂默认值
v4l2-ctl --device=/dev/video0 --reset-ctrls=all
```

### 3.4 适配配置：显示尺寸（画面缩放）
#### 3.4.1 采集尺寸不变，缩放显示尺寸（帧缓冲显示）
```bash
# 示例1：720P采集（1280×720）→ 480P显示（640×480）
ffmpeg -i /dev/video0 -input_format mjpeg -video_size 1280x720 -vf "scale=640:480,format=bgra" -f fbdev /dev/fb0

# 示例2：480P采集（640×480）→ 240P显示（320×240）（更流畅）
ffmpeg -i /dev/video0 -input_format mjpeg -video_size 640x480 -vf "scale=320:240,format=bgra" -f fbdev /dev/fb0

# 示例3：按比例缩放（只设宽度，高度自动适配，避免拉伸）
ffmpeg -i /dev/video0 -input_format mjpeg -video_size 1280x720 -vf "scale=640:-1,format=bgra" -f fbdev /dev/fb0
```
**参数说明**：
- `scale=[宽]:[高]`：ffmpeg缩放滤镜，核心控制显示尺寸；
- `scale=640:-1`：`-1` 表示高度按原始比例自动计算，避免画面拉伸变形；
- `-format=bgra`：转换为帧缓冲支持的显示格式。
#### 3.4.2 改变视频在图片中的位置

```bash
ffmpeg -i /dev/video0 \
  -input_format mjpeg \
  -video_size 1280x720 \
  -vf "scale=924:550,format=bgra,pad=1024:600:x=100:y=50:color=black" \
  -f fbdev /dev/fb0
```

### 3.5 验证操作：采集/推流/文件传输
#### 3.5.1 采集指定属性的高清截图

```bash
# 1. 先配置摄像头为高清参数（必做）
v4l2-ctl --device=/dev/video0 --set-fmt-video=width=1920,height=1080,pixelformat=MJPG
# 2. 采集高清截图（指定分辨率/格式/质量）
ffmpeg -f v4l2 -input_format mjpeg -video_size 1920x1080 -i /dev/video0 -vframes 1 -q:v 1 hd_screenshot.jpg
# 将图片显示在屏幕上
# 核心命令：指定尺寸 + 强制覆盖 + 静默模式（消除所有无关提示）
sudo ffmpeg -y -loglevel quiet -i hd_screenshot.jpg -vf "scale=924:550,format=bgra" -f fbdev /dev/fb0
```

#### 3.5.2 录制视频

```bash
# ffmpeg视频采集
ffmpeg -f v4l2 -s 1920x1080 -r 30 -vcodec mjpeg -i /dev/video0 -b:v 8000k -an videocap.avi
 
# 更多参数
ffmpeg -f v4l2 -s 1920x1080 -r 30 -vcodec mjpeg -i /dev/video0 -pix_fmt yuv420p -b:v 2000k -vcodec libx264 -preset veryfast -an videocap1.mp4

# 视频播放
sudo ffmpeg -y -loglevel quiet -i videocap.avi -vf "scale=924:550,format=bgra" -f fbdev /dev/fb0 
```

#### 3.5.3 SCP上传文件到电脑（查看效果）
##### Windows电脑
```bash
# 上传720P截图到电脑桌面
scp root@192.168.1.100:/root/camera_720p.jpg C:\Users\你的用户名\Desktop\
```


## 四、视频在频幕上播放

## 五、代码控制视频

## 六、视频推流云端