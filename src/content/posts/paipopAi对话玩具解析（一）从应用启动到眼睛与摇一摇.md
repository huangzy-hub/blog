---
title: paipopAi对话玩具解析（一）：从 APP_STA_START 到眼睛任务与摇一摇服务
published: 2026-08-27
updated: 2026-08-27
pinned: false
description: 从 APP_STA_START 展开 Paipop 玩具的两条异步服务链：眼睛任务如何用 mutex、generation 和 snapshot 驱动 SPI/LCD，摇一摇服务如何通过 STK8321、I²C、中断、pending 和 20 ms 定时回调确认运动并发布业务事件。
tags: [AC791N, Paipop, 嵌入式, STK8321, 回调函数, 任务通信]
category: 嵌入式
series: Paipop AI 对话玩具源码解析
seriesOrder: 2
draft: false
---

# paipopAi对话玩具解析（一）：从 APP_STA_START 到眼睛任务与摇一摇服务

上一篇已经追踪了杰理 AC79 怎样把 `paipop_toy` 注册进 `.app` 段，以及 `start_app()` 怎样让应用最终进入 `APP_STA_START`。这篇不再重复宏展开、链接脚本和应用查找，而是从 `APP_STA_START` 往下看：应用启动后，眼睛动画和摇一摇检测为什么不会挤在一条顺序调用链里，它们又分别怎样借助杰理 SDK 工作。

本文基于 Paipop 工程 `test` 分支的 `4f8fa14` 源码快照整理，采用静态源码和 SDK 接口证据，没有重新运行固件。`CONFIG_PAIPOP_VOICE_CHAIN_ONLY`、`CONFIG_PAIPOP_LCD_DISABLE` 和 `CONFIG_PAIPOP_SHAKE_DISABLE` 会裁掉相应服务；下面描述的是这些功能未被关闭时的主路径。文中“项目代码”指当前 `Paipop_YP_Toy` 仓库中的第一方实现，不表示已经通过 Git 历史确认每一行的个人作者。

## 阅读导航

1. [杰理 AC79 应用启动与注册机制详解](/posts/杰理ac79应用启动与注册机制详解/)：应用描述符怎样形成，`app_core` 怎样找到并启动应用。
2. **本文**：`APP_STA_START` 怎样建立眼睛任务与摇一摇服务两条异步工作链。
3. [paipopAi对话玩具解析（二）：从按键与摇一摇到对话打断](/posts/paipopai对话玩具解析二从按键与摇一摇到对话打断/)：回调怎样接入杰理事件框架，事件怎样进入业务 FSM。

## 一、`APP_STA_START` 建立两条并行服务链

杰理应用框架进入项目实现的 `paipop_toy_state_machine()` 后，本文关心的两个入口都在 `APP_STA_START` 分支中：

```c
case APP_STA_START:
#if !defined CONFIG_PAIPOP_VOICE_CHAIN_ONLY && \
    !defined CONFIG_PAIPOP_LCD_DISABLE
    paipop_eye_service_init();
#endif

    /* FSM、OTA、按键和事件层初始化略 */

#if !defined CONFIG_PAIPOP_VOICE_CHAIN_ONLY && \
    !defined CONFIG_PAIPOP_SHAKE_DISABLE
    paipop_shake_start(paipop_events_shake_cb, NULL);
#endif

    /* Wi-Fi 和业务启动事件略 */
    break;
```

`paipop_eye_service_init()` 和 `paipop_shake_start()` 都是应用启动时执行的准备函数。前者创建长期运行的动画任务，后者把传感器、中断、定时器和业务回调接好。真正的画面刷新或摇动处理发生在后续任务和回调中，并不会在 `APP_STA_START` 里一次做完。

下面这张图是全文主线。`→` 表示当前源码中的直接调用，`⇢` 表示任务切换、硬件中断或注册后回调，不应理解成同一调用栈中的普通函数调用。

```text
APP_STA_START
├─ 眼睛链
│  → paipop_eye_service_init()
│  → 创建 mutex、初始化 LCD
│  → thread_fork(..., paipop_eye_task, ...)
│  ⇢ paipop_eye_task() 周期运行
│     → snapshot 取得 behavior + generation
│     → 生成眼睛姿态与动画
│     → dev_write(spi_hdl, ...) 刷新双 LCD
│
└─ 摇一摇链
   → paipop_shake_start(paipop_events_shake_cb, NULL)
   → dev_open(iic0) 并初始化 STK8321
   → port_wakeup_reg(PA5/PA6, ISR)
   → sys_timer_add_to_task(app_core, process, 20 ms)
   ⇢ PA5/PA6 中断：ISR 只设置 pending
   ⇢ 20 ms 回调：读取传感器、检查 600 ms 冷却
   → shake.callback(...)
   → paipop_events_shake_cb()
   → paipop_events_post(PAIPOP_EVT_SHAKE)
   → sys_event_notify(...)              本文到此为止
```

这两条链有共同原则：产品层只给出“想要什么”或“发生了什么”，耗时工作放到合适的任务环境；硬件和框架只负责执行或通知，不替产品做业务决策。

## 二、眼睛链：业务只给行为，动画任务负责渲染

### 1. `paipop_eye_service_init()` 真正创建动画任务

初始化函数先清空控制对象、创建互斥锁，再初始化眼睛/LCD，最后调用杰理 `thread_fork()`：

```c
int paipop_eye_service_init(void)
{
    int ret;

    memset(&eye_hdl, 0, sizeof(eye_hdl));
    eye_hdl.behavior = PAIPOP_EYE_BEHAVIOR_CLOSED;

    ret = os_mutex_create(&eye_hdl.mutex);
    if (ret != OS_NO_ERR) {
        return ret;
    }
    eye_hdl.sync_ready = 1;

    ret = eye_init();
    if (ret) {
        return ret;
    }

    eye_hdl.eye_ready = 1;
    ret = thread_fork(PAIPOP_EYE_TASK_NAME,
                      18, PAIPOP_EYE_TASK_STACK_SIZE, 0,
                      &eye_hdl.task_pid,
                      paipop_eye_task, NULL);
    return ret;
}
```

这里有两个不同性质的动作：

- `paipop_eye_service_init() → thread_fork()` 是项目对杰理 SDK 的直接调用；
- `thread_fork(..., paipop_eye_task, ...) ⇢ paipop_eye_task()` 是任务创建和调度边界，任务入口不会像普通函数那样在 `thread_fork()` 内顺序执行到结束。

`task_info_table` 中的同名条目是任务配置，不是“表一出现就自动运行”。在当前代码里，真正提出创建请求的是 `thread_fork()`。

眼睛单独使用任务，是因为它会持续处理随机注视、眨眼、表情插值、OTA 进度以及双 LCD 刷新。如果把这些工作放进 `app_core` 的业务处理路径，SPI 传输和动画等待可能拖慢按键、网络和语音控制消息。

### 2. `behavior` 是业务层与动画层的边界

眼睛服务只暴露四种高层行为：

```c
enum paipop_eye_behavior {
    PAIPOP_EYE_BEHAVIOR_CLOSED,
    PAIPOP_EYE_BEHAVIOR_IDLE,
    PAIPOP_EYE_BEHAVIOR_LISTENING,
    PAIPOP_EYE_BEHAVIOR_SPEAKING,
};
```

- `CLOSED`：暂时闭眼，例如部分配置或初始化阶段；
- `IDLE`：引擎就绪，等待下一步动作；
- `LISTENING`：设备正在采集用户语音；
- `SPEAKING`：AI 回答进入输出阶段，设备正在播放 TTS 音频。

业务层切换行为时，不直接画图，而是调用：

```c
void paipop_eye_set_behavior(enum paipop_eye_behavior behavior)
{
    paipop_eye_lock();
    if (eye_hdl.eye_ready && eye_hdl.behavior != behavior) {
        eye_hdl.behavior = behavior;
        eye_hdl.manual_blink = 0;
        eye_hdl.generation++;
    }
    paipop_eye_unlock();
}
```

因此职责边界是：业务层决定 `behavior`，眼睛任务决定这种行为对应怎样的开合度、注视位置、眨眼节奏和状态图标。

> **知识卡：`SPEAKING` 是谁在说？**
>
> `SPEAKING` 表示 AI/TTS 正在通过扬声器输出，不是用户正在说话。用户说话对应 `LISTENING`。眼睛服务不理解 ASR、LLM 或 TTS 的内部协议，只接收已经归一化的高层行为。

### 3. `mutex + generation + snapshot` 怎样交换状态

两边通过文件级控制对象共享状态：

```c
struct paipop_eye_hdl {
    OS_MUTEX mutex;
    u8 sync_ready;
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

static struct paipop_eye_hdl eye_hdl;
```

眼睛任务每轮先取得一次快照：

```c
paipop_eye_snapshot(&requested,
                    &requested_generation,
                    &exit_req,
                    &manual_blink,
                    &ota_active,
                    &ota_progress,
                    &ota_progress_dirty);
```

`paipop_eye_snapshot()` 在一个很短的加锁区间内复制所有字段，并消费两个一次性标志：

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

解锁后，任务使用局部变量计算和绘图。这样既保证这一组值来自同一份状态，又不会在耗时的动画和 SPI 输出期间一直占着互斥锁。

当 `requested_generation != generation` 时，任务知道控制状态发生过更新，于是停止旧动作并应用最新行为：

```c
if (requested_generation != generation) {
    generation = requested_generation;
    behavior = requested;
    motion.moving = 0;
    motion.base_open = paipop_eye_behavior_open(behavior);
    motion.status = paipop_eye_behavior_status(behavior);
    /* 显示新姿态并重新安排动画 */
}
```

> **知识卡：为什么 `generation++` 不换成消息队列？**
>
> 眼睛通常只关心最新目标。例如短时间内发生 `IDLE → LISTENING → SPEAKING`，屏幕没有必要依次补播三个旧命令。`behavior` 保存最新值，`generation` 保存版本；即使行为绕一圈又回到原值，版本变化仍能让任务重新安排动画。这是“最新状态优先”的任务通信，代价是不会立即唤醒任务，也不保证逐条保留历史命令。若每条命令都不能丢，应使用消息队列或其他可计数同步机制。

> **知识卡：`snapshot()` 为什么传一串地址？**
>
> 调用点的 `&requested` 等表达式把局部变量地址交给函数，函数再通过 `*behavior`、`*generation` 等输出参数写回多项结果。一次加锁得到整组快照，比为每个字段分别加锁更容易保持一致；`manual_blink` 和 `ota_progress_dirty` 在取走后清零，属于一次性通知。

### 4. 动画最后通过 `spi1` 写入 LCD

板级代码把 `spi1` 的操作表和硬件参数注册为设备记录：

```c
SPI1_PLATFORM_DATA_BEGIN(spi1_data)
    .clk = 20000000,
    .mode = SPI_1WIRE_MODE,
    .port = 'B',
SPI1_PLATFORM_DATA_END()

REGISTER_DEVICES(device_table) = {
    /* ... */
    {"spi1", &spi_dev_ops, (void *)&spi1_data},
    /* ... */
};
```

LCD 驱动按名字打开设备，并通过统一设备接口配置和发送数据：

```c
lcd_drv.spi_hdl = dev_open("spi1", NULL);
dev_ioctl(lcd_drv.spi_hdl, IOCTL_SPI_NON_BLOCK, 1);

/* 刷新图像时 */
ret = dev_write(lcd_drv.spi_hdl, (void *)map, len);

/* 等待非阻塞发送完成 */
dev_ioctl(lcd_drv.spi_hdl,
          IOCTL_SPI_WRITE_NON_BLOCK_FLUSH,
          0);
```

`REGISTER_DEVICES` 只建立“名字 → 驱动操作表 → 平台参数”的映射。`dev_open("spi1")` 查到记录并返回句柄，后续 `dev_ioctl/dev_write` 再通过句柄进入 SPI 驱动。它不是系统事件注册，也不会自动把 SPI 操作送到应用事件处理器。

杰理通用设备接口可以这样记：

- `dev_open()`：按名字找到设备并得到句柄；
- `dev_ioctl()`：发送设备专用控制命令；
- `dev_write()`：写一段连续数据；
- `dev_read()`：读一段连续数据；
- `dev_close()`：关闭句柄。

当前眼睛链使用 `open/ioctl/write`；后面的 STK8321 链使用 `open/ioctl`。这两条路径都没有直接调用 `dev_read()`，因为 STK8321 的重复 START、ACK 和 STOP 时序由多条 I²C `ioctl` 明确表达。

## 三、摇一摇链：原始中断先变成“有效摇动”

### 1. `paipop_shake_start()` 一次把整条链接好

应用启动时传入业务回调：

```c
paipop_shake_start(paipop_events_shake_cb, NULL);
```

`paipop_shake_start()` 的顺序是：

1. 清空 `shake` 并保存 `cb/priv`；
2. 调用 `stk8321_init()`，打开 I²C、复位并检查芯片；
3. 调用 `stk8321_shake_int_init()`，配置 Any Motion；
4. 把 PA5、PA6 上升沿分别绑定到两个 ISR；
5. 在 `app_core` 上注册 20 ms 周期回调；
6. 返回，让应用继续初始化其他模块。

关键代码如下：

```c
memset(&shake, 0, sizeof(shake));
shake.callback = cb;
shake.callback_priv = priv;

ret = stk8321_init();
if (ret) {
    return ret;
}

ret = stk8321_shake_int_init();
if (ret) {
    return ret;
}

shake.started = 1;
shake.last_shake_ms =
    timer_get_ms() - PAIPOP_SHAKE_COOLDOWN_MS;

shake.int1_wakeup_hdl =
    port_wakeup_reg(EVENT_IO_0, IO_PORTA_05,
                    EDGE_POSITIVE, paipop_shake_int1_isr);
shake.int2_wakeup_hdl =
    port_wakeup_reg(EVENT_IO_1, IO_PORTA_06,
                    EDGE_POSITIVE, paipop_shake_int2_isr);

shake.timer_id =
    sys_timer_add_to_task("app_core", NULL,
                          paipop_shake_process, 20);
```

这些注册调用只证明框架已经保存了入口。PA5/PA6 是否真的产生中断、定时器是否按预期运行，仍属于硬件和运行时行为；本文没有把它写成已经观测到的结果。

### 2. `shake` 保存服务的全部运行状态

`shake` 是 `paipop_shake.c` 内的文件级静态对象：

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

它同时保存资源句柄、ISR 与任务之间的 pending 标志、统计和冷却时间，以及业务回调地址。文件级 `static` 让它只能被当前 C 文件直接访问，静态存储期也让它在程序启动时先被清零。

> **知识卡：`shake` 是设备对象吗？**
>
> 不是。它是项目摇一摇服务的控制块。真正的 STK8321 通信句柄保存在 `stk8321.c` 的 `stk8321_iic` 中；杰理的 GPIO 中断句柄和定时器 ID只是被 `shake` 记录下来，便于停止服务时注销。

### 3. I²C 负责配置和读取 STK8321

板级软件 I²C 使用 PA7、PA8：

```c
SW_IIC_PLATFORM_DATA_BEGIN(sw_iic0_data)
    .clk_pin = IO_PORTA_07,
    .dat_pin = IO_PORTA_08,
    .sw_iic_delay = 50,
SW_IIC_PLATFORM_DATA_END()

REGISTER_DEVICES(device_table) = {
    /* ... */
    {"iic0", &iic_dev_ops, (void *)&sw_iic0_data},
    /* ... */
};
```

STK8321 驱动主动打开它：

```c
#define STK8321_IIC_DEV_NAME "iic0"

stk8321_iic = dev_open(STK8321_IIC_DEV_NAME, NULL);
```

写寄存器时，项目决定设备地址、寄存器和值；杰理软件 I²C 驱动负责实际产生 PA7/PA8 波形：

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

`stk8321_init()` 随后执行软件复位、读取 `CHIP_ID`、进入正常功耗模式、设置量程和带宽，并回读关键寄存器。`stk8321_shake_int_init()` 再配置运动阈值、X/Y/Z 三轴 slope 检测、有效电平、映射和锁存状态。

因此四根线分工明确：

- PA7/PA8：MCU 主动通过 I²C 读写传感器；
- PA5/PA6：STK8321 检测到运动条件后通知 MCU。

I²C/SPI 的 `dev_*` 调用本身不会自动进入 `paipop_toy_event_handler()`。只有代码明确调用事件发布接口时，消息才进入杰理系统事件框架。

### 4. PA5/PA6 中断只留下 pending

中断注册把项目实现的 ISR 交给杰理 GPIO 唤醒框架：

```c
port_wakeup_reg(EVENT_IO_0,
                IO_PORTA_05,
                EDGE_POSITIVE,
                paipop_shake_int1_isr);

port_wakeup_reg(EVENT_IO_1,
                IO_PORTA_06,
                EDGE_POSITIVE,
                paipop_shake_int2_isr);
```

真正的 ISR 很短：

```c
static void paipop_shake_int1_isr(void)
{
    shake.int1_pending = 1;
}

static void paipop_shake_int2_isr(void)
{
    shake.int2_pending = 1;
}
```

`pending = 1` 只表示“对应引脚来过中断，请任务环境稍后检查”，并不等于已经确认一次有效摇动。ISR 不在这里读 I²C、不发系统事件，也不打断对话，原因是：

- I²C 传输和日志比写一个标志慢得多；
- 引脚上升沿还需要通过 STK8321 状态确认；
- 系统事件、FSM 和语音控制不适合在硬件中断上下文执行。

### 5. 20 ms 回调确认 Any Motion 和冷却时间

启动函数把 `paipop_shake_process()` 注册到 `app_core`：

```c
sys_timer_add_to_task("app_core", NULL,
                      paipop_shake_process, 20);
```

按照杰理定时器接口契约，时间到后框架会在目标任务环境调用它。处理函数先取走 pending，没有中断就立即返回；有中断才读传感器：

```c
source = paipop_shake_take_pending_source();
if (!source) {
    return;
}

now_ms = timer_get_ms();
event_info = stk8321_read_event_info();
(void)stk8321_read_xyz(&x, &y, &z);
status = stk8321_clear_or_read_int_status();

if ((u32)(now_ms - shake.last_shake_ms) < 600) {
    return;
}

if (!(status & STK8321_INTSTS1_ANY_MOT_STS)) {
    return;
}

shake.last_shake_ms = now_ms;
shake.shake_count++;

if (shake.callback) {
    shake.callback(shake.callback_priv);
}
```

这里进行了两次过滤：

1. `STK8321_INTSTS1_ANY_MOT_STS` 确认这次原始 GPIO 通知确实对应运动状态；
2. 600 ms 冷却把一次摇动引发的密集边沿合并，避免连续触发上层业务。

> **知识卡：`shake` 不需要互斥锁吗？**
>
> `started`、计数、冷却时间和回调主要在 `app_core` 的处理路径中使用，正常路径不需要给整个对象套一个普通互斥锁。真正跨上下文的是 ISR 写、任务读清的两个 pending。普通互斥锁不能在 ISR 中阻塞使用，`volatile` 也只约束编译器访问，并不提供完整同步保证。当前布尔 pending 加 600 ms 冷却允许多个边沿合并，因此容忍少量读清竞争；若业务要求每个硬件边沿都不能丢，应使用关中断临界区、原子交换或 ISR 安全队列，而不是普通任务互斥锁。若其他任务也要直接调用 start/stop，则还应把生命周期操作串行化。

### 6. 停止服务按相反顺序撤销资源

`paipop_shake_stop()` 先删除定时器，再注销 PA5/PA6 中断，随后关闭传感器中断配置并清空 `shake`。当前实现没有调用已经存在的 `stk8321_deinit()`，因此不能说 stop 会关闭 `iic0` 句柄；这只是当前源码事实，不影响本文所追踪的启动和检测主链。

## 四、业务回调把有效摇动交给事件层

启动时传入、服务中保存、确认后调用的是同一个函数地址：

```c
/* APP_STA_START */
paipop_shake_start(paipop_events_shake_cb, NULL);

/* paipop_shake_start() */
shake.callback = cb;
shake.callback_priv = priv;

/* paipop_shake_process() */
if (shake.callback) {
    shake.callback(shake.callback_priv);
}
```

因此在当前注册路径中，最后一段间接调用的候选目标已经被限定为 `paipop_events_shake_cb(NULL)`。这是普通 C 函数指针回调：摇一摇服务只负责确认“发生了有效摇动”，使用者决定接下来做什么。

业务回调先过滤 OTA，再调用事件层：

```c
void paipop_events_shake_cb(void *priv)
{
    if (paipop_ota_is_busy()) {
        return;
    }

    paipop_events_post(PAIPOP_EVT_SHAKE, 0);
}
```

`paipop_events_post()` 才把项目业务事件包装成杰理系统事件：

```c
int paipop_events_post(enum paipop_toy_event event, int value)
{
    struct device_event dev = {0};

    dev.event = (unsigned char)event;
    dev.value = value;
    dev.arg = NULL;

    return sys_event_notify(SYS_DEVICE_EVENT,
                            PAIPOP_DEVICE_EVENT_FROM_APP,
                            &dev,
                            sizeof(dev));
}
```

本文在 `sys_event_notify()` 处收住。到这里可以确认：

- 硬件中断回调、20 ms 定时回调和业务回调属于回调机制；
- `sys_event_notify()` 开始进入另一套系统事件框架；
- 回调可以独立存在，也可以像这里一样成为事件框架的上游；
- 注册和源码调用关系能够证明可能的投递路径，但本文没有运行固件去观测一次真实摇动。

事件随后怎样到达 `paipop_toy_event_handler()`、如何分类为按键/网络/设备事件、FSM 又怎样结合当前状态决定是否打断对话，放在[系列（二）](/posts/paipopai对话玩具解析二从按键与摇一摇到对话打断/)继续分析。

## 五、项目、SDK 与硬件分别负责什么

| 环节 | 项目代码负责 | 杰理 SDK 或硬件负责 | 调用性质 |
|---|---|---|---|
| 应用启动 | 在 `APP_STA_START` 调用两个服务初始化函数 | `app_core` 驱动应用生命周期回调 | SDK 到项目的生命周期回调 |
| 眼睛任务 | 实现 `paipop_eye_task()` 和动画策略 | `thread_fork` 创建任务，调度器运行任务 | 直接调用后发生任务切换 |
| 眼睛状态 | 维护 `behavior/generation/snapshot` | OS mutex 提供同步原语 | 项目共享状态，SDK 提供锁 |
| LCD 输出 | 生成图像并调用 `dev_write` | `spi_dev_ops` 和 SPI 硬件发送数据 | 设备操作表间接分派 |
| STK8321 | 实现寄存器协议和 Any Motion 配置 | `iic_dev_ops` 产生 I²C 时序，传感器检测运动 | 设备操作表与外部硬件 |
| GPIO 中断 | 实现两个短 ISR | `port_wakeup_reg` 保存入口，硬件边沿触发 | 回调注册与硬件异步跳转 |
| 20 ms 处理 | 实现 pending、状态确认和冷却 | 定时器系统向 `app_core` 调度回调 | 定时回调/任务边界 |
| 业务交接 | 实现 `paipop_events_shake_cb` 并发布事件 | 系统事件框架接收 `sys_event_notify` | 项目回调连接事件框架 |

表中项目函数都能在当前仓库找到定义，属于当前分析范围内的第一方项目源码；`thread_fork`、`dev_*`、`port_wakeup_reg`、`sys_timer_add_to_task` 和 `sys_event_notify` 是杰理 SDK 接口。STK8321 的 Any Motion 判断发生在外部传感器内部，项目只能通过寄存器配置和状态读取使用它。

## 六、总结与源码证据索引

整篇文章可以压缩成这段话：

> `APP_STA_START` 不是把所有业务顺序执行到底，而是建立多个后续工作入口。眼睛服务创建独立任务，业务层只在互斥锁下更新 `behavior` 和 `generation`，动画任务用 `snapshot` 取得最新状态，再通过 `spi1` 刷新 LCD。摇一摇服务通过 `iic0` 初始化 STK8321，把 PA5/PA6 上升沿注册给短 ISR，并在 `app_core` 中每 20 ms 检查 pending；只有传感器确认 Any Motion 且通过 600 ms 冷却，才调用业务回调。业务回调最后把 `PAIPOP_EVT_SHAKE` 发布给杰理事件框架，至于当前状态下是否打断对话，则是下一层 FSM 的职责。

关键证据如下：

| 主题 | 源码位置 | 证据强度 |
|---|---|---|
| `APP_STA_START` 启动两个服务及其编译条件 | `app_main.c:95-135` | 已验证：直接源码调用 |
| 眼睛控制对象、mutex 和 snapshot | `src/services/paipop_eye_service.c:52-158` | 已验证：项目定义 |
| 眼睛任务循环和 generation 检查 | `src/services/paipop_eye_service.c:520-744` | 已验证：项目定义 |
| 眼睛初始化与 `thread_fork` 注册 | `src/services/paipop_eye_service.c:746-779` | 已验证注册；实际调度未运行观测 |
| `spi1`/`iic0` 板级设备记录 | `board/wl82/paipop_v1_1_board.c:41-55, 181-188` | 已验证：项目配置引用 SDK 操作表 |
| LCD 的 `dev_open/ioctl/write` | `src/drivers/lcd.c:63-126, 490-520` | 已验证：项目对 SDK API 的直接调用 |
| STK8321 I²C 时序与初始化 | `src/drivers/stk8321.c:7-105, 209-289` | 已验证：项目驱动定义 |
| 摇一摇对象、ISR、20 ms 确认和回调 | `src/services/paipop_shake.c:8-200` | 已验证注册和项目逻辑；硬件触发未运行观测 |
| 停止服务的资源撤销范围 | `src/services/paipop_shake.c:204-225` | 已验证：未调用 `stk8321_deinit()` |
| 业务回调和事件发布边界 | `src/app/paipop_events.c:136-156` | 已验证：直接源码调用 |

理解这一篇的重点不是背函数名，而是看清两个设计边界：

- 眼睛链把“业务状态”与“动画渲染”分开；
- 摇一摇链把“硬件原始通知”与“有效业务事件”分开。

有了这两个边界，再进入下一篇的回调、系统事件和 FSM，就不会误以为所有变化都由 `app_core` 自己检测和决定。
