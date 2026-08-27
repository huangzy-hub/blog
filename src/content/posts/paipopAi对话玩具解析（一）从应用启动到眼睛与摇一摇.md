---
title: paipopAi对话玩具解析（一）：从应用启动到眼睛与摇一摇
published: 2026-08-27
pinned: false
description: 结合 Paipop 玩具工程，讲清应用启动后怎样创建眼睛任务、用 generation 和 snapshot 交换状态，以及 STK8321 设备注册、三类回调和摇一摇事件怎样进入业务 FSM。
tags: [AC791N, Paipop, 嵌入式, STK8321, 回调函数, 任务通信]
category: 嵌入式
draft: false
---

# paipopAi对话玩具解析（一）：从应用启动到眼睛与摇一摇

上一篇已经追踪了杰理 AC79 的应用注册和启动机制：`REGISTER_APPLICATION` 把应用描述符放进注册表，`app_main()` 再用 `start_app()` 启动 `paipop_toy`。这篇从 `APP_STA_START` 接着往下看，但先不铺开 Wi-Fi、ASR、LLM、TTS 和 OTA 的全部细节，只讲清两个最容易混淆的子系统：**眼睛动画**和**摇一摇**。

本文主要回答这些问题：

- `paipop_eye_anim` 任务是什么时候创建的？
- `LISTENING`、`SPEAKING` 分别表示什么？
- 为什么这里用 `generation++`，而没有使用消息队列？
- `paipop_eye_snapshot()` 为什么要传一串地址？
- `iic0` 是怎样注册的，`dev_open()` 又是怎样找到它的？
- 业务回调、硬件回调和定时回调分别是谁实现、谁触发？
- `shake.int1_pending = 1` 和业务回调有什么关系？
- 为什么不能直接在硬件中断里处理中断聊天？

本文基于 `test` 分支的 `4f8fa14` 源码快照整理。调用链来自当前源码和杰理 SDK 公开接口；没有重新运行固件，因此“已经注册的回调会在对应硬件条件下被框架调用”属于接口和注册点能够证明的路径，不冒充本次运行观测。

## 一、先分清代码归属

| 代码 | 归属 | 作用 |
|---|---|---|
| `app_main.c` | Paipop 玩具工程 | 启动玩具应用和各业务模块 |
| `paipop_eye_service.c` | Paipop 玩具工程 | 管理眼睛行为和独立动画任务 |
| `eye_anim.c`、`lcd.c` | Paipop 玩具工程 | 生成眼睛画面并驱动双 LCD |
| `paipop_shake.c` | Paipop 玩具工程 | 组织中断、延后处理和业务通知 |
| `stk8321.c` | Paipop 玩具工程 | 通过 I²C 配置和读取 STK8321 |
| `paipop_events.c`、`paipop_fsm.c` | Paipop 玩具工程 | 把摇动转换成产品事件并作出业务决策 |
| `thread_fork()`、`port_wakeup_reg()`、`sys_timer_add_to_task()` | 杰理 SDK | 创建任务、配置 GPIO 中断和调度定时回调 |
| `dev_open()`、`dev_ioctl()`、`dev_write()`、`dev_read()` | 杰理 SDK | 统一设备访问接口 |
| Any Motion 寄存器 | STK8321 芯片能力 | 在传感器内部判断三轴运动并输出中断 |

这里所说的“我的代码”是当前工程里的第一方实现，不表示已经用 Git 历史确认每一行的个人作者。

## 二、`paipop_shake_start()` 是什么时候执行的

系统首先进入项目的 `app_main()`：

```c
void app_main(void)
{
    struct intent it;

    init_intent(&it);
    it.name = "paipop_toy";
    start_app(&it);
}
```

`start_app()` 是杰理 SDK 接口。它根据名字找到已经注册的 `paipop_toy`，再通过应用操作表调用：

```c
paipop_toy_state_machine(app, APP_STA_START, it);
```

`APP_STA_START` 中依次启动各模块：

```c
case APP_STA_START:
    paipop_eye_service_init();
    paipop_fsm_init();
    paipop_ota_init();
    key_event_enable();
    paipop_events_start();
    paipop_shake_start(paipop_events_shake_cb, NULL);
    paipop_wifi_provision_start();
    paipop_fsm_dispatch(PAIPOP_EVT_APP_START, 0);
    break;
```

所以 `paipop_shake_start()` 是**应用启动时执行一次的准备函数**，不是发生摇动时才执行。它负责：

```text
保存业务回调
  → 打开 iic0
  → 初始化 STK8321
  → 配置 Any Motion
  → 注册 PA5/PA6 硬件回调
  → 注册 20 ms 定时回调
  → 返回，继续启动 Wi-Fi
```

之后真正摇动时，只会触发它提前注册好的处理路径。应用进入 `APP_STA_STOP` 或 `APP_STA_DESTROY` 时，再调用 `paipop_shake_stop()` 删除定时器并注销中断。

## 三、眼睛为什么单独创建任务

`paipop_eye_service_init()` 先初始化 LCD，再调用杰理 `thread_fork()`：

```c
ret = eye_init();
if (ret) {
    return ret;
}

ret = thread_fork(PAIPOP_EYE_TASK_NAME,
                  18,
                  PAIPOP_EYE_TASK_STACK_SIZE,
                  0,
                  &eye_hdl.task_pid,
                  paipop_eye_task,
                  NULL);
```

这句可以读成：

```text
创建名为 paipop_eye_anim 的任务
  → 任务入口是 paipop_eye_task(NULL)
  → 把任务 PID 写进 eye_hdl.task_pid
```

`thread_fork()` 才是真正创建任务的调用。`task_info_table` 中同名记录是任务配置表，不是“执行到表就自动运行任务”。当前源码中任务表和 `thread_fork()` 的优先级、栈参数并不一致；这篇只讨论控制流程，不把哪组参数最终生效写成没有证据的结论。

眼睛需要独立任务，是因为它要持续完成：

- 随机注视和微小眼球运动；
- 普通眨眼、双眨眼和特殊表情；
- 根据时间插值刷新局部画面；
- 通过 SPI 向两块 LCD 发送像素；
- OTA 时显示进度条。

如果这些工作都放进 `app_core`，LCD 刷新和动画延时就可能拖慢按键、网络和语音事件处理。独立任务把“产品决策”和“画面渲染”分开了。

### 1. `LISTENING` 和 `SPEAKING` 是什么

眼睛服务只接收四种高层行为：

```c
enum paipop_eye_behavior {
    PAIPOP_EYE_BEHAVIOR_CLOSED,
    PAIPOP_EYE_BEHAVIOR_IDLE,
    PAIPOP_EYE_BEHAVIOR_LISTENING,
    PAIPOP_EYE_BEHAVIOR_SPEAKING,
};
```

| 行为 | 在产品中的含义 |
|---|---|
| `CLOSED` | 配网、引擎初始化等暂不需要表现的阶段 |
| `IDLE` | 语音引擎已就绪，等待用户开始 |
| `LISTENING` | 正在采集用户语音，PCM 上行并等待 ASR |
| `SPEAKING` | AI 回答已经进入输出阶段，设备正在播放 TTS 音频 |

因此，`SPEAKING` 不是“用户正在说话”，而是“AI 正通过扬声器说话”。语音 SDK 报告 `OUTPUTING` 后，事件层把它转换成产品事件，FSM 再修改眼睛行为：

```c
case PAIPOP_EVT_ENGINE_PHASE_OUTPUTING:
    if (state == PAIPOP_TOY_STATE_ENGINE_CHAT) {
        paipop_fsm_mark_output_seen();
        paipop_eye_set_behavior(
            PAIPOP_EYE_BEHAVIOR_SPEAKING);
    }
    return 0;
```

FSM 只说“现在进入 `SPEAKING`”，真正画什么表情仍由眼睛任务决定。

### 2. `generation++` 是一种怎样的任务通信

眼睛服务有一份共享控制对象：

```c
struct paipop_eye_hdl {
    OS_MUTEX mutex;
    u8 eye_ready;
    u8 exit_req;
    u8 manual_blink;
    u8 ota_active;
    u8 ota_progress;
    u8 ota_progress_dirty;
    u32 generation;
    enum paipop_eye_behavior behavior;
    int task_pid;
};
```

FSM 修改眼睛行为时：

```c
paipop_eye_lock();

if (eye_hdl.eye_ready &&
    eye_hdl.behavior != behavior) {
    eye_hdl.behavior = behavior;
    eye_hdl.manual_blink = 0;
    eye_hdl.generation++;
}

paipop_eye_unlock();
```

这里传递了两项信息：

```text
behavior    = 最新目标状态
generation  = 这份状态的版本号
```

眼睛任务周期性读取共享状态。如果看到版本号发生变化，就停止旧动作并应用最新行为：

```c
if (requested_generation != generation) {
    generation = requested_generation;
    behavior = requested;
    motion.moving = 0;
    eye_anim_show_state_pose_region(...);
    paipop_eye_reset_schedule(...);
}
```

这仍然属于任务间通信，只是采用了“互斥锁保护的共享状态”，而不是消息队列。

为什么这里不一定需要消息队列？因为眼睛通常只关心**最新状态**。假设短时间内发生：

```text
IDLE → LISTENING → SPEAKING
```

屏幕不必排队完整播放三个旧命令，只要尽快进入最新的 `SPEAKING`。`generation` 还有另一个作用：即使状态快速变化后又变回原值，眼睛任务仍能从版本号知道“中间发生过新请求”，并重新安排动画。

这种方式的代价是不会在 `generation++` 的瞬间立即唤醒任务，要等下一次轮询。如果某项业务要求每条命令都不能丢，或者必须立即唤醒休眠任务，消息队列、事件标志或信号量会更合适。

### 3. `paipop_eye_snapshot()` 在做什么

眼睛任务每轮调用：

```c
paipop_eye_snapshot(&requested,
                    &requested_generation,
                    &exit_req,
                    &manual_blink,
                    &ota_active,
                    &ota_progress,
                    &ota_progress_dirty);
```

参数前面的 `&` 表示“把局部变量的地址传进去”。函数通过这些地址，把共享对象中的值复制到眼睛任务的局部变量：

```c
static void paipop_eye_snapshot(...)
{
    paipop_eye_lock();

    *behavior = eye_hdl.behavior;
    *generation = eye_hdl.generation;
    *exit_req = eye_hdl.exit_req;
    *manual_blink = eye_hdl.manual_blink;
    *ota_active = eye_hdl.ota_active;
    *ota_progress = eye_hdl.ota_progress;
    *ota_progress_dirty = eye_hdl.ota_progress_dirty;

    eye_hdl.manual_blink = 0;
    eye_hdl.ota_progress_dirty = 0;

    paipop_eye_unlock();
}
```

它叫“快照”，是因为函数在一次加锁期间取得一套相互一致的数据，解锁后再用局部变量画图，不需要长时间占用互斥锁。

其中：

| 输出变量 | 含义 |
|---|---|
| `requested` | 当前要求的眼睛行为 |
| `requested_generation` | 行为版本号 |
| `exit_req` | 是否要求眼睛任务退出 |
| `manual_blink` | 是否手动眨眼一次 |
| `ota_active` | 是否进入 OTA 显示模式 |
| `ota_progress` | 当前 OTA 百分比 |
| `ota_progress_dirty` | OTA 进度是否刚刚变化 |

`manual_blink` 和 `ota_progress_dirty` 被读取后立即清零，说明它们是“一次性通知”：眼睛任务已经取走，就不应该在下一轮重复处理。

## 四、摇一摇服务怎样保存状态并初始化传感器

### 1. `shake` 在哪里，它保存了什么

`shake` 不是 SDK 对象，而是 `paipop_shake.c` 中定义的文件级变量：

```c
struct paipop_shake_hdl {
    void *int1_wakeup_hdl;
    void *int2_wakeup_hdl;
    u16 timer_id;
    volatile u8 int1_pending;
    volatile u8 int2_pending;
    u8 started;
    u32 irq_count;
    u32 shake_count;
    u32 last_shake_ms;
    paipop_shake_cb_t callback;
    void *callback_priv;
};

static struct paipop_shake_hdl shake;
```

`static` 表示这个变量只能被 `paipop_shake.c` 使用；文件级静态对象在程序启动时自动清零。整个摇一摇服务共用这一份控制对象：

```text
中断注册句柄 + 定时器 ID
+ 两个 pending 标志
+ 计数和冷却时间
+ 业务回调函数及其参数
```

### 2. 先分清 STK8321 的四根信号线

当前板级配置中：

| 引脚 | 作用 |
|---|---|
| PA7 | 软件 I²C 时钟 SCL |
| PA8 | 软件 I²C 数据 SDA |
| PA5 | STK8321 INT1 中断输出 |
| PA6 | STK8321 INT2 中断输出 |

PA7、PA8 用来读写寄存器，PA5、PA6 用来告诉 MCU“传感器检测到了运动”。两组引脚不能混为一谈。

`stk8321_init()` 的主要步骤是：

```text
打开 iic0
  → 向 SWRST 写 0xB6，软件复位
  → 读取并检查 CHIP_ID
  → 进入正常功耗模式
  → 配置 ±4g 量程
  → 配置 125 Hz 带宽和滤波数据
  → 回读部分寄存器进行验证
```

随后 `stk8321_shake_int_init()` 配置 Any Motion：

```text
先关闭旧中断
  → 配置连续采样数和运动阈值
  → INT1/INT2 设置为高电平有效、锁存模式
  → 开启 X/Y/Z 三轴 slope 检测
  → 把 Any Motion 映射到 INT1 和 INT2
  → 清除历史状态
```

传感器负责判断“运动条件是否成立”，杰里芯片负责接收 PA5/PA6 的电平变化。

## 五、设备注册与 `dev_*` 接口怎样配合

### 1. 设备注册到底注册了什么

板级文件先填写软件 I²C 参数：

```c
SW_IIC_PLATFORM_DATA_BEGIN(sw_iic0_data)
    .clk_pin = IO_PORTA_07,
    .dat_pin = IO_PORTA_08,
    .sw_iic_delay = 50,
SW_IIC_PLATFORM_DATA_END()
```

再把名字、操作表和参数绑定成一条设备记录：

```c
REGISTER_DEVICES(device_table) = {
    {"iic0", &iic_dev_ops, (void *)&sw_iic0_data},
    ...
};
```

`REGISTER_DEVICES` 展开后会把这组设备描述放入 `.device` 段。链接阶段负责收集这些记录，运行时的杰理设备框架再使用这张表；这和上一篇的 `.app` 应用注册思路相似，只是注册对象从“应用”换成了“设备”。

可以把它看成设备电话簿：

```text
名字      操作方法          硬件参数
iic0  →  iic_dev_ops  →  PA7、PA8、delay=50
```

这里需要分清哪些由项目填写，哪些由 SDK 自动完成：

| 阶段 | 项目代码做什么 | 杰理 SDK 做什么 |
|---|---|---|
| 编写板级配置 | 填写 `iic0`、PA7、PA8 和平台参数 | 提供注册宏和 `iic_dev_ops` |
| 编译、链接和启动 | 不手动遍历表 | 收集设备记录并维护设备表 |
| 打开设备 | 调用 `dev_open("iic0", NULL)` | 按名字查找记录并调用对应 `open` 操作 |
| 操作设备 | 调用 `dev_ioctl/dev_write/dev_read` | 根据句柄转到对应驱动操作表 |

设备注册本身不会主动读取 STK8321。真正让设备开始工作的是后面的 `dev_open()` 和设备操作调用。

### 2. `dev_open()`、`dev_ioctl()`、`dev_write()`、`dev_read()` 怎么用

通用生命周期是：

```c
void *handle = dev_open("设备名", NULL);
if (!handle) {
    return -1;
}

dev_ioctl(handle, 控制命令, 控制参数);
dev_write(handle, 发送缓冲区, 长度);
dev_read(handle, 接收缓冲区, 长度);

dev_close(handle);
```

四个接口的职责：

| 接口 | 作用 |
|---|---|
| `dev_open()` | 按名字找到设备并返回句柄 |
| `dev_ioctl()` | 执行设备专用控制命令 |
| `dev_write()` | 向设备发送一段连续数据 |
| `dev_read()` | 从设备读取一段连续数据 |
| `dev_close()` | 释放设备句柄 |

#### STK8321 使用 `dev_open()` 和 `dev_ioctl()`

```c
stk8321_iic = dev_open("iic0", NULL);
```

SDK 根据名字找到 `iic_dev_ops` 和 PA7/PA8 参数。写寄存器时，项目需要精确控制 I²C 时序：

```c
dev_ioctl(stk8321_iic, IIC_IOCTL_START, 0);
dev_ioctl(stk8321_iic,
          IIC_IOCTL_TX_WITH_START_BIT,
          STK8321_IIC_WRITE_CMD);
dev_ioctl(stk8321_iic, IIC_IOCTL_TX, reg);
dev_ioctl(stk8321_iic,
          IIC_IOCTL_TX_WITH_STOP_BIT,
          value);
```

项目决定发哪个寄存器和值；杰里软件 I²C 驱动负责产生 PA7/PA8 的 START、数据位、ACK 和 STOP 波形。

当前 STK8321 驱动没有直接使用 `dev_read()`，因为读寄存器需要“先写寄存器地址，再重复 START 切换到读方向”，所以它也用多条 `dev_ioctl()` 逐步表达协议。

#### LCD 使用 `dev_open()`、`dev_ioctl()` 和 `dev_write()`

```c
lcd_drv.spi_hdl = dev_open("spi1", NULL);
dev_ioctl(lcd_drv.spi_hdl, IOCTL_SPI_NON_BLOCK, 1);
dev_write(lcd_drv.spi_hdl, (void *)map, len);
```

这里 `dev_ioctl()` 把 SPI 设置为非阻塞模式，`dev_write()` 再发送一块连续图像数据。

因此，同名接口的具体含义取决于设备句柄：I²C 命令不能拿给 SPI 使用，返回值也要遵循具体驱动的约定。

## 六、三类回调怎样注册和触发

三类回调函数都由项目实现，但注册和触发方式不同：

| 回调 | 项目实现 | 谁保存、谁触发 |
|---|---|---|
| 业务回调 | `paipop_events_shake_cb()` | `paipop_shake` 服务自己保存并调用 |
| 硬件回调 | `paipop_shake_int1_isr()`、`int2_isr()` | 通过杰里 `port_wakeup_reg()` 注册，由 GPIO 中断触发 |
| 定时回调 | `paipop_shake_process()` | 通过杰里 `sys_timer_add_to_task()` 注册，由系统每 20 ms 调度 |

### 1. 业务回调：普通函数指针

应用启动时传入：

```c
paipop_shake_start(paipop_events_shake_cb, NULL);
```

摇一摇服务保存：

```c
shake.callback = cb;
shake.callback_priv = priv;
```

因此绑定结果是：

```text
shake.callback       → paipop_events_shake_cb
shake.callback_priv  → NULL
```

这层不使用杰理回调注册框架，只是普通 C 函数指针。

### 2. 硬件回调：项目传函数，SDK 等硬件

```c
shake.int1_wakeup_hdl =
    port_wakeup_reg(EVENT_IO_0,
                    IO_PORTA_05,
                    EDGE_POSITIVE,
                    paipop_shake_int1_isr);

shake.int2_wakeup_hdl =
    port_wakeup_reg(EVENT_IO_1,
                    IO_PORTA_06,
                    EDGE_POSITIVE,
                    paipop_shake_int2_isr);
```

项目调用注册接口并传入 ISR；杰里 SDK 自动配置 GPIO、保存函数地址并建立公共中断入口。之后的路径是：

```text
STK8321 把 INT1 拉高
  → PA5 出现上升沿
  ⇢ 杰里硬件中断入口
  ⇢ SDK 找到已注册的函数
  → paipop_shake_int1_isr()
```

这里 `⇢` 表示硬件或框架跳转，不是当前函数栈中的普通直接调用。

### 3. 定时回调：项目传函数，SDK 负责计时

```c
shake.timer_id =
    sys_timer_add_to_task("app_core",
                          NULL,
                          paipop_shake_process,
                          20);
```

项目只负责告诉 SDK：每 20 ms 在 `app_core` 中调用哪个函数。计时、通知目标任务和调度回调由杰里 SDK 完成。

### 4. `int1_pending = 1` 和业务回调是什么关系

硬件 ISR 非常短：

```c
static void paipop_shake_int1_isr(void)
{
    shake.int1_pending = 1;
}
```

`int1_pending = 1` 只表示：

> PA5 刚才来过中断，请任务环境稍后检查。

它不等于“已经确认一次有效摇动”，也不保证一定调用业务回调。20 ms 处理函数会先取走 pending：

```c
source = paipop_shake_take_pending_source();
if (!source) {
    return;
}
```

然后才读取传感器并判断：

```c
event_info = stk8321_read_event_info();
stk8321_read_xyz(&x, &y, &z);
status = stk8321_clear_or_read_int_status();

if (now_ms - shake.last_shake_ms < 600) {
    return;
}

if (!(status & STK8321_INTSTS1_ANY_MOT_STS)) {
    return;
}
```

只有确认 `ANY_MOTION` 且不在 600 ms 冷却期内，才调用：

```c
if (shake.callback) {
    shake.callback(shake.callback_priv);
}
```

因为前面已经保存过函数地址，这句在当前应用中等价于：

```c
paipop_events_shake_cb(NULL);
```

完整关系是：

```text
注册业务回调
  → 只保存函数地址，暂时不调用

PA5/PA6 上升沿
  → ISR 设置 pending
  ⇢ 20 ms 定时回调
  → 读取 STK8321 并确认有效运动
  → 调用已保存的业务回调
```

可以把 `pending` 看成“门铃响过的标志”，把业务回调看成“确认门口真的有人后应该通知谁”。

### 5. 为什么不直接在硬件回调里执行业务

硬件中断环境要求尽快返回。这里不能直接进行完整业务处理，主要有三个原因：

1. I²C 读状态和 XYZ 需要多次传输，比置一个标志慢得多；
2. PA5/PA6 上升沿还只是原始信号，必须检查 `ANY_MOTION` 和 600 ms 冷却；
3. 日志、系统事件、FSM 和语音中断都不适合在硬件中断上下文执行。

因此采用常见的嵌入式分工：

```text
硬件 ISR：只负责“通知”
任务回调：负责“确认和处理”
业务回调：负责“告诉产品层发生了什么”
```

这既保护系统实时性，也避免把误中断直接当成产品动作。

### 6. 为什么 20 ms 回调不直接写死业务函数

先澄清：业务回调**确实是在** `paipop_shake_process()` 这个 20 ms 回调中执行的。区别只是它没有写死：

```c
paipop_events_shake_cb(NULL);
```

而是调用提前保存的函数指针：

```c
shake.callback(shake.callback_priv);
```

如果写死，`paipop_shake.c` 就必须依赖 Paipop 玩具事件层。使用回调后，摇一摇服务只负责“检测有效摇动”，使用者决定“摇动后做什么”：

```c
// 当前产品：转换成玩具事件
paipop_shake_start(paipop_events_shake_cb, NULL);

// 工厂测试：可以换成测试回调
paipop_shake_start(factory_shake_test_cb, test_context);
```

所以业务回调的价值主要是解耦和复用，不是为了提高速度。

## 七、有效摇动最终怎样影响业务

当前业务回调先检查 OTA：

```c
void paipop_events_shake_cb(void *priv)
{
    if (paipop_ota_is_busy()) {
        return;
    }

    paipop_events_post(PAIPOP_EVT_SHAKE, 0);
}
```

`paipop_events_post()` 再调用杰里事件框架：

```c
sys_event_notify(SYS_DEVICE_EVENT,
                 PAIPOP_DEVICE_EVENT_FROM_APP,
                 &dev,
                 sizeof(dev));
```

之后事件回到应用：

```text
sys_event_notify()
  ⇢ 杰里系统事件框架
  → paipop_toy_event_handler()
  → paipop_events_handle_sys_event()
  → paipop_events_handle_device()
  → paipop_fsm_dispatch(PAIPOP_EVT_SHAKE, 0)
```

FSM 只有在 `ENGINE_CHAT` 中才处理摇动：

```c
case PAIPOP_EVT_SHAKE:
    if (state == PAIPOP_TOY_STATE_ENGINE_CHAT) {
        // 省略重复触发保护和失败恢复
        paipop_fsm_mark_shake_restart_requested();
        paipop_engine_interrupt_chat("shake interrupt");
        paipop_fsm_start_shake_interrupt_timer();
    }
    return 0;
```

因此底层一次电平变化不会直接控制语音：

- OTA 正忙：业务回调直接忽略；
- 不在聊天状态：FSM 收到事件但不执行打断；
- 正在聊天：请求退出当前语音轮次，等 SDK 上报退出并完成保护后，再继续同一会话。

## 八、哪些步骤由代码调用，哪些由 SDK 自动完成

| 起点 | 项目主动调用 | 后续自动过程 |
|---|---|---|
| 启动应用 | `start_app(&it)` | 杰理查应用表并回调 `APP_STA_START` |
| 创建眼睛任务 | `thread_fork(..., paipop_eye_task, ...)` | 杰理调度器运行眼睛任务 |
| 打开 I²C | `dev_open("iic0", NULL)` | 杰理查设备表并调用 `iic_dev_ops.open` |
| 发送 I²C 命令 | `dev_ioctl(...)` | 杰理软件 I²C 产生 PA7/PA8 时序 |
| 注册 GPIO 回调 | `port_wakeup_reg(..., isr)` | 硬件上升沿后杰理调用项目 ISR |
| 注册定时回调 | `sys_timer_add_to_task(..., process, 20)` | 杰理每 20 ms 在 `app_core` 调用处理函数 |
| 注册业务回调 | `paipop_shake_start(callback, priv)` | 这层由项目服务保存，确认有效摇动后自行调用 |
| 投递产品事件 | `sys_event_notify(...)` | 杰理事件框架把事件送到应用处理器 |

最重要的判断方法是：

> 项目先把名字、参数或函数地址交给框架；框架保存后，真正的硬件中断、时间到期或系统事件发生时，才自动调用对应入口。

## 九、总图、易错点与讲解提纲

### 1. 把整个过程压缩成一张图

```text
app_main()
  → init_intent(&it)
  → it.name = "paipop_toy"
  → start_app(&it)
  ⇢ 杰理应用框架回调 APP_STA_START
  ├─ paipop_eye_service_init()
  │    → eye_init()
  │    → thread_fork(..., paipop_eye_task, ...)
  │    ⇢ 眼睛任务轮询 snapshot
  │         → generation 变化时切换动画
  │
  └─ paipop_shake_start(paipop_events_shake_cb, NULL)
       → dev_open("iic0")
       → 初始化 STK8321 / Any Motion
       → port_wakeup_reg(PA5/PA6, ISR)
       → sys_timer_add_to_task(app_core, process, 20ms)

设备发生摇动
  ⇢ STK8321 INT1/INT2 拉高
  ⇢ 杰里 GPIO 中断
  → ISR：pending = 1
  ⇢ 20 ms 定时回调
  → 读状态、XYZ、清锁存、检查冷却
  → shake.callback(...)
  → paipop_events_shake_cb()
  → PAIPOP_EVT_SHAKE
  ⇢ 杰里系统事件
  → Paipop FSM
  → 在 ENGINE_CHAT 中请求中断当前对话
```

### 2. 几个最容易讲错的地方

1. `SPEAKING` 是 AI/TTS 输出，不是用户正在说话。
2. `generation++` 不是消息队列，但仍是受互斥锁保护的任务通信。
3. `paipop_eye_snapshot()` 不只是读取，还消费 `manual_blink` 和 `ota_progress_dirty` 两个一次性标志。
4. PA7/PA8 是 I²C，PA5/PA6 是 STK8321 中断。
5. 设备注册不会自动读取设备；`dev_open/dev_ioctl` 才开始实际操作。
6. 三类回调函数都由项目实现，但硬件和定时回调由杰理 SDK 调度。
7. `pending = 1` 只代表原始中断来过，不代表已经确认有效摇动。
8. 业务回调已经在 20 ms 任务回调中执行，函数指针只是避免写死业务依赖。
9. 当前 `paipop_shake_stop()` 会注销中断并删除定时器，但没有调用已经定义的 `stk8321_deinit()`，不能说它关闭了 `iic0` 句柄。

### 3. 怎样用一分钟给别人讲清楚

可以这样讲：

> 杰理启动 `paipop_toy` 后，我的 `APP_STA_START` 会初始化眼睛、FSM、事件、摇一摇和 Wi-Fi。眼睛用独立任务刷新双 LCD，FSM 只修改 `IDLE`、`LISTENING`、`SPEAKING` 等高层行为；共享状态由互斥锁保护，`generation` 是版本号，眼睛任务通过 `snapshot` 一次取走最新状态。摇一摇方面，板级代码把 `iic0` 注册为 PA7、PA8 上的软件 I²C，STK8321 驱动用 `dev_open` 和 `dev_ioctl` 配置 Any Motion；PA5、PA6 通过杰里 `port_wakeup_reg` 注册硬件回调，中断里只设置 pending。杰里每 20 ms 在 `app_core` 调用处理函数，任务环境再读传感器、检查 600 ms 冷却，确认有效后调用业务回调。业务回调把摇动转换成 `PAIPOP_EVT_SHAKE`，最后由 FSM 根据当前是否正在聊天决定要不要中断对话。

### 4. 源码索引

| 主题 | 源码位置 |
|---|---|
| 应用启动和模块初始化 | `app_main.c:95-171` |
| 眼睛共享状态与动画任务 | `src/services/paipop_eye_service.c:19-68, 140-158, 520-778` |
| `generation` 和行为设置 | `src/services/paipop_eye_service.c:800-815` |
| LCD/SPI 设备操作 | `src/drivers/lcd.c:63-126, 490-543` |
| 摇一摇控制对象和 ISR | `src/services/paipop_shake.c:8-69` |
| 摇一摇确认和业务回调 | `src/services/paipop_shake.c:79-200` |
| STK8321 I²C 访问 | `src/drivers/stk8321.c:7-123` |
| STK8321 初始化与 Any Motion | `src/drivers/stk8321.c:209-289` |
| `iic0` 板级设备注册 | `board/wl82/paipop_v1_1_board.c:50-55, 181-188` |
| 摇一摇转产品事件 | `src/app/paipop_events.c:136-156, 256-279` |
| FSM 处理摇一摇 | `src/app/paipop_fsm.c:916-940` |
| 杰里 GPIO 回调实现 | SDK `cpu/wl82/port_waked_up.c:43-60, 96-204` |
| 杰里设备与定时器接口 | SDK `include_lib/driver/device/device.h`、`include_lib/system/timer.h` |

## 总结

这一部分的核心不是记住所有函数，而是分清三种边界：

```text
产品状态 → 眼睛行为：共享状态 + generation
设备名字 → 硬件驱动：设备注册表 + dev_* 接口
硬件/时间 → 项目函数：回调注册 + SDK 调度
```

眼睛任务体现的是“只取最新状态”的任务协作；摇一摇体现的是“ISR 最小化、任务延后处理、业务回调解耦”。理解这两条链后，再看按键、Wi-Fi、语音 SDK 和 OTA 的异步事件，就不会把所有逻辑误认为是一条从 `app_main()` 顺序执行到底的普通函数调用。
