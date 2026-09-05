---
title: 嵌入式liunx应用开发笔记-进阶篇（三）
published: 2026-02-14
pinned: false
description: 在LED屏幕上显示jpeg和png图片。
tags: [liunx, 应用]
category: 嵌入式
series: 嵌入式 Linux 应用开发进阶
seriesOrder: 3
draft: false
---



# 在LED屏幕上显示jpeg图片

## 一、下载libjpeg库

- 配置工程； 
- 编译工程； 
- 安装和移植；


## 二、主要接口和结构体

```c
struct jpeg_decompress_struct cinfo; //记录着 jpeg 数据的详细信息，也保存着解码之后输出数据的详细信息。
struct jpeg_error_mgr jerr; //用于处理错误的对象。
```

### 1、解码操作的过程

⑴、创建 jpeg 解码对象； 
⑵、指定解码数据源； 
⑶、读取图像信息； 
⑷、设置解码参数； 
⑸、开始解码； 
⑹、读取解码后的数据； 
⑺、解码完毕； 
⑻、释放/销毁解码对象。



### 2、错误处理

error_exit 函数指针便指向了错误处理函数。使用 libjpeg 库函数 jpeg_std_error()会将 libjpeg 错误处理设置为默认处理方式。如下所示
- cinfo.err = jpeg_std_error(&jerr);

### 3、创建解码对象 
- jpeg_create_decompress(&cinfo);

### 4、设置数据源 
- jpeg_stdio_src(&cinfo, jpeg_file); 

### 5、读取 jpeg 文件的头信息 

- jpeg_read_header(&cinfo, TRUE); 

调用 jpeg_read_header()后，可以得到 jpeg 图像的一些信息，譬如 jpeg 图像的宽度、高度、颜色通道数
以及 colorspace 等，这些信息会赋值给 cinfo 对象中的相应成员变量，如下所示： 

```c
cinfo.image_width //jpeg 图像宽度 
cinfo.image_height //jpeg 图像高度 
cinfo.num_components //颜色通道数 
cinfo.jpeg_color_space //jpeg 图像的颜色空间 
```

### 6、设置解码处理参数 

在进行解码之前，我们可以对一些解码参数进行设置，这些参数都有一个默认值，调用jpeg_read_header()
函数后，这些参数被设置成相应的默认值。 
直接对 cinfo 对象的成员变量进行修改即可，这里介绍两个比较有代表性的解码处理参数： 
- 输出的颜色（cinfo.out_color_space）：默认配置为 RGB 颜色，也就是 JCS_RGB； 
- 图像缩放操作（cinfo.scale_num 和 cinfo.scale_denom）：libjpeg 可以设置解码出来的图像的大小，也就是与原图的比例。使用 scale_num 和 scale_denom 两个参数，解出来的图像大小就是scale_num/scale_denom，JPEG 当前仅支持 1/1、1/2、1/4、和 1/8 这几种缩小比例。默认是 1/1，也就是保持原图大小。譬如要将输出图像设置为原图的 1/2 大小，可进行如下设置： 

```c
cinfo.scale_num=1; 
cinfo.scale_denom=2;
```

### 7、开始解码 

- jpeg_start_decompress(&cinfo); 
在完成解压缩操作后，会将解压后的图像信息填充至 cinfo 结构中。


### 8、读取数据

接下来就可以读取解码后的数据了，数据是按照行读取的，解码后的数据按照从左到右、从上到下的顺
序存储，每个像素点对应的各颜色或灰度通道数据是依次存储，譬如一个 24-bit RGB 真彩色的图像中，一
行的数据存储模式为 B,G,R,B,G,R,B,G,R,...。 
libjpeg 默认解码得到的图像数据是 BGR888 格式，即 R 颜色在低 8 位、而 B 颜色在高 8 位。可以定义

```c
一个 BGR888 颜色类型，如下所示： 
typedef struct bgr888_color { 
 unsigned char red; 
 unsigned char green; 
 unsigned char blue; 
} __attribute__ ((packed)) bgr888_t; 
```

每次读取一行数据，计算每行数据需要的空间大小，比如 RGB 图像就是宽度×3（24-bit RGB 真彩色一个像素 3 个字节），灰度图就是宽度×1（一个像素 1 个字节）。 

```c
bgr888_t *line_buf = malloc(cinfo.output_width * cinfo.output_components); 
```

以上我们分配了一个行缓冲区，它的大小为 cinfo.output_width * cinfo.output_components，也就是输出图像的宽度乘上每一个像素的字节大小。我们除了使用 malloc 分配缓冲区外，还可以使用 libjpeg 的内存管理器来分配缓冲区，这个不再介绍！ 缓冲区分配好之后，接着可以调用 jpeg_read_scanlines()来读取数据，jpeg_read_scanlines()可以指定一次读多少行，但是目前该函数还只能支持一次只读 1 行；函数如下所示： 

```c
jpeg_read_scanlines(&cinfo, &buf, 1); 
```

1 表示每次读取的行数，通常都是将其设置为 1。  
cinfo.output_scanline 表示接下来要读取的行对应的索引值，初始化为 0（表示第一行）、1 表示第二行等，每读取一行数据，该变量就会加 1，所以我们可以通过下面这种循环方式依次读取解码后的所有数据：

```c
while(cinfo.output_scanline < cinfo.output_height) 
{ 
 jpeg_read_scanlines(&cinfo, buffer, 1); 
 //do something 
} 
```

### 9、结束解码

- jpeg_finish_decompress(&cinfo); 

### 10、释放/销毁解码对象 

- jpeg_destroy_decompress(&cinfo); 

## 三、示例代码

```c
#include <stdio.h> 
#include <stdlib.h> 
#include <sys/types.h> 
#include <sys/stat.h> 
#include <fcntl.h> 
#include <unistd.h> 
#include <sys/ioctl.h> 
#include <string.h> 
#include <linux/fb.h> 
#include <sys/mman.h>  
  
#include <jpeglib.h> 
 
typedef struct bgr888_color { 
 unsigned char red; 
 unsigned char green; 
 unsigned char blue; 
} __attribute__ ((packed)) bgr888_t; 
 
static int width; //LCD X 分辨率 
static int height; //LCD Y 分辨率 
static unsigned short *screen_base = NULL; //映射后的显存基地址 
static unsigned long line_length; //LCD 一行的长度（字节为单位） 
static unsigned int bpp; //像素深度 bpp 
 
static int show_jpeg_image(const char *path) 
{ 
 struct jpeg_decompress_struct cinfo; 
 struct jpeg_error_mgr jerr; 
 FILE *jpeg_file = NULL; 
 bgr888_t *jpeg_line_buf = NULL; //行缓冲区:用于存储从 jpeg 文件中解压出来的一行图像数据 
 unsigned short *fb_line_buf = NULL; //行缓冲区:用于存储写入到 LCD 显存的一行数据 
 unsigned int min_h, min_w; 
 unsigned int valid_bytes; 
 int i; 
 
 //绑定默认错误处理函数 
 cinfo.err = jpeg_std_error(&jerr); 
 
 //打开.jpeg/.jpg 图像文件 
 jpeg_file = fopen(path, "r"); //只读方式打开 
 if (NULL == jpeg_file) { 
 perror("fopen error"); 
 return -1; 
 } 
 
 //创建 JPEG 解码对象 
 jpeg_create_decompress(&cinfo); 
 
 //指定图像文件 
 jpeg_stdio_src(&cinfo, jpeg_file); 
 
 //读取图像信息 
 jpeg_read_header(&cinfo, TRUE);  
 

 printf("jpeg 图像大小: %d*%d\n", cinfo.image_width, cinfo.image_height); 
 
 //设置解码参数 
 cinfo.out_color_space = JCS_RGB;//默认就是 JCS_RGB 
 //cinfo.scale_num = 1; 
 //cinfo.scale_denom = 2; 
 
 //开始解码图像 
 jpeg_start_decompress(&cinfo); 
 
 //为缓冲区分配内存空间 
 jpeg_line_buf = malloc(cinfo.output_components * cinfo.output_width); 
 fb_line_buf = malloc(line_length); 
 
 //判断图像和 LCD 屏那个的分辨率更低 
 if (cinfo.output_width > width) 
 min_w = width; 
 else 
 min_w = cinfo.output_width; 
 
 if (cinfo.output_height > height) 
 min_h = height; 
 else 
 min_h = cinfo.output_height; 
 
 //读取数据 
 valid_bytes = min_w * bpp / 8;//一行的有效字节数 表示真正写入到 LCD 显存的一行数据的大小 
 while (cinfo.output_scanline < min_h) { 
 
 jpeg_read_scanlines(&cinfo, (unsigned char **)&jpeg_line_buf, 1);//每次读取一行数据 
 
 //将读取到的 BGR888 数据转为 RGB565 
 for (i = 0; i < min_w; i++) 
 fb_line_buf[i] = ((jpeg_line_buf[i].red & 0xF8) << 8) | 
 ((jpeg_line_buf[i].green & 0xFC) << 3) | 
 ((jpeg_line_buf[i].blue & 0xF8) >> 3); 
 
 memcpy(screen_base, fb_line_buf, valid_bytes); 
 screen_base += width;//+width 定位到 LCD 下一行显存地址的起点 
 } 
 
 //解码完成 
 jpeg_finish_decompress(&cinfo); //完成解码  
 
 jpeg_destroy_decompress(&cinfo);//销毁 JPEG 解码对象、释放资源 
 
 //关闭文件、释放内存 
 fclose(jpeg_file); 
 free(fb_line_buf); 
 free(jpeg_line_buf); 
 return 0; 
} 
 
int main(int argc, char *argv[]) 
{ 
 struct fb_fix_screeninfo fb_fix; 
 struct fb_var_screeninfo fb_var; 
 unsigned int screen_size; 
 int fd; 
 
 /* 传参校验 */ 
 if (2 != argc) { 
 fprintf(stderr, "usage: %s <jpeg_file>\n", argv[0]); 
 exit(-1); 
 } 
 
 /* 打开 framebuffer 设备 */ 
 if (0 > (fd = open("/dev/fb0", O_RDWR))) { 
 perror("open error"); 
 exit(EXIT_FAILURE); 
 } 
 
 /* 获取参数信息 */ 
 ioctl(fd, FBIOGET_VSCREENINFO, &fb_var); 
 ioctl(fd, FBIOGET_FSCREENINFO, &fb_fix); 
 
 line_length = fb_fix.line_length; 
 bpp = fb_var.bits_per_pixel; 
 screen_size = line_length * fb_var.yres; 
 width = fb_var.xres; 
 height = fb_var.yres; 
 
 /* 将显示缓冲区映射到进程地址空间 */ 
 screen_base = mmap(NULL, screen_size, PROT_WRITE, MAP_SHARED, fd, 0); 
 if (MAP_FAILED == (void *)screen_base) { 
 perror("mmap error"); 
 close(fd);  
 
 exit(EXIT_FAILURE); 
 } 
 
 /* 显示 BMP 图片 */ 
 memset(screen_base, 0xFF, screen_size); 
 show_jpeg_image(argv[1]); 
 
 /* 退出 */ 
 munmap(screen_base, screen_size); //取消映射 
 close(fd); //关闭文件 
 exit(EXIT_SUCCESS); //退出进程 
} 

```


# 在LED屏幕上显示png图片

## 一、移植libpng和zlib库

- 配置工程； 
- 编译工程； 
- 安装和移植；

## 二、主要接口和结构体

### 1、libpng 的数据结构 

首先，使用 libpng 库需要包含它的头文件<png.h>。png.h 头文件中包含了 API、数据结构的申明，libpng中有两个很重要的数据结构体：png_struct 和 png_info。 png_struct 作为 libpng 库函数内部使用的一个数据结构体，除了作为传递给每个 libpng 库函数调用的第一个变量外，在大多数情况下不会被用户所使用。使用 libpng 之前，需要创建一个 png_struct 对象并对其进行初始化操作，该对象由 libpng 库内部使用，调用 libpng 库函数时，通常需要把这个对象作为参数传入。 png_info 数据结构体描述了 png 图像的信息，在以前旧的版本中，用户可以直接访问 png_info 对象中的成员，譬如查看图像的宽、高、像素深度、修改解码参数等；然而，这往往会导致出现一些问题，因此新的版本中专门开发了一组 png_info 对象的访问接口：get 方法 png_get_XXX 和 set 方法 png_set_XXX，建议大家通过 API 来访问这些成员。

### 2、创建和初始化 png_struct 对象 

```c
png_structp png_ptr = NULL; 
png_ptr = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL); 
if (!png_ptr) 
 return -1; 

```

### 3、创建和初始化 png_info 对象 

png_info数据结构体描述了png图像的信息，同样也需要创建png_info对象，调用png_create_info_struct()函数创建一个 png_info 对象，其函数原型如下所示： 

```c
png_infop png_create_info_struct(png_const_structrp png_ptr); 

```
```c
png_infop info_ptr = NULL; 
info_ptr = png_create_info_struct(png_const_structrp png_ptr); 
if (NULL == info_ptr) { 
 png_destroy_read_struct(&png_ptr, NULL, NULL); 
 return -1; 
}

```

### 4、设置错误返回点 

```c
/* 设置错误返回点 */ 
if (setjmp(png_jmpbuf(png_ptr))) { 
 png_destroy_read_struct(&png_ptr, &info_ptr, NULL); 
 return -1; 
} 
```

### 5、指定数据源 

```c
FILE *png_file = NULL; 
 
/* 打开 png 文件 */ 
png_file = fopen("image.png", "r"); //以只读方式打开 
if (NULL == png_file) { 
 perror("fopen error"); 
 return -1; 
} 
 
/* 指定数据源 */ 
png_init_io(png_ptr, png_file); 
```

### 6、读取 png 图像数据并解码 


### 7、读取解码后的数据 

解码完成之后，我们便可以去获取解码后的数据了，要么那它们做进一步的处理、要么直接刷入显存显示到 LCD 上；对于 low-level 方式，存放图像数据的缓冲区是由调用者分配的，所以直接从缓冲区中获取数据即可！ 对于 high-level 方式，存放图像数据的缓冲区是由 png_read_png()函数内部所分配的，并将缓冲区与png_struct 对象之间建立了关联，我们可以通过 png_get_rows()函数获取到指向每一行数据缓冲区的指针数组，如下所示： 

```c
png_bytepp row_pointers = NULL; 
row_pointers = png_get_rows(png_ptr, info_ptr);//获取到指向每一行数据缓冲区的指针数组 
```

当我们销毁 png_struct 对象时，由 png_read_png()所分配的缓冲区也会被释放归还给操作系统。

### 8、结束销毁对象 

调用 png_destroy_read_struct()销毁 png_struct 对象，该函数原型如下所示： 
- void png_destroy_read_struct(png_structpp png_ptr_ptr, png_infopp info_ptr_ptr, png_infopp end_info_ptr_ptr); 
使用方法如下： 
- png_destroy_read_struct(png_ptr, info_ptr, NULL); 

## 三、示例代码


```c
#include <stdio.h> 
#include <stdlib.h> 
#include <sys/types.h> 
#include <sys/stat.h> 
#include <fcntl.h> 
#include <unistd.h> 
#include <sys/ioctl.h> 
#include <string.h> 
#include <linux/fb.h> 
#include <sys/mman.h> 
#include <png.h> 
 
static int width; //LCD X 分辨率 
static int height; //LCD Y 分辨率 
static unsigned short *screen_base = NULL; //映射后的显存基地址 
static unsigned long line_length; //LCD 一行的长度（字节为单位） 
static unsigned int bpp; //像素深度 bpp 
 
static int show_png_image(const char *path) 
{ 
 png_structp png_ptr = NULL; 
 png_infop info_ptr = NULL; 
 FILE *png_file = NULL; 
 unsigned short *fb_line_buf = NULL; //行缓冲区:用于存储写入到 LCD 显存的一行数据 
 unsigned int min_h, min_w; 
 unsigned int valid_bytes; 
 unsigned int image_h, image_w; 
 png_bytepp row_pointers = NULL; 
 int i, j, k; 
 
 /* 打开 png 文件 */ 
 png_file = fopen(path, "r"); //以只读方式打开 
 if (NULL == png_file) { 
 perror("fopen error"); 
 return -1; 
 } 

 /* 分配和初始化 png_ptr、info_ptr */ 
 png_ptr = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL); 
 if (!png_ptr) { 
 fclose(png_file); 
 return -1; 
 } 
 
 info_ptr = png_create_info_struct(png_ptr); 
 if (!info_ptr) { 
 png_destroy_read_struct(&png_ptr, NULL, NULL); 
 fclose(png_file); 
 return -1; 
 } 
 
 /* 设置错误返回点 */ 
 if (setjmp(png_jmpbuf(png_ptr))) { 
 png_destroy_read_struct(&png_ptr, &info_ptr, NULL); 
 fclose(png_file); 
 return -1; 
 } 
 
 /* 指定数据源 */ 
 png_init_io(png_ptr, png_file); 
 
 /* 读取 png 文件 */ 
 png_read_png(png_ptr, info_ptr, PNG_TRANSFORM_STRIP_ALPHA, NULL); 
 image_h = png_get_image_height(png_ptr, info_ptr); 
 image_w = png_get_image_width(png_ptr, info_ptr); 
 printf("分辨率: %d*%d\n", image_w, image_h); 
 
 /* 判断是不是 RGB888 */ 
 if ((8 != png_get_bit_depth(png_ptr, info_ptr)) && 
 (PNG_COLOR_TYPE_RGB != png_get_color_type(png_ptr, info_ptr))) { 
 printf("Error: Not 8bit depth or not RGB color"); 
 png_destroy_read_struct(&png_ptr, &info_ptr, NULL); 
 fclose(png_file); 
 return -1; 
 } 
 
 /* 判断图像和 LCD 屏那个的分辨率更低 */ 
 if (image_w > width) 
 min_w = width; 
 else  
 
 min_w = image_w; 
 
 if (image_h > height) 
 min_h = height; 
 else 
 min_h = image_h; 
 
 valid_bytes = min_w * bpp / 8; 
 
 /* 读取解码后的数据 */ 
 fb_line_buf = malloc(valid_bytes); 
 row_pointers = png_get_rows(png_ptr, info_ptr);//获取数据 
 
 unsigned int temp = min_w * 3; //RGB888 一个像素 3 个 bit 位 
 for(i = 0; i < min_h; i++) { 
 
 // RGB888 转为 RGB565 
 for(j = k = 0; j < temp; j += 3, k++) 
 fb_line_buf[k] = ((row_pointers[i][j] & 0xF8) << 8) | 
 ((row_pointers[i][j+1] & 0xFC) << 3) | 
 ((row_pointers[i][j+2] & 0xF8) >> 3); 
 
 memcpy(screen_base, fb_line_buf, valid_bytes);//将一行数据刷入显存 
 screen_base += width; //定位到显存下一行 
 } 
 
 /* 结束、销毁/释放内存 */ 
 png_destroy_read_struct(&png_ptr, &info_ptr, NULL); 
 free(fb_line_buf); 
 fclose(png_file); 
 return 0; 
} 
 
int main(int argc, char *argv[]) 
{ 
 struct fb_fix_screeninfo fb_fix; 
 struct fb_var_screeninfo fb_var; 
 unsigned int screen_size; 
 int fd; 
 
 /* 传参校验 */ 
 if (2 != argc) { 
 fprintf(stderr, "usage: %s <png_file>\n", argv[0]);  
 
 exit(-1); 
 } 
 
 /* 打开 framebuffer 设备 */ 
 if (0 > (fd = open("/dev/fb0", O_RDWR))) { 
 perror("open error"); 
 exit(EXIT_FAILURE); 
 } 
 
 /* 获取参数信息 */ 
 ioctl(fd, FBIOGET_VSCREENINFO, &fb_var); 
 ioctl(fd, FBIOGET_FSCREENINFO, &fb_fix); 
 
 line_length = fb_fix.line_length; 
 bpp = fb_var.bits_per_pixel; 
 screen_size = line_length * fb_var.yres; 
 width = fb_var.xres; 
 height = fb_var.yres; 
 
 /* 将显示缓冲区映射到进程地址空间 */ 
 screen_base = mmap(NULL, screen_size, PROT_WRITE, MAP_SHARED, fd, 0); 
 if (MAP_FAILED == (void *)screen_base) { 
 perror("mmap error"); 
 close(fd); 
 exit(EXIT_FAILURE); 
 } 
 
 /* 显示 BMP 图片 */ 
 memset(screen_base, 0xFF, screen_size);//屏幕刷白 
 show_png_image(argv[1]); 
 
 /* 退出 */ 
 munmap(screen_base, screen_size); //取消映射 
 close(fd); //关闭文件 
 exit(EXIT_SUCCESS); //退出进程 
} 


```



# 使用FreeType显示字符
## 一、FreeType简介
FreeType是一个开源的字体渲染库，支持TrueType、OpenType等多种字体格式，能够将字体文件中的字符转换为点阵数据，供LCD显示使用，跨平台兼容性好，适配嵌入式Linux系统。

## 二、FreeType移植步骤

- 下载FreeType源码。
- 交叉编译FreeType源码
- 安装目录文件说明
- 编译完成后，安装目录下包含关键文件
- 移植到开发板




## 三、核心概念补充
### 1. 字形（glyph）
字符的具体图像表现形式，可理解为字符的书写风格。同一字符可对应多种字形，例如宋体的“国”与微软雅黑的“国”属于不同字形，其视觉呈现和笔画风格存在差异。

### 2. 字形索引
字体文件中查找字形的关键索引值，由字符编码转换而来。支持的字符编码包括ASCII编码、GB2312编码、BIG5编码、GBK编码及Unicode编码等，通过编码与索引的映射关系，可精准定位目标字形。

### 3. 像素点（pixel）、点（point）与dpi
- **像素点**：LCD显示的最小单位，例如800*480分辨率的LCD，水平方向有800个像素点，垂直方向有480个像素点，总像素数为800*480。
- **点（point）**：数字印刷中的物理单位，1点=1/72英寸（1英寸=25.4毫米）。
- **dpi（dots per inch）**：每英寸的像素点数，用于描述显示设备的密度。  
  像素点数与点数、dpi的换算公式：**像素点数 = 点数 * dpi / 72**  
  示例：水平方向点数为50，dpi为300，则像素点数=50*300/72≈208。

### 4. 字形布局
分为水平布局和垂直布局，决定字符的书写和显示方向，核心参数用于定位和约束字形显示规则：
#### （1）核心基准元素
- **原点（origin）**：字形定位的基准点，是水平基线（X轴）和垂直基线（Y轴）的交点。
- **基准线**：水平基线和垂直基线的统称，用于统一字符的对齐标准。
  - 水平布局：垂直基线在字形左侧，水平基线为字符上下对齐基准；
  - 垂直布局：水平基线在字形上方，垂直基线为字符左右对齐基准（常见于对联、古书文字）。

#### （2）关键度量参数
- **宽度（width）**：字形轮廓最左侧到最右侧的距离；
- **高度（height）**：字形轮廓最上边到最下边的距离；
  - 注：同一种字体中，不同字符的字形宽高可能不同（如大写“A”与小写“a”），部分字符可能宽高相等。
- **bearingX**：垂直基线到字形轮廓最左侧的距离。
  - 水平布局：字形在垂直基线右侧，bearingX为正数；
  - 垂直布局：字形在垂直基线居中放置，bearingX为负数。
- **bearingY**：水平基线到字形轮廓最上边的距离。
  - 垂直布局：字形在水平基线下方，bearingY为正数；
  - 水平布局：字形轮廓最上边在水平基线上方时，bearingY为正数，反之则为负数。
- **xMin/xMax、yMin/yMax**：字形轮廓的边界坐标，xMin为最左位置，xMax为最右位置，yMin为最下位置，yMax为最上位置，四者构成字形的边界框（bounding box，bbox），可紧密包裹字形。
- **advance（步进宽度）**：相邻两个字形原点的距离（字间距）。
  - 水平布局：advanceX为相邻两条垂直基线的水平距离；
  - 垂直布局：advanceY为相邻两条水平基线的垂直距离。

### 5. 字符对齐原理
字符显示时通过基准线实现统一对齐，确保不同字符（如大小写字母、标点、汉字）在同一行或同一列中整齐排列：
- 水平方向：以垂直基线为对齐基准，控制字符左右间距（由advanceX决定）；
- 垂直方向：以水平基线为对齐基准，例如逗号“，”靠近水平基线下方显示，双引号“”靠近水平基线上方显示。
- 字形左上角定位公式：若原点坐标为（x0, y0），则字形左上角坐标为 **(x0 + bearingX, y0 - bearingY)**。

### 6. 字形位图数据
FreeType从字体文件中提取的字形像素数据，存储在缓冲区中，缓冲区大小=字形宽度（width）*字形高度（height）（单位：字节）。
- 缓冲区中每个字节对应一个像素点，值为0时表示该像素不填充颜色，值大于0时表示该像素需要填充字符颜色。



## 四、FreeType库核心使用步骤

### 1、初始化 FreeType 库
在使用 FreeType 库函数之前，需要对 FreeType 库进行初始化操作，使用 `FT_Init_FreeType()` 函数完成初始化操作。在调用该函数之前，我们需要定义一个 `FT_Library` 类型变量，调用 `FT_Init_FreeType()` 函数时将该变量的指针作为参数传递进去；使用示例如下所示：

```c
FT_Library library; 
FT_Error error;  

error = FT_Init_FreeType(&library); 
if (error) 
 fprintf(stderr, "Error: failed to initialize FreeType library object\n"); 
```

`FT_Init_FreeType` 完成以下操作：
- 它创建了一个 FreeType 库对象，并将 `library` 作为库对象的句柄。
- `FT_Init_FreeType()` 调用成功返回 0；失败将返回一个非零值错误码。

### 2、加载 face 对象
应用程序通过调用 `FT_New_Face()` 函数创建一个新的 face 对象，其实就是加载字体文件。一个 face 对象描述了一个特定的字体样式和风格，譬如"Times New Roman Regular"和"Times New Roman Italic"对应两种不同的 face。

调用 `FT_New_Face()` 函数前，我们需要定义一个 `FT_Face` 类型变量，使用示例如下所示：

```c
FT_Library library; //库对象的句柄 
FT_Face face; //face 对象的句柄 
FT_Error error; 

FT_Init_FreeType(&library); 

error = FT_New_Face(library, "/usr/share/fonts/font.ttf", 0, &face); 
if (error) { 
 /* 发生错误、进行相关处理 */ 
} 
```

`FT_New_Face()` 函数原型如下所示：

```c
FT_Error FT_New_Face(FT_Library library, const char *filepathname, 
 FT_Long face_index, FT_Face *aface); 

```

函数参数以及返回值说明如下：
- `library`：一个 FreeType 库对象的句柄，face 对象从中建立；
- `filepathname`：字库文件路径名（一个标准的 C 字符串）；
- `face_index`：某些字体格式允许把几个字体 face 嵌入到同一个文件中，这个索引指示了你想加载的 face，其实就是一个下标，如果这个值太大，函数将会返回一个错误，通常把它设置为 0 即可！想要知道一个字体文件中包含了多少个 face，只要简单地加载它的第一个 face（把 face_index 设置为 0），函数调用成功返回后，`face->num_faces` 的值就指示出了有多少个 face 嵌入在该字体文件中。
- `aface`：一个指向新建 face 对象的指针，当失败时其值被设置为 NULL。
- 返回值：调用成功返回 0；失败将返回一个非零值的错误码。

### 3、设置字体大小
设置字体的大小有两种方式：`FT_Set_Char_Size()` 和 `FT_Set_Pixel_Sizes()`。

#### FT_Set_Pixel_Sizes() 函数
调用 `FT_Set_Pixel_Sizes()` 函数设置字体的宽度和高度，以像素为单位，使用示例如下所示：

```c
FT_Set_Pixel_Sizes(face, 50, 50);  
```

第一个参数传入 face 句柄；第二个参数和第三个参数分别指示字体的宽度和高度，以像素为单位；需要注意的是，我们可以将宽度或高度中的任意一个参数设置为 0，那么意味着设置为 0 的参数将会与另一个参数保持相等，如下所示：

```c
FT_Set_Pixel_Sizes(face, 50, 0); 
```
上面调用 `FT_Set_Pixel_Sizes()` 函数时，将字体高度设置为 0，也就意味着字体高度将自动等于字体宽度 50。

#### FT_Set_Char_Size() 函数
调用 `FT_Set_Char_Size()` 函数设置字体大小，示例如下所示，假设在一个 300x300dpi 的设备上把字体大小设置为 16pt：

```c
error = FT_Set_Char_Size( 
 face, //face 对象的句柄 
 16*64, //以 1/64 点为单位的字体宽度 
 16*64, //以 1/64 点为单位的字体高度 
 300, //水平方向上每英寸的像素点数 
 300); //垂直方向上每英寸的像素点数 
```

说明：
- 字体的宽度和高度并不是以像素为单位，而是以 1/64 点（point）为单位表示（也就是 26.6 固定浮点格式），一个点是一个 1/72 英寸的距离。
- 同样也可将宽度或高度其中之一设置为 0，那么意味着设置为 0 的参数将会与另一个参数保持相等。
- dpi 参数设置为 0 时，表示使用默认值 72dpi。

### 4、加载字形图像



## 五、示例代码框架（FreeType方式显示字符）
```c

#include <stdio.h> 
#include <stdlib.h> 
#include <sys/types.h> 
#include <sys/stat.h> 
#include <fcntl.h> 
#include <unistd.h> 
#include <sys/ioctl.h> 
#include <string.h> 
#include <errno.h> 
#include <sys/mman.h> 
#include <linux/fb.h> 
#include <math.h> //数学库函数头文件 
 
#include <wchar.h> 
#include <ft2build.h> 
#include FT_FREETYPE_H 
 
#define FB_DEV "/dev/fb0" //LCD 设备节点 
 
#define argb8888_to_rgb565(color) ({ \ 
 unsigned int temp = (color); \ 
 ((temp & 0xF80000UL) >> 8) | \ 
 ((temp & 0xFC00UL) >> 5) | \ 
 ((temp & 0xF8UL) >> 3); \ 
 }) 
 
static unsigned int width; //LCD 宽度 
static unsigned int height; //LCD 高度 
static unsigned short *screen_base = NULL;//LCD 显存基地址 RGB565 
static unsigned long screen_size; 
static int fd = -1; 
 
static FT_Library library; 
static FT_Face face; 
 
static int fb_dev_init(void)  
 
{ 
 struct fb_var_screeninfo fb_var = {0}; 
 struct fb_fix_screeninfo fb_fix = {0}; 
 
 /* 打开 framebuffer 设备 */ 
 fd = open(FB_DEV, O_RDWR); 
 if (0 > fd) { 
 fprintf(stderr, "open error: %s: %s\n", FB_DEV, strerror(errno)); 
 return -1; 
 } 
 
 /* 获取 framebuffer 设备信息 */ 
 ioctl(fd, FBIOGET_VSCREENINFO, &fb_var); 
 ioctl(fd, FBIOGET_FSCREENINFO, &fb_fix); 
 
 screen_size = fb_fix.line_length * fb_var.yres; 
 width = fb_var.xres; 
 height = fb_var.yres; 
 
 /* 内存映射 */ 
 screen_base = mmap(NULL, screen_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0); 
 if (MAP_FAILED == (void *)screen_base) { 
 perror("mmap error"); 
 close(fd); 
 return -1; 
 } 
 
 /* LCD 背景刷成黑色 */ 
 memset(screen_base, 0xFF, screen_size); 
 return 0; 
} 
 
static int freetype_init(const char *font, int angle) 
{ 
 FT_Error error; 
 FT_Vector pen; 
 FT_Matrix matrix; 
 float rad; //旋转角度 
 
 /* FreeType 初始化 */ 
 FT_Init_FreeType(&library); 
 
 /* 加载 face 对象 */  

 error = FT_New_Face(library, font, 0, &face); 
 if (error) { 
 fprintf(stderr, "FT_New_Face error: %d\n", error); 
 exit(EXIT_FAILURE); 
 } 
 
 /* 原点坐标 */ 
 pen.x = 0 * 64; 
 pen.y = 0 * 64; //原点设置为(0, 0) 
 
 /* 2x2 矩阵初始化 */ 
 rad = (1.0 * angle / 180) * M_PI; //（角度转换为弧度）M_PI 是圆周率 
#if 0 //非水平方向 
 matrix.xx = (FT_Fixed)( cos(rad) * 0x10000L); 
 matrix.xy = (FT_Fixed)(-sin(rad) * 0x10000L); 
 matrix.yx = (FT_Fixed)( sin(rad) * 0x10000L); 
 matrix.yy = (FT_Fixed)( cos(rad) * 0x10000L); 
#endif 
 
#if 1 //斜体 水平方向显示的 
 matrix.xx = (FT_Fixed)( cos(rad) * 0x10000L); 
 matrix.xy = (FT_Fixed)( sin(rad) * 0x10000L); 
 matrix.yx = (FT_Fixed)( 0 * 0x10000L); 
 matrix.yy = (FT_Fixed)( 1 * 0x10000L); 
#endif 
 
 /* 设置 */ 
 FT_Set_Transform(face, &matrix, &pen); 
 FT_Set_Pixel_Sizes(face, 40, 0); //设置字体大小 
 
 return 0; 
} 
 
static void lcd_draw_character(int x, int y, 
 const wchar_t *str, unsigned int color) 
{ 
 unsigned short rgb565_color = argb8888_to_rgb565(color);//得到 RGB565 颜色值 
 FT_GlyphSlot slot = face->glyph; 
 size_t len = wcslen(str); //计算字符的个数 
 long int temp; 
 int n; 
 int i, j, p, q; 
 int max_x, max_y, start_y, start_x;  

 // 循环加载各个字符 
 for (n = 0; n < len; n++) { 
 
 // 加载字形、转换得到位图数据 
 if (FT_Load_Char(face, str[n], FT_LOAD_RENDER)) 
 continue; 
 
 start_y = y - slot->bitmap_top; //计算字形轮廓上边 y 坐标起点位置 注意是减去 bitmap_top 
 if (0 > start_y) {//如果为负数 如何处理？？ 
 q = -start_y; 
 temp = 0; 
 j = 0; 
 } 
 else { // 正数又该如何处理?? 
 q = 0; 
 temp = width * start_y; 
 j = start_y; 
 } 
 
 max_y = start_y + slot->bitmap.rows;//计算字形轮廓下边 y 坐标结束位置 
 if (max_y > (int)height) 
 max_y = height; 
 
 for (; j < max_y; j++, q++, temp += width) { 
 
 start_x = x + slot->bitmap_left; //起点位置要加上左边空余部分长度 
 if (0 > start_x) { 
 p = -start_x; 
 i = 0; 
 } 
 else { 
 p = 0; 
 i = start_x; 
 } 
 
 max_x = start_x + slot->bitmap.width; 
 if (max_x > (int)width) 
 max_x = width; 
 
 for (; i < max_x; i++, p++) { 
 
 // 如果数据不为 0，则表示需要填充颜色  
 if (slot->bitmap.buffer[q * slot->bitmap.width + p]) 
 screen_base[temp + i] = rgb565_color; 
 } 
 } 
 
 //调整到下一个字形的原点 
 x += slot->advance.x / 64; //26.6 固定浮点格式 
 y -= slot->advance.y / 64; 
 } 
} 
 
int main(int argc, char *argv[]) 
{ 
 
 
 /* LCD 初始化 */ 
 if (fb_dev_init()) 
 exit(EXIT_FAILURE); 
 
 /* freetype 初始化 */ 
 if (freetype_init(argv[1], atoi(argv[2]))) 
 exit(EXIT_FAILURE); 
 
 /* 在 LCD 上显示中文 */ 
 int y = height * 0.25; 
 lcd_draw_character(30, 80, L"路漫漫其修远兮，吾将上下而求索", 0x000000); 
 lcd_draw_character(30, y+80, L"莫愁前路无知己，天下谁人不识君", 0x9900FF); 
 lcd_draw_character(30, 2*y+80, L"君不见黄河之水天上来，奔流到海不复回", 0xFF0099); 
 lcd_draw_character(30, 3*y+80, L"君不见高堂明镜悲白发，朝如青丝暮成雪", 0x9932CC); 
 
 /* 退出程序 */ 
 FT_Done_Face(face); 
 FT_Done_FreeType(library); 
 munmap(screen_base, screen_size); 
 close(fd); 
 exit(EXIT_SUCCESS); 
} 

```

编译时需要指定 freetype 库的头文件搜索路径和库文件搜索路径，以及 zlib 库、libpng 库以及数学
库 libm（因为程序代码中使用到了数学库提供的 API），编译方法如下： 
```bash
${CC} -o testApp testApp.c -I/home/dt/tools/freetype/include/freetype2 -L/home/dt/tools/freetype/lib -
lfreetype -L/home/dt/tools/zlib/lib -lz -L/home/dt/tools/png/lib -lpng –lm
```

## 五、关键注意事项
1. 字体文件路径：开发板上需放置对应的字体文件（如宋体、黑体），并在代码中正确指定路径。
2. 资源释放：使用完FreeType库后，需依次调用`FT_Done_Face`和`FT_Done_FreeType`释放资源，避免内存泄漏。
3. 坐标调整：`bitmap_left`和`bitmap_top`用于调整字符的显示位置，需根据LCD的坐标系统适配，避免字符显示偏移。
4. 点阵数据处理：根据`pixel_mode`处理点阵数据（二值模式、灰度模式等），确保字符正确显示。
5. 库依赖：开发板需正确安装FreeType库，应用程序编译时需链接FreeType库（如编译选项`-lfreetype`）。当前文件内容过长，豆包只阅读了前 18%。
