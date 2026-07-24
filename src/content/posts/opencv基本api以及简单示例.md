---
title: opencv基本api以及简单示例
published: 2026-04-07
pinned: false
description: opencv基本api以及简单示例
tags: [opencv]
category: 嵌入式
draft: false
---

[菜鸟教程]（https://www.runoob.com/opencv/cpp-opencv-basic.html）

OpenCV 开发基础知识点笔记

# 一、图像基础与像素操作

## 1. 图像存储与通道

- **单通道**：对应灰度图/二值图，每个像素仅1个亮度值（0-255），类型为`CV_8UC1`。

- **三通道**：对应彩色图（BGR顺序），每个像素含B、G、R三个值，类型为`CV_8UC3`，通道顺序不可混淆。

- **四通道**：带透明通道（Alpha），类型为`CV_8UC4`，常用于PNG图像。

## 2. 像素访问方式（核心补充：`at`/`ptr` 本质）

关键前提：`at` 和 `ptr` 均为 OpenCV 自定义的 `cv::Mat` 类成员函数，并非 C++ 原生语法，是 OpenCV 开发者封装的像素访问工具，仅用于 `Mat` 图像对象的像素操作。

### （1）安全访问（`.at<>()`）

- 本质：OpenCV 封装的模板成员函数，内部会做**边界检查**，避免访问超出图像范围。

- 语法：`src.at<Vec3b>(y, x)[通道索引]`（彩色图）、`src.at<uchar>(y, x)`（灰度图）

- 函数原型（伪代码）：

template<typename T>
T& Mat::at(int row, int col); // 返回对应位置像素的引用

- 特点：安全、简单、性能稍慢，适合新手调试。

- 示例：

// 彩色图像素赋值
src.at<Vec3b>(y, x)[0] = x / 2;  // B通道
src.at<Vec3b>(y, x)[1] = y / 2;  // G通道
src.at<Vec3b>(y, x)[2] = 200;    // R通道

### （2）指针遍历（高效，`.ptr<>()`）

- 本质：OpenCV 封装的模板成员函数，直接返回**第 y 行第一个像素的内存地址（指针）**，内部不做边界检查。

- 语法：`src.ptr<uchar>(y)`（灰度图/底层字节访问）、`src.ptr<Vec3b>(y)`（彩色图像素访问）

- 函数原型（伪代码）：

template<typename T>
T* Mat::ptr(int row); // 返回第row行的起始指针

- 核心逻辑：先取行指针，再按列访问，无边界检查，性能优于`.at()`。

- 灰度图遍历：

for (int y = 0; y < src.rows; y++) {
    uchar* row_ptr = src.ptr<uchar>(y);  // 取第y行指针
    for (int x = 0; x < src.cols; x++) {
        row_ptr[x] = 255;  // 直接访问像素
    }
}

- 彩色图遍历（`Vec3b`方式）：

for (int y = 0; y < src.rows; y++) {
    Vec3b* row_ptr = src.ptr<Vec3b>(y);  // 取第y行指针
    for (int x = 0; x < src.cols; x++) {
        row_ptr[x][0] = x / 2;  // B通道
        row_ptr[x][1] = y / 2;  // G通道
        row_ptr[x][2] = 200;    // R通道
    }
}

### （3）单 / 多通道通用

`(int)(*(b.data + b.step[0] * row + b.step[1] * col + channel));`

## 3. 浅拷贝与深拷贝

- **浅拷贝**：直接赋值`Mat dst = src`，仅复制指针，共享像素数据，修改一方会影响另一方，易导致内存重复释放。

- **深拷贝**：`Mat dst = src.clone()`或`src.copyTo(dst)`，复制完整像素数据，两者完全独立，修改互不影响。

- 核心类比：与C++浅/深拷贝逻辑一致，`clone()`对应深拷贝，直接赋值对应浅拷贝。

## 4. 循环变量 `col` 与通道数、指针的关系

- `col` 是循环计数器，代表“当前处理的像素列数”，范围 `0 ~ src.cols-1`，循环次数 = 一行的像素总数（`src.cols`）。

- 关键关系：一行的总字节数 = 像素数（`src.cols`） × 通道数（`src.channels()`），而非 `col × 通道数`。

- 指针偏移逻辑：`curr_row`（当前行指针）的偏移量 = `col × 通道数`，即 `curr_row = 行首指针 + col × 通道数`（`curr_row` 是地址，`col×通道数` 是整数偏移量，两者类型不同，不可直接相等）。

- 示例（底层字节遍历）：

uchar* row_start = src.ptr<uchar>(y); // 行首指针（固定）
for (int col = 0; col < src.cols; col++) {
    int b = row_start[col * 3 + 0]; // col×3 是字节偏移量
    int g = row_start[col * 3 + 1];
    int r = row_start[col * 3 + 2];
}

## 5. 代码提取：图像基础操作核心函数（对应示例1）

### （1）图像创建

- 全零黑色图像：`Mat::zeros(高度, 宽度, 类型)`，示例：

Mat blackImage = Mat::zeros(400, 600, CV_8UC3); // 400x600 三通道黑色图

- 自定义彩色图像：`Mat(高度, 宽度, 类型, Scalar(B, G, R))`，示例：

Mat colorImage(400, 600, CV_8UC3, Scalar(255, 128, 0)); // B=255, G=128, R=0 蓝色图

### （2）图像读取、显示、保存

- 读取图像：`imread(图像路径, 读取模式)`（默认彩色，`IMREAD_GRAYSCALE` 为灰度）

- 显示图像：`imshow(窗口名, 图像)`，搭配 `waitKey(延迟时间)`（0为无限等待）

- 关闭窗口：`destroyAllWindows()`（关闭所有窗口）

- 保存图像：`imwrite(保存路径, 图像)`，支持jpg、png等格式，示例：

imwrite("test_output.jpg", saveImage); // 保存为jpg格式

### （3）图像裁剪（ROI）

- 语法：`Mat 裁剪图 = 原图(Rect(x, y, 宽度, 高度))`，注意：默认浅拷贝（共享数据）

- 深拷贝裁剪：`Mat 独立裁剪图 = 原图(Rect(x, y, 宽度, 高度)).clone()`，示例：

Mat croppedImage = srcImage(Rect(100, 100, 200, 200)); // 浅拷贝
Mat croppedClone = srcImage(Rect(100, 100, 200, 200)).clone(); // 深拷贝

### （4）图像缩放

- 核心函数：`resize(输入图, 输出图, 目标尺寸, x缩放比例, y缩放比例, 插值方式)`

- 关键参数：插值方式 `INTER_LINEAR`（线性插值，默认，适合缩放），示例：

Mat smallImage;
resize(testImage, smallImage, Size(100, 100), 0, 0, INTER_LINEAR); // 缩小到100x100

# 二、图像预处理核心操作

## 1. 颜色空间转换

- 核心函数：`cvtColor(输入, 输出, 转换类型)`

- 常用转换：

  - 彩色转灰度：`COLOR_BGR2GRAY`（人脸检测、边缘检测必备）

  - 灰度转彩色：`COLOR_GRAY2BGR`（用于在灰度图上绘制彩色文字/图形）

- 注意：`cvtColor`仅转换颜色空间，不改变像素数据本质。

## 2. 图像模糊（降噪）

- 核心函数：`GaussianBlur(输入, 输出, 核大小, sigmaX)`

- 参数说明：

  - 核大小：必须为正奇数（3、5、15等），数值越大模糊程度越强。

  - sigmaX：X方向高斯标准差，设为0时OpenCV自动计算。

- 示例：

Mat blurred;
GaussianBlur(src, blurred, Size(15, 15), 0);  // 15x15高斯模糊

## 3. 边缘检测

- 核心算法：Canny边缘检测，函数`Canny(灰度输入, 输出, 低阈值, 高阈值)`

- 阈值规则：

  - 低于低阈值：直接丢弃（非边缘）

  - 高于高阈值：保留（强边缘）

  - 介于两者之间：与强边缘连通则保留，否则丢弃

- 示例：

Mat gray;
cvtColor(src, gray, COLOR_BGR2GRAY);
Mat edges;
Canny(gray, edges, 50, 150);  // 经典阈值组合

## 4. 二值化

- 核心函数：`threshold(灰度输入, 输出, 阈值, 最大值, 类型)`

- 常用类型：`THRESH_BINARY`（大于阈值设为最大值，否则设为0）

- 示例：

Mat thresholded;
threshold(gray, thresholded, 128, 255, THRESH_BINARY);  // 阈值128二值化

## 5. 直方图均衡化

- 核心函数：`equalizeHist(输入, 输出)`（仅支持单通道图像）

- 作用：增强图像对比度，让暗部更亮、亮部更清晰，提升人脸检测等任务的成功率。

- 示例：

Mat equalized;
equalizeHist(gray, equalized);  // 灰度图均衡化

## 6. 图像反转

- 核心函数：`bitwise_not(输入, 输出)`，按位取反实现颜色反转，示例：

Mat inverted;
bitwise_not(image, inverted); // 反转图像颜色

## 7. 代码提取：图像处理核心函数（对应示例3）

- 核心流程：彩色图 → 灰度图 → 预处理（模糊/均衡化） → 边缘检测/二值化/反转

- 拼接显示：`hconcat(图1, 图2, 结果)`（水平拼接）、`vconcat(图1, 图2, 结果)`（垂直拼接），示例：

Mat row1, row2, result;
hconcat(showImage1, showGray, row1); // 水平拼接2张图
vconcat(row1, row2, result); // 垂直拼接2行图

# 三、图像绘制与拼接

## 1. 基础图形绘制

- 画圆：`circle(图像, 圆心坐标, 半径, 颜色, 线宽)`，线宽-1为实心填充。

circle(src, Point(150, 150), 80, Scalar(255, 255, 0), -1); // 青色实心圆

- 画矩形：`rectangle(图像, 左上角坐标, 右下角坐标, 颜色, 线宽)`，线宽-1为实心填充。

rectangle(src, Point(280, 80), Point(420, 220), Scalar(0, 255, 255), -1); // 黄色实心矩形

- 绘制文字：`putText(图像, 文字内容, 起始坐标, 字体, 字号, 颜色, 线宽)`

putText(src, "高斯模糊", Point(10, 30), FONT_HERSHEY_SIMPLEX, 0.7, Scalar(0, 255, 0), 2); // 绿色文字

## 2. 图像拼接

- 水平拼接：`hconcat(图1, 图2, 结果图)`，将两张图左右拼接。

- 垂直拼接：`vconcat(图1, 图2, 结果图)`，将两张图上下拼接。

- 示例（2行3列拼接）：

Mat row1, row2, result;
// 拼接第一行（3张图）
hconcat(showImage1, showGray, row1);
hconcat(row1, showBlurred, row1);
// 拼接第二行（3张图）
hconcat(showEdges, showThresh, row2);
hconcat(row2, showInverted, row2);
// 垂直拼接两行
vconcat(row1, row2, result);

## 3. 代码提取：图像绘制核心函数（对应示例2）

### （1）绘制直线

- 函数：`line(图像, 起点, 终点, 颜色, 线宽)`，示例：

line(canvas, Point(50, 50), Point(200, 50), Scalar(0, 0, 255), 3); // 红色直线

### （2）绘制椭圆

- 函数：`ellipse(图像, 中心, 轴长, 旋转角度, 起始角度, 终止角度, 颜色, 线宽)`，示例：

ellipse(canvas, Point(450, 300), Size(80, 50), 30, 0, 360, Scalar(255, 255, 0), 3); // 空心椭圆

### （3）绘制多边形

- 核心：通过`vector<Point>`定义顶点，调用`fillPoly`（填充）或`polylines`（空心），示例（简化）：

vector<Point> pts = {Point(100,200), Point(200,100), Point(300,200)};
fillPoly(canvas, pts, Scalar(0,255,0)); // 填充三角形

# 四、摄像头操作与视频处理（代码提取，对应示例4）

## 1. 核心类与函数

- 摄像头/视频读取类：`VideoCapture`，用于打开摄像头或视频文件

### （1）打开摄像头

VideoCapture cap(0); // 参数0表示默认摄像头
if (!cap.isOpened()) { // 检查摄像头是否打开成功
    cerr << "错误：无法打开摄像头！" << endl;
    return;
}

### （2）读取视频帧

- 语法：`cap >> 帧对象`，循环读取实现实时显示，示例：

Mat frame;
while (true) {
    cap >> frame; // 读取一帧
    if (frame.empty()) break; // 帧为空则退出
    imshow("摄像头", frame); // 显示帧
    if (waitKey(30) & 0xFF == 27) break; // ESC退出
}

### （3）获取摄像头参数

- 函数：`cap.get(参数标识)`，常用标识：

  - `CAP_PROP_FRAME_WIDTH`：帧宽度

  - `CAP_PROP_FRAME_HEIGHT`：帧高度

  - `CAP_PROP_FPS`：帧率

### （4）释放资源

cap.release(); // 释放摄像头
destroyAllWindows(); // 关闭所有窗口

### （5）实时图像处理

- 流程：读取帧 → 预处理（灰度、边缘检测等） → 拼接显示，示例：

Mat gray, edges, edgesColor;
cvtColor(frame, gray, COLOR_BGR2GRAY); // 转灰度
Canny(gray, edges, 50, 150); // 边缘检测
cvtColor(edges, edgesColor, COLOR_GRAY2BGR); // 灰度转彩色，便于拼接
hconcat(display, edgesColor, combined); // 拼接原图和边缘图
imshow("摄像头示例", combined);

# 五、人脸检测核心流程

## 1. 检测器初始化

- 声明级联分类器：`CascadeClassifier faceCascade;`

- 加载模型：`faceCascade.load("haarcascade_frontalface_default.xml");`（需指定模型文件路径）

## 2. 人脸检测

- 核心函数：`detectMultiScale(灰度图, 存储结果, 缩放比例, 最小邻域)`

- 结果存储：`vector<Rect> faces;`，每个`Rect`包含人脸的x、y坐标及宽、高。

## 3. 绘制检测结果

- 直接使用`Rect`对象绘制矩形：`rectangle(display, face, Scalar(0, 255, 0), 3);`

- 无需额外指定坐标，`face`已包含完整位置和大小信息。

## 4. 代码提取：人脸检测完整流程（对应示例5）

// 1. 加载分类器
CascadeClassifier faceCascade;
if (!faceCascade.load("haarcascade_frontalface_default.xml")) {
    cerr << "错误：无法加载人脸检测模型！" << endl;
    return;
}
// 2. 打开摄像头
VideoCapture cap(0);
if (!cap.isOpened()) { cerr << "无法打开摄像头！" << endl; return; }
// 3. 实时检测循环
Mat frame, gray;
vector<Rect> faces;
while (true) {
    cap >> frame;
    if (frame.empty()) break;
    Mat display = frame.clone();
    // 4. 预处理（灰度+均衡化，提升检测效果）
    cvtColor(frame, gray, COLOR_BGR2GRAY);
    equalizeHist(gray, gray);
    // 5. 检测人脸
    faceCascade.detectMultiScale(
        gray, faces, 1.1, 3, 0 | CASCADE_SCALE_IMAGE, Size(80, 80)
    );
    // 6. 绘制检测结果
    for (size_t i = 0; i < faces.size(); i++) {
        Rect face = faces[i];
        rectangle(display, face, Scalar(0, 255, 0), 3); // 人脸框
        putText(display, "人脸 " + to_string(i+1), Point(face.x, face.y-10),
                FONT_HERSHEY_SIMPLEX, 0.6, Scalar(0, 255, 0), 2);
    }
    // 7. 显示与退出
    imshow("人脸检测", display);
    if (waitKey(30) & 0xFF == 27) break; // ESC退出
}
// 8. 释放资源
cap.release();
destroyAllWindows();

### 关键参数说明（detectMultiScale）

- 缩放比例（1.1）：每次检测时图像缩小的比例，越小越精准但速度越慢。

- 最小邻居数（3）：过滤误检测，数值越大，检测越严格。

- 最小人脸尺寸（Size(80,80)）：忽略小于该尺寸的人脸，避免小噪声误检测。

# 六、核心易错点总结（补充版）

1.  **颜色顺序**：OpenCV中彩色图为**BGR**而非RGB，`Scalar(B, G, R)`，混淆会导致颜色显示错误。

2.  **输入类型**：Canny、threshold、equalizeHist、人脸检测均需**灰度图**输入，彩色图需先转换。

3.  **指针遍历**：`ptr<uchar>(y)`获取第y行指针，`p[x]`对应第x列像素，无`ptr(x,y)`写法，遍历需先取行再取列；不可用`ptr(y) += x`修改指针本身。

4.  **拷贝安全**：修改图像前务必深拷贝，避免浅拷贝导致的 unintended数据修改。

5.  **显示规则**：灰度图、二值图可直接`imshow`；绘制彩色文字/图形时，需先将单通道图转为BGR三通道图。

6.  **`Vec3b` 与 `[]` 运算符**：`Vec3b`是OpenCV自定义结构体，`[]`是重载运算符，`[0]`=B、`[1]`=G、`[2]`=R，不可混淆通道顺序。

7.  **`at`/`ptr` 本质**：两者均为`Mat`类的成员函数，`at`安全带边界检查，`ptr`高效无边界检查，不可当作C++原生语法使用。

8.  **循环变量 `col`**：`col`是像素列数，不是字节数，一行总字节数=像素数×通道数，指针偏移量=col×通道数。

9.  **摄像头/人脸检测**：需确保摄像头正常打开、人脸模型路径正确；`waitKey`延迟时间不可为0（否则会卡顿），建议30ms左右。

10. **图像裁剪**：默认浅拷贝，修改裁剪图会影响原图，需独立副本时用`clone()`。
