---
title: LVGL基础控件使用和示例
published: 2026-03-04
pinned: false
description: 在vscode中运行LVGL以及LVGL基础控件使用和示例。
tags: [lvgl, 应用, lvgl]
category: 嵌入式
draft: false
---



# 在vscode中运行LVGL

我的环境配置参考了下面视频，但是教程使用的是LVGLv8官方例程,我随后升级成了v9.1，下面的代码都是基于v9.1的官方例程源码。
[参考视频](https://www.bilibili.com/video/BV1eWLgzrEPq/)


# LVGL基础控件使用和示例（学习笔记）

主要参考韦东山lvglv9.1教程及相关文档。

## 代码效果

![lvgl代码效果](/assets/images/lvgl代码效果.png)
部分为动态效果，图片中无法体现

## 示例源码

```c

#include "study_test.h"
#include "lvgl/lvgl.h"


// 在 study_test.c 顶部定义
typedef struct {
    int count;          // 倒计时数值
    lv_obj_t * label;   // 显示文本的标签
} timer_ctx_t;

static lv_obj_t * spinbox; // 全局微调框对象，方便回调函数访问（新手示例常用，实际可封装为结构体）

//动画执行回调函数（控制标签 y 坐标）
static void anim_y_cb(void * var, int32_t v)
{
    // var：动画绑定的对象（这里是标签label）；v：动画当前的Y坐标值
    lv_obj_set_y(var, v); // 核心：将标签的Y坐标设置为动画计算出的当前值
}

//开关事件回调函数（触发动画的核心逻辑）
static void sw_event_cb(lv_event_t * e)
{
    // 1. 获取触发事件的目标对象（这里是开关sw）
    lv_obj_t * sw = lv_event_get_target(e);
    // 2. 获取传递的用户数据（这里是标签label，绑定开关和标签）
    lv_obj_t * label = lv_event_get_user_data(e);

    // 3. 判断开关是否为“打开（选中）”状态
    if(lv_obj_has_state(sw, LV_STATE_CHECKED)) {
        // -------- 打开开关：标签向右滑到x=100 --------
        lv_anim_t a;                // 定义动画对象
        lv_anim_init(&a);           // 初始化动画
        lv_anim_set_var(&a, label); // 绑定动画到标签对象
        // 设置动画数值范围：从标签当前Y坐标 → 目标Y坐标40
        lv_anim_set_values(&a, lv_obj_get_y(label), 40);
        lv_anim_set_duration(&a, 500); // 动画时长500ms（0.5秒）
        lv_anim_set_exec_cb(&a, anim_y_cb); // 设置动画执行回调（修改Y坐标）
        // 设置动画路径：lv_anim_path_overshoot（过冲，滑到目标后轻微回弹）
        lv_anim_set_path_cb(&a, lv_anim_path_overshoot);
        lv_anim_start(&a);          // 启动动画
    }
    else {
        // -------- 关闭开关：标签向左滑出屏幕 --------
        lv_anim_t a;
        lv_anim_init(&a);
        lv_anim_set_var(&a, label);
        // 设置动画数值范围：从当前Y坐标 → 目标Y坐标（-标签高度，完全滑出屏幕）
        lv_anim_set_values(&a, lv_obj_get_y(label), -lv_obj_get_height(label));
        lv_anim_set_duration(&a, 500);
        lv_anim_set_exec_cb(&a, anim_y_cb);
        // 设置动画路径：lv_anim_path_ease_in（缓入，开始慢、后来快）
        lv_anim_set_path_cb(&a, lv_anim_path_ease_in);
        lv_anim_start(&a);
    }
}

//加号按钮事件回调
static void lv_spinbox_increment_event_cb(lv_event_t * e)
{
    // 获取事件类型（点击、长按、释放等）
    lv_event_code_t code = lv_event_get_code(e);
    // 判断：短按 或 长按重复（按住不放持续触发）
    if(code == LV_EVENT_SHORT_CLICKED || code  == LV_EVENT_LONG_PRESSED_REPEAT) {
        lv_spinbox_increment(spinbox); // 微调框数值+1（按小数格式自动调整步长）
    }
}

//减号按钮事件回调
static void lv_spinbox_decrement_event_cb(lv_event_t * e)
{
    lv_event_code_t code = lv_event_get_code(e);
    // 同样响应短按/长按重复
    if(code == LV_EVENT_SHORT_CLICKED || code == LV_EVENT_LONG_PRESSED_REPEAT) {
        lv_spinbox_decrement(spinbox); // 微调框数值-1
    }
}


// 事件回调函数：处理下拉列表的事件
static void event_handler(lv_event_t * e)
{
    // 1. 获取触发的事件代码（比如点击、值变化、按下等）
    lv_event_code_t code = lv_event_get_code(e);
    // 2. 获取触发事件的目标对象（这里就是下拉列表本身）
    lv_obj_t * obj = lv_event_get_target(e);
    
    // 3. 判断是否是“选项值变化”事件（选中新选项时触发）
    if(code == LV_EVENT_VALUE_CHANGED) {
        char buf[32];  // 定义缓冲区存储选中的文本
        // 4. 获取选中选项的文本，存入缓冲区
        lv_dropdown_get_selected_str(obj, buf, sizeof(buf));
        // 5. 打印选中的选项到日志（调试用）
        LV_LOG_USER("Option: %s", buf);
    }
}

/**
 * 定时器回调：核心倒计时逻辑
 * @param timer 定时器句柄
 */
static void count_down_cb(lv_timer_t * timer)
{
    // 从定时器取出封装好的参数
    timer_ctx_t * ctx = (timer_ctx_t *)lv_timer_get_user_data(timer);

    ctx->count--;

    char buf[16];
    lv_snprintf(buf, sizeof(buf), "remain:%d s", ctx->count);
    lv_label_set_text(ctx->label, buf);

    if (ctx->count <= 0) {
        lv_label_set_text(ctx->label, "Time's up!");
        lv_timer_pause(timer);
    }
}

/**
 * 事件回调函数：处理对象的交互事件
 * @param e 事件对象，包含事件类型、触发对象、用户数据等信息
 */
static void my_event_cb(lv_event_t * e)
{
    // 获取触发事件的目标对象（被点击/长按的obj）
    lv_obj_t * obj = lv_event_get_target(e);
    // 获取具体的事件类型码（短按、长按等）
    lv_event_code_t code = lv_event_get_code(e);
    // 获取注册事件时传递的用户数据（标签控件）
    lv_obj_t * label = lv_event_get_user_data(e);

    // 根据不同事件类型执行不同逻辑
    switch(code) {
        case LV_EVENT_PRESSED:          // 短按事件（按下瞬间）
            lv_label_set_text(label, "LV_EVENT_PRESSED");
            lv_obj_set_style_bg_color(obj, lv_color_hex(0xc43e1c), LV_STATE_DEFAULT);
            LV_LOG_USER("LV_EVENT_PRESSED\n");
            break;

        case LV_EVENT_LONG_PRESSED:     // 长按删除对象（按住超过500ms）
            lv_obj_set_style_bg_color(obj, lv_color_hex(0x4cbe37), LV_STATE_DEFAULT);
            LV_LOG_USER("LV_EVENT_LONG_PRESSED\n");
            lv_obj_del(obj);
            break;

        default:                        // 其他事件（如释放、点击完成等）
            break;
    }
}


static void my_event_flag(lv_event_t * e)
{
    lv_obj_t * obj = lv_event_get_target(e);          // 获取触发事件的对象
    lv_obj_t * obj1 = lv_event_get_current_target(e); // 获取当前处理事件的对象（事件冒泡时为父对象）
    lv_event_code_t code = lv_event_get_code(e);      // 获取当前触发的事件代码
    lv_obj_t * label = lv_event_get_user_data(e);     // 获取添加事件时传递的用户数据

    switch(code) {
        case LV_EVENT_PRESSED:
            lv_label_set_text(label, "LV_EVENT_PRESSED");
            lv_obj_set_style_bg_color(obj1, lv_color_hex(0xc43e1c), 0); // 通过本地样式设置父对象背景色
            lv_obj_set_style_bg_color(obj, lv_color_hex(0xc43e1c), 0);  // 通过本地样式设置触发对象背景色
            LV_LOG_USER("LV_EVENT_PRESSED\n");
            break;

        case LV_EVENT_RELEASED:
            lv_label_set_text(label, "LV_EVENT_RELEASED");
            lv_obj_remove_local_style_prop(obj1, LV_STYLE_BG_COLOR, 0); // 删除父对象的本地样式
            lv_obj_remove_local_style_prop(obj, LV_STYLE_BG_COLOR, 0);  // 删除触发对象的本地样式
            LV_LOG_USER("LV_EVENT_RELEASED\n");
            break;

        default:
            //LV_LOG_USER("NONE\n");
            break;
    }
}


void study()
{
    /* ===================== 位置和大小 ============================= */
  // 1. 创建父对象（作为容器）
  lv_obj_t * obj = lv_obj_create(lv_screen_active());
  // 设置父对象尺寸：宽300，高200
  lv_obj_set_size(obj, 300, 200);
  // 父对象位置
  lv_obj_set_pos(obj, 10, 100);
  // 设置父对象背景色（灰色），区分屏幕
  lv_obj_set_style_bg_color(obj, lv_color_hex(0xCCCCCC), LV_STATE_DEFAULT);

  // 2. 创建子对象（嵌套在父对象中）
  lv_obj_t * obj1 = lv_obj_create(obj);
  // 设置子对象尺寸：宽100，高100
  lv_obj_set_width(obj1, lv_pct(50));   // 宽度 = 父对象宽度的 33%
  lv_obj_set_height(obj1, lv_pct(50));  // 高度 = 父对象高度的 33%
  //lv_obj_set_size(obj1, 100, 100);
  // 子对象在父对象中居中
  lv_obj_center(obj1);
  // 设置子对象背景色（蓝色），区分父对象
  lv_obj_set_style_bg_color(obj1, lv_color_hex(0x0066CC), LV_STATE_DEFAULT);


  /* ===================== 弹性布局示例 =========================== */
  // 1. 创建父容器（弹性布局）
  lv_obj_t * flex_container = lv_obj_create(lv_screen_active());
  lv_obj_set_size(flex_container, 300, 80);  // 容器尺寸
  lv_obj_set_pos(flex_container, 10, 10);//容器位置
  //lv_obj_center(flex_container);             // 容器居中
  lv_obj_set_layout(flex_container, LV_LAYOUT_FLEX);          // 设置弹性布局
  lv_obj_set_flex_flow(flex_container, LV_FLEX_FLOW_ROW);     // 水平排列
  // 设置子对象对齐：主轴居中、交叉轴居中、间距均匀
  lv_obj_set_flex_align(flex_container, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_SPACE_EVENLY);

  // 2. 创建按钮1 + 标签（v9 标准写法）
  lv_obj_t * btn1 = lv_btn_create(flex_container);
  lv_obj_set_width(btn1, lv_pct(25));       // 宽度=容器25%
  lv_obj_t * label1 = lv_label_create(btn1); // 按钮内创建标签
  lv_label_set_text(label1, "btn1");        // 设置标签文本
  lv_obj_center(label1);                     // 标签在按钮中居中

  // 3. 创建按钮2 + 标签
  lv_obj_t * btn2 = lv_btn_create(flex_container);
  lv_obj_set_width(btn2, lv_pct(25));
  lv_obj_t * label2 = lv_label_create(btn2);
  lv_label_set_text(label2, "btn2");
  lv_obj_center(label2);

  // 4. 创建按钮3 + 标签
  lv_obj_t * btn3 = lv_btn_create(flex_container);
  lv_obj_set_width(btn3, lv_pct(25));
  lv_obj_t * label3 = lv_label_create(btn3);
  lv_label_set_text(label3, "btn3");
  lv_obj_center(label3);


  /* ===================== 改变图层 ================================== */

  //图层的使用：直接在顶层创建悬浮按钮
  lv_obj_t * float_btn = lv_btn_create(lv_layer_top()); // 父对象是顶层
  lv_obj_set_size(float_btn, 180, 60);
  lv_obj_align(float_btn, LV_ALIGN_TOP_LEFT, 10, 310); // 左上角

  // 给按钮加标签
  lv_obj_t * label = lv_label_create(float_btn);
  lv_label_set_text(label, "top");
  lv_obj_center(label);


  float_btn = lv_btn_create(lv_layer_top()); // 父对象是顶层
  lv_obj_set_size(float_btn, 180, 60);
  lv_obj_align(float_btn, LV_ALIGN_TOP_LEFT, 120, 310); // 左上角
  lv_obj_set_style_bg_color(float_btn, lv_color_hex(0xFF0000), LV_STATE_DEFAULT);//设置按钮背景色为红色（十六进制 0xFF0000）

  // 给按钮加标签
  label = lv_label_create(float_btn);
  lv_label_set_text(label, "bottom");
  lv_obj_center(label);

  //放到底层
  lv_obj_move_background(float_btn);


  /* ======================= 样式的使用 ============================== */

  // 1. 创建按钮
  lv_obj_t * btn = lv_btn_create(lv_screen_active());
  lv_obj_set_size(btn, 140, 60);
  lv_obj_set_pos(btn, 10, 380);//容器位置

  // 2. 设置默认状态样式（核心快捷函数）
  lv_obj_set_style_bg_color(btn, lv_color_hex(0x0066CC), LV_STATE_DEFAULT); // 背景色：蓝色
  lv_obj_set_style_radius(btn, 10, LV_STATE_DEFAULT);                    // 圆角：10像素
  lv_obj_set_style_border_width(btn, 2, LV_STATE_DEFAULT);                  // 边框宽度：2像素
  lv_obj_set_style_border_color(btn, lv_color_hex(0x003399), LV_STATE_DEFAULT); // 边框色：深蓝色
  lv_obj_set_style_shadow_color(btn, lv_color_hex(0x000000), LV_STATE_DEFAULT); // 阴影色：黑色
  lv_obj_set_style_shadow_offset_y(btn, 3, LV_STATE_DEFAULT);               // 阴影Y偏移：3像素
  lv_obj_set_style_shadow_opa(btn, 80, LV_STATE_DEFAULT);                   // 阴影透明度：80（0-255）

  // 3. 设置按下状态样式（点击时的外观）
  lv_obj_set_style_bg_color(btn, lv_color_hex(0x003399), LV_STATE_PRESSED); // 按下时背景色加深
  lv_obj_set_style_shadow_offset_y(btn, 1, LV_STATE_PRESSED);               // 按下时阴影上移（模拟按压）

  // 4. 设置按钮内标签样式
  label = lv_label_create(btn);
  lv_label_set_text(label, "style btn");
  lv_obj_center(label);
  lv_obj_set_style_text_color(label, lv_color_white(), LV_STATE_DEFAULT);    // 文字白色
  lv_obj_set_style_text_font(label, &lv_font_montserrat_16, LV_STATE_DEFAULT); // 文字字体

  /* ==================LVGL 事件驱动机制============================== */

    // 1. 创建事件触发对象（基础矩形）
    obj = lv_obj_create(lv_screen_active());
    lv_obj_set_size(obj, 140, 60);    // 设置对象尺寸
    lv_obj_set_pos(obj, 160, 380);//容器位置

    // 2. 创建状态显示标签
    label = lv_label_create(obj);
    lv_label_set_text(label, "test");  // 初始化文本
    lv_obj_center(label);              // 标签居中（覆盖在obj上方）

    // 3. 绑定事件：监听obj的所有事件，回调函数为my_event_cb，传递label作为用户数据
    lv_obj_add_event_cb(obj, my_event_cb, LV_EVENT_ALL, label);

  /* =====================事件冒泡==================================== */

      /* 创建一个基础对象 obj1 */
    obj1 = lv_obj_create(lv_screen_active());
    lv_obj_set_size(obj1, 300, 200);
    lv_obj_set_pos(obj1, 10, 460);//容器位置

    /* 以 obj1 创建一个基础对象 obj2 */
    lv_obj_t * obj2 = lv_obj_create(obj1);
    lv_obj_set_size(obj2, 250, 150);
    lv_obj_center(obj2);
    lv_obj_add_flag(obj2, LV_OBJ_FLAG_EVENT_BUBBLE); // 启用事件冒泡，将事件传播给父级

    /* 以 obj2 创建一个基础对象 obj3 */
    lv_obj_t * obj3 = lv_obj_create(obj2);
    lv_obj_set_size(obj3, 200, 100);
    lv_obj_center(obj3);
    lv_obj_add_flag(obj3, LV_OBJ_FLAG_EVENT_BUBBLE); // 启用事件冒泡

    /* 以 obj3 创建一个基础对象 obj4 */
    lv_obj_t * obj4 = lv_obj_create(obj3);
    lv_obj_set_size(obj4, 150, 50);
    lv_obj_center(obj4);
    lv_obj_add_flag(obj4, LV_OBJ_FLAG_EVENT_BUBBLE); // 启用事件冒泡

    /* 以屏幕为父类，创建一个 label 部件(对象) */
    label = lv_label_create(lv_screen_active());
    lv_label_set_text(label, "test");
    lv_obj_align_to(label, obj1, LV_ALIGN_OUT_TOP_MID, 0, 0); // 将 label 相对于 obj1 对齐

    /* 给 obj1 添加事件回调函数，所有的事件类型都能触发该回调函数 */
    lv_obj_add_event_cb(obj1, my_event_flag, LV_EVENT_ALL, label);

  /* ==========================定时器================================ */

    // 1. 创建显示标签
    label = lv_label_create(lv_screen_active());
    lv_label_set_text(label, "remain:10s");
    lv_obj_set_pos(label, 40, 680);//容器位置
    lv_obj_set_style_text_font(label, &lv_font_montserrat_24, LV_STATE_DEFAULT);

    // 2. 动态分配并初始化参数结构体
    timer_ctx_t * ctx = (timer_ctx_t *)lv_malloc(sizeof(timer_ctx_t));
    ctx->count = 10;
    ctx->label = label;

    // 3. 创建定时器，并绑定参数结构体
    lv_timer_t * timer = lv_timer_create(count_down_cb, 1000, ctx);
    // （可选）如果需要在其他地方再次获取，也可以用 lv_timer_set_user_data
    // lv_timer_set_user_data(timer, ctx);
    //就绪和重置计时器
    //lv_timer_ready(timer);
    //lv_timer_reset(timer);
    //暂停和恢复计时器
    //lv_timer_pause(timer);
    //lv_timer_resume(timer);

  /* ==========================进度条================================ */

    lv_obj_t * bar = lv_bar_create(lv_screen_active());
    lv_obj_set_size(bar, 200, 20);
    lv_obj_set_pos(bar, 30, 720);//容器位置
    lv_bar_set_value(bar, 70, LV_ANIM_ON); // 设置进度值（0-100）

  /* =====================矩阵按钮==================================== */

    lv_obj_t * btnm = lv_buttonmatrix_create(lv_screen_active());
    static const char * map[] = {"1", "2", "3", "\n", "4", "5", "6", ""};
    lv_buttonmatrix_set_map(btnm, map);
    lv_obj_set_pos(btnm, 30, 760);//容器位置

  /* ==================日历=========================================== */

    lv_obj_t * cal = lv_calendar_create(lv_screen_active());
    lv_obj_set_size(cal, 300, 250);
    lv_obj_set_pos(cal, 350, 220);//容器位置

    // 设置显示的月份
    lv_calendar_set_month_shown(cal, 2025, 10);

  /* ====================图表======================================== */

    lv_obj_t * chart = lv_chart_create(lv_screen_active());
    lv_obj_set_size(chart, 300, 200);
    lv_obj_set_pos(chart, 350, 10);//容器位置
    lv_chart_series_t * ser = lv_chart_add_series(chart, lv_color_hex(0x00ff00), LV_CHART_AXIS_PRIMARY_Y);
    lv_chart_set_next_value(chart, ser, 10);
    lv_chart_set_next_value(chart, ser, 15);
    lv_chart_set_next_value(chart, ser, 33);
    lv_chart_set_next_value(chart, ser, 40);
    lv_chart_set_next_value(chart, ser, 54);
    lv_chart_set_next_value(chart, ser, 59);
    lv_chart_set_next_value(chart, ser, 71);
    lv_chart_set_next_value(chart, ser, 80);

 /* ========================表格===================================== */

    lv_obj_t * table = lv_table_create(lv_screen_active());
    lv_table_set_cell_value(table, 0, 0, "Name");
    lv_table_set_cell_value(table, 0, 1, "Age");
    //lv_table_set_cell_value(table, 0, 2, "Gender");
    lv_table_set_cell_value(table, 1, 0, "Alice");
    lv_table_set_cell_value(table, 1, 1, "25");
    //lv_table_set_cell_value(table, 1, 2, "Female");
    lv_table_set_cell_value(table, 2, 0, "Tom");
    lv_table_set_cell_value(table, 2, 1, "21");
    //lv_table_set_cell_value(table, 2, 2, "Male");

    lv_obj_set_pos(table, 350, 490);//容器位置

/* ========================文本输入框并绑定键盘===================================== */

    // 1. 创建文本输入框
    lv_obj_t * ta = lv_textarea_create(lv_screen_active());
    lv_obj_set_size(ta, 300, 200);
    lv_obj_set_pos(ta, 350, 690);//容器位置
    lv_textarea_set_placeholder_text(ta, "Type here...");

    // 2. 创建虚拟键盘
    lv_obj_t * kb = lv_keyboard_create(lv_screen_active());
    lv_obj_set_size(kb, 300, 200);
    lv_obj_set_pos(kb, 300, 0);//容器位置

    // 3. 核心：将键盘和文本框绑定（输入的文字会自动填入文本框）
    lv_keyboard_set_textarea(kb, ta);

/* ========================环形加载器===================================== */

    // 1. 创建环形加载器
    lv_obj_t * spinner = lv_spinner_create(lv_screen_active());

    // 2. 设置大小
    lv_obj_set_size(spinner, 100, 100);

    // 3. 设置动画参数（替代原来的参数）
    lv_spinner_set_anim_params(spinner, 4000, 180); // 4000ms 动画周期，180度弧长

    //容器位置
    lv_obj_set_pos(spinner, 750, 270);

/* ========================下拉列表===================================== */

    // 1. 创建下拉列表控件，父对象是当前活跃屏幕
    lv_obj_t * dd = lv_dropdown_create(lv_screen_active());
    
    // 2. 设置下拉列表的选项（换行符\n分隔不同选项）
    lv_dropdown_set_options(dd, "Apple\n"
                            "Banana\n"
                            "Orange\n"
                            "Cherry\n"
                            "Grape\n"
                            "Raspberry\n"
                            "Melon\n"
                            "Orange\n"
                            "Lemon\n"
                            "Nuts");

    // 3. 对齐：屏幕顶部居中，x偏移0，y偏移20（离顶部20像素）
    lv_obj_align(dd, LV_ALIGN_TOP_MID, 300, 150);
    
    // 4. 给下拉列表绑定事件回调：
    //    - 回调函数：event_handler
    //    - 监听的事件：LV_EVENT_ALL（所有事件）
    //    - 用户数据：NULL（无额外参数传递）
    lv_obj_add_event_cb(dd, event_handler, LV_EVENT_ALL, NULL);

// ========================指示灯===================================== */

    /*Create a LED and switch it OFF*/
    lv_obj_t * led1  = lv_led_create(lv_screen_active());
    lv_obj_align(led1, LV_ALIGN_CENTER, 220, 20);
    lv_led_off(led1);

    /*Copy the previous LED and set a brightness*/
    lv_obj_t * led2  = lv_led_create(lv_screen_active());
    lv_obj_align(led2, LV_ALIGN_CENTER, 300, 20);
    lv_led_set_brightness(led2, 150);
    lv_led_set_color(led2, lv_palette_main(LV_PALETTE_RED));

    /*Copy the previous LED and switch it ON*/
    lv_obj_t * led3  = lv_led_create(lv_screen_active());
    lv_obj_align(led3, LV_ALIGN_CENTER, 380, 20);
    lv_led_on(led3);

/* ========================微调框===================================== */
    // 1. 创建微调框对象，父对象为当前活跃屏幕
    spinbox = lv_spinbox_create(lv_screen_active());
    
    // 2. 设置数值范围：最小值-1000，最大值25000
    lv_spinbox_set_range(spinbox, -1000, 25000);
    
    // 3. 设置数字格式：总位数5位，小数位数2位（示例：123.45、-99.99）
    lv_spinbox_set_digit_format(spinbox, 5, 2);
    
    // 4. 初始值：默认是0，调用step_prev让初始值减1（变为-0.01）
    lv_spinbox_step_prev(spinbox);
    
    // 5. 设置微调框宽度（高度自适应）
    lv_obj_set_width(spinbox, 100);
    
    // 6. 微调框居中显示
    lv_obj_align(spinbox, LV_ALIGN_CENTER, 300, 140);

    // 7. 获取微调框高度，用于匹配按钮尺寸（保证按钮和微调框等高）
    int32_t h = lv_obj_get_height(spinbox);

    // 8. 创建右侧加号按钮
    btn = lv_button_create(lv_screen_active());
    lv_obj_set_size(btn, h, h); // 按钮尺寸：宽=高=微调框高度（正方形）
    // 对齐：微调框右侧中轴，x偏移5像素（留间距），y无偏移
    lv_obj_align_to(btn, spinbox, LV_ALIGN_OUT_RIGHT_MID, 5, 0);
    // 按钮背景图设为“加号符号”（LVGL内置符号）
    lv_obj_set_style_bg_image_src(btn, LV_SYMBOL_PLUS, 0);
    // 绑定事件回调：响应所有事件，触发递增逻辑
    lv_obj_add_event_cb(btn, lv_spinbox_increment_event_cb, LV_EVENT_ALL,  NULL);

    // 9. 创建左侧减号按钮（逻辑同加号按钮）
    btn = lv_button_create(lv_screen_active());
    lv_obj_set_size(btn, h, h);
    // 对齐：微调框左侧中轴，x偏移-5像素
    lv_obj_align_to(btn, spinbox, LV_ALIGN_OUT_LEFT_MID, -5, 0);
    // 按钮背景图设为“减号符号”
    lv_obj_set_style_bg_image_src(btn, LV_SYMBOL_MINUS, 0);
    // 绑定事件回调：触发递减逻辑
    lv_obj_add_event_cb(btn, lv_spinbox_decrement_event_cb, LV_EVENT_ALL, NULL);

/* ========================动画===================================== */

    // 1. 创建文本标签
    label = lv_label_create(lv_screen_active());
    lv_label_set_text(label, "Hello animations!"); // 设置显示文本
    lv_obj_set_pos(label, 750, -20);               // 初始位置：x=750，y=-20

    // 2. 创建开关控件
    lv_obj_t * sw = lv_switch_create(lv_screen_active());
    lv_obj_set_pos(sw, 790, 80);               // x=790，y=80
    lv_obj_add_state(sw, LV_STATE_DEFAULT);        // 默认设置为“关闭”状态
    // 3. 绑定开关事件：状态变化时触发sw_event_cb，传递label作为用户数据
    lv_obj_add_event_cb(sw, sw_event_cb, LV_EVENT_VALUE_CHANGED, label);
}

```



