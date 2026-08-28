---
title: paipopAi对话玩具解析（二）：从按键与摇一摇到对话打断
published: 2026-08-27
updated: 2026-08-28
pinned: false
description: 沿着按键和摇一摇两条真实调用链，讲清回调、杰理系统事件、app_core、玩具状态机与 PaipopSDK 如何协作完成对话打断。
tags: [AC791N, Paipop, 嵌入式, 系统事件, 回调函数, 状态机]
category: 嵌入式
draft: false
---

# paipopAi对话玩具解析（二）：从按键与摇一摇到对话打断

## 阅读导航

1. [杰理 AC79 应用启动与注册机制详解：从 `REGISTER_APPLICATION` 到 `start_app`](/posts/杰理ac79应用启动与注册机制详解/)
2. [paipopAi对话玩具解析（一）：从 `APP_STA_START` 到眼睛任务与摇一摇服务](/posts/paipopai对话玩具解析一从应用启动到眼睛与摇一摇/)
3. **本文**：从外部刺激、系统事件一路追到玩具 FSM 和对话打断。

前两篇分别回答了两个问题：杰理怎样找到并启动 `paipop_toy` 应用，以及应用进入 `APP_STA_START` 后怎样创建眼睛任务、初始化 STK8321、注册 GPIO 中断和 20 ms 定时回调。

这一篇继续回答更接近产品逻辑的问题：**按一下按键或摇一下玩具，输入怎样变成业务事件，并由 FSM 决定下一步？** 只有玩具已经处于 `ENGINE_CHAT` 时，这两种输入才会请求结束当前轮次；在初始化、退出等其他状态中，同一个输入可能被排队、用于重试或直接忽略。

这条链路里同时出现了设备注册、函数回调、系统事件、`app_core` 和多层状态。它们不是同一种机制，也不是由 `app_core` 一手包办。先把整条主线记住：

> 驱动负责发现，回调负责通知，事件框架负责排队和路由，`app_core` 负责在任务上下文中依次执行，`paipop_events` 与 FSM 负责翻译和决策，PaipopSDK 负责真正执行。

本文基于 `Paipop_YP_Toy` 仓库 `test` 分支提交 `4f8fa14` 做静态分析。项目目录中的玩具业务代码和 `PaipopSDK` 封装层属于 Paipop 第一方代码；`app_core`、按键驱动、设备框架、定时器和系统事件接口属于杰理 SDK；`PaipopSDK` 下面的灵芯实现位于外部库边界。杰理事件分发与灵芯内部资源释放没有完整源码，因此文中会把能直接确认的调用与框架/库回调边界区分开。

## 一、先看完整控制链：六个角色各做什么

按键和摇一摇的来源不同，但进入业务层以后会汇合：

```text
现实刺激
  ↓
硬件与驱动发现变化
  ↓
回调或驱动事件报告
  ↓
杰理 sys_event 封装与投递
  ↓
当前应用的 event_handler
  ↓
paipop_events 分类并翻译成业务事件
  ↓
paipop_fsm：当前状态 + 业务事件
  ↓
PaipopSDK 执行退出/继续对话
  ↓
SDK 生命周期回调报告完成
```

可以把参与者分成六类：

| 角色 | 在本项目中负责什么 | 不负责什么 |
|---|---|---|
| 硬件和驱动 | 检测 GPIO、按键动作或 STK8321 中断 | 不理解“对话是否应该打断” |
| 回调机制 | 保存一个函数地址，在中断、定时或业务条件成立时调用 | 不自带消息类型、队列和路由 |
| 杰理系统事件框架 | 用 `type/from/payload` 封装低频控制消息并送给应用 | 不决定 Paipop 的业务状态 |
| `app_core` | 管理应用生命周期，并提供当前应用事件和部分定时回调的串行执行环境 | 不扫描按键，也不认识 `ENGINE_CHAT` |
| `paipop_events` 与 FSM | 把平台事件翻译为玩具事件，再结合当前状态做决定 | 不实现云端 ASR、LLM 或 TTS |
| PaipopSDK/灵芯 | 启停一轮对话、录放音、连接云端，并通过生命周期回调报告结果 | 不管理杰理的应用注册表 |

这张表是理解后面所有代码的基础：`app_core` 是调度环境，不是业务大脑；真正决定“现在该不该打断”的是 `paipop_fsm`。

## 二、`app_core` 串行，串行的边界在哪里

杰理公共初始化代码创建名为 `app_core` 的任务。该任务完成系统、板级和应用初始化后，进入消息循环：

```c
static void app_task_handler(void *p)
{
    /* 省略平台和板级初始化 */
    app_core_init();
    __do_initcall(late_initcall);
    app_main();

    while (1) {
        res = os_task_pend("taskq", msg, ARRAY_SIZE(msg));
        if (res != OS_TASKQ) {
            continue;
        }
        app_core_msg_handler(msg);
    }
}
```

源码位置：杰理 SDK `apps/common/system/init.c:180-232`。

这个循环一次取出一条任务消息，再处理下一条。因此，“由 `app_core` 串行管理”准确含义是：

- 投递到这个任务的消息会在同一个任务上下文中依次处理；
- 指定到 `app_core` 的定时回调也在这个任务中执行，例如摇一摇的 20 ms 处理函数；
- 一个事件处理函数没有返回前，`app_core` 不会同时在同一个任务栈里再执行另一条普通消息。

但它不代表整个系统只有一个执行流。眼睛动画任务、网络或语音 SDK 内部任务、定时器基础设施以及硬件 ISR 仍可能并发运行。因此：

> `app_core` 的串行可以减少业务控制流互相穿插，却不能自动保护其他任务和中断共享的数据，也不能代替必要的互斥锁、临界区或原子操作。

摇一摇服务这样注册定时回调：

```c
shake.timer_id = sys_timer_add_to_task(
    "app_core", NULL, paipop_shake_process, PAIPOP_SHAKE_TIMER_MS);
```

这里的第一个参数明确指定了执行任务。项目负责传入函数地址和 20 ms 周期，杰理定时系统负责计时，并在目标任务中调度 `paipop_shake_process()`。这是一次**定时回调注册**，还不是系统事件投递。

## 三、`sys_event`：当前应用的统一收件箱

### 1. 应用怎样留下事件入口

Paipop 应用把生命周期回调和系统事件回调放入同一张操作表：

```c
static const struct application_operation paipop_toy_ops = {
    .state_machine = paipop_toy_state_machine,
    .event_handler = paipop_toy_event_handler,
};

REGISTER_APPLICATION(paipop_toy) = {
    .name = "paipop_toy",
    .ops = &paipop_toy_ops,
    .state = APP_STA_DESTROY,
};
```

其中 `.state_machine` 接收 `APP_STA_START`、`APP_STA_STOP` 等应用生命周期状态，`.event_handler` 接收应用运行期间的系统事件。后者的实现很薄：

```c
static int paipop_toy_event_handler(struct application *app,
                                    struct sys_event *event)
{
    if (!event) {
        return false;
    }

    return paipop_events_handle_sys_event(event);
}
```

源码位置：`apps/Paipop_YP_Toy/app_main.c:95-161`。

它不是由项目代码反复手动调用的“收集函数”。项目只是把函数地址注册到操作表；事件到达当前应用时，杰理框架再通过该函数指针调用它。它自身也不保存事件，只把这封“信”交给项目的分类层。

这两个参数也要分清：`app` 是 `app_core` 提供的当前 `paipop_toy` 应用对象，当前实现没有用到它；`event` 是事件框架交付的外层 `struct sys_event`，不是按键驱动里局部变量 `e` 的地址。后面要先检查 `event->type` 再决定 `event->payload` 的结构类型；如果生产者不完全可信，健壮代码还应检查 `event->len` 是否足以容纳目标结构。

### 2. 从局部 `e/dev` 到 `event->payload`：装包、投递与拆包

杰理定义的系统事件结构是：

```c
#define SYS_KEY_EVENT       0x0001
#define SYS_TOUCH_EVENT     0x0002
#define SYS_DEVICE_EVENT    0x0004
#define SYS_NET_EVENT       0x0008
#define SYS_BT_EVENT        0x0010

struct sys_event {
    u16 type;
    u8 from;
    u8 len;
    u8 payload[0];
};
```

源码位置：杰理 SDK `include_lib/utils/event/event.h:9-25`。

可以把它理解成统一信封：

- `type` 表示大类，例如按键、网络或设备事件；
- `from` 表示来源；
- `len` 表示内容长度；
- `payload` 是具体事件数据。

**投递不是把局部指针原样留到以后。** 系统事件接口的签名是：

```c
int sys_event_notify(u16 type, u8 from, void *event, u8 len);
```

调用方给出“事件大类、来源、数据地址和数据长度”，事件框架据此把数据交付为带 `payload` 的统一事件。以按键为例，发送端的 `e` 是 `key_driver_scan()` 栈上的局部变量：

```c
struct key_event e = {0};

e.type = scan_para->key_type;
e.action = key_event;
e.value = key_value;
key_event_notify(KEY_EVENT_FROM_KEY, &e);
```

摇一摇则由项目显式创建另一种局部数据并调用系统接口：

```c
struct device_event dev = {0};

dev.event = PAIPOP_EVT_SHAKE;
dev.value = 0;
dev.arg = NULL;
sys_event_notify(SYS_DEVICE_EVENT,
                 PAIPOP_DEVICE_EVENT_FROM_APP,
                 &dev, sizeof(dev));
```

当前最终 `sdk.elf` 中，经过 LTO 特化的本项目按键路径可以确认等效调用为 `sys_event_notify(SYS_KEY_EVENT, KEY_EVENT_FROM_KEY, event, 6)`；这里的 6 是当前 ABI 下 `struct key_event` 的大小。这个证据只确认当前 K1/K2 路径，不泛化为所有构建、所有 `from` 参数都完全相同。后续应用回调看到的数据关系应理解为：

```text
发送时                         接收时

&e → struct key_event          event → struct sys_event
      type/action/value                 type = SYS_KEY_EVENT
                                        from = KEY_EVENT_FROM_KEY
                                        payload → e 的字段内容
```

因此 `paipop_toy_event_handler(app, event)` 中的 `event` **不等于**原来的 `&e`；类型也不同：前者是 `struct sys_event *`，后者是 `struct key_event *`。但将 `event->payload` 转回 `struct key_event *` 后，读到的 `type/action/value` 来自发送时的 `e`。当前 ELF 的反汇编还确认，事件框架把 4 字节信封头和 `len` 字节负载复制进内部环形缓冲区；这是字节级浅拷贝，结构体中的指针所指对象不会被继续深拷贝，本项目摇一摇消息里的 `dev.arg` 恰好为 `NULL`。精确 C 实现仍在杰理二进制库边界，本文不把反汇编结论虚构成某段可见的 `malloc/memcpy` 源码。公开接口也没有承诺 `payload` 在回调结束后仍然有效，因此处理函数不应把这个指针保存起来长期使用；确实需要跨回调保留时，应复制所需字段到自己管理的存储中。

项目先判断 `type`，再决定怎样解释 `payload`：

```c
int paipop_events_handle_sys_event(struct sys_event *event)
{
    if (!event) {
        return false;
    }

    switch (event->type) {
    case SYS_KEY_EVENT:
        return paipop_events_handle_key(
            (struct key_event *)event->payload);
    case SYS_NET_EVENT:
        return paipop_events_handle_net(
            (struct net_event *)event->payload);
    case SYS_DEVICE_EVENT:
        return paipop_events_handle_device(event);
    default:
        break;
    }

    return false;
}
```

源码位置：`src/app/paipop_events.c:282-299`。

虽然杰理定义了五类顶层事件，当前项目只在这里分类 `KEY`、`NET` 和 `DEVICE`。`TOUCH`、`BT` 或不属于本模块的事件会返回 `false`。必须先判断类型再转换 `payload`，否则可能把网络数据误当成 `struct key_event` 读取。这里的强制转换不会重新创建或复制一份按键事件，只是告诉 C 编译器“从这个地址开始，按照 `struct key_event` 的字段布局读取”。

不过，检查 `type` 只能确定“期望按哪种结构解释”，不能证明负载长度一定足够。当前构建的正常生产者分别发送 6 字节 `key_event` 和 12 字节 `device_event`，而 `paipop_events_handle_sys_event()` / `paipop_events_handle_device()` 没有校验 `event->len`，是在信任杰理 SDK 和项目内部生产者。若以后允许外部模块构造事件，更稳妥的解包条件应类似：

```c
event->type == SYS_KEY_EVENT &&
event->len >= sizeof(struct key_event)
```

`if (!dev)` 也不能替代长度检查：只要外层 `event` 非空，它尾部的 `payload` 地址通常就不是空指针，即使实际负载不足。

### 3. `true`、`false` 与默认事件处理器

事件回调的返回值表达的是“这封信有没有被当前应用消费”：

```text
true  → 当前应用已经处理，不需要默认处理器继续处理
false → 当前应用不处理，框架可以继续走后备路径
```

杰理的事件示例说明：当活动应用没有消费事件时，会调用弱定义的 `app_default_event_handler()`。Paipop 工程提供了自己的默认实现：已知的五类系统事件直接忽略，未知类型才触发断言。这里的 `true/false` 只用于说明应用消费与默认处理器的后备关系，并不能据此断言所有静态 `post_handler` 等后续钩子都会被跳过。

```c
void app_default_event_handler(struct sys_event *event)
{
    switch (event->type) {
    case SYS_KEY_EVENT:
    case SYS_TOUCH_EVENT:
    case SYS_DEVICE_EVENT:
    case SYS_NET_EVENT:
    case SYS_BT_EVENT:
        break;
    default:
        ASSERT(0, "unknown event type: %s\n", __func__);
        break;
    }
}
```

因此，默认处理器不是另一个业务 FSM，也不在 `paipop_toy_ops` 中。它更像活动应用没有消费事件时的兜底入口。

杰理公开头文件、官方事件示例和 `app_core` 任务循环能够确认上述接口契约。事件核心实现位于 SDK 库边界，所以后文用 `⇢` 表示由事件框架、任务或硬件完成的跳转，不把它画成当前源码中可见的普通直接调用。

## 四、按键链（FLOW-01）：K1/K2 怎样走到 FSM

按键是两条链中更直接的一条：板级配置把 PC1、PC2 映射为 K1、K2，`board_init()` 调用 `key_driver_init()` 后，由杰理按键驱动周期扫描、消抖并识别动作。这里注册的是按键硬件配置，不是把 `paipop_events_handle_key()` 直接挂到 GPIO。证据位于 `board/wl82/paipop_v1_1_board.c:105-123,209-215`。

`key_driver_scan()` 每轮先创建局部变量 `e`，通过 `scan_para->get_value()` 取得当前键值，再经过消抖和单击/长按判断：

```c
struct key_event e = {0};

cur_key_value = scan_para->get_value();
/* 省略消抖和 CLICK/LONG/HOLD/UP 判断 */

e.type = scan_para->key_type;
e.action = key_event;
e.value = key_value;

if (key_event_remap(&e)) {
    key_event_notify(KEY_EVENT_FROM_KEY, &e);
}
```

源码位置：杰理 SDK `apps/common/key/key_driver.c:60-190`。`action` 表示 `CLICK/LONG/HOLD/UP`，`value` 表示 K1/K2。`key_event_notify()` 已经进入杰理按键/系统事件链，项目不需要再包装一次 `SYS_KEY_EVENT`。

事件投递成功、框架把外层 `event` 交给 `paipop_toy_event_handler()` 后，后面的处理已经回到普通同步函数调用：

```c
/* 应用总入口：只负责转发 */
return paipop_events_handle_sys_event(event);

/* 分类层：先确认外层事件类型，再解释 payload */
case SYS_KEY_EVENT:
    return paipop_events_handle_key(
        (struct key_event *)event->payload);
```

`paipop_events_handle_key()` 再依次判断：是否为 K1/K2、OTA 是否忙、是否为 `KEY_EVENT_UP`，以及这次 `CLICK` 是否只是组合键释放产生的残余点击。普通单击最终被翻译为项目业务事件：

```c
if (key->action == KEY_EVENT_CLICK) {
    /* 省略组合键释放抑制 */
    return paipop_fsm_dispatch(PAIPOP_EVT_TOUCH_CLICK,
                               key->value) == 0;
}
```

源码位置：`src/app/paipop_events.c:158-208`。完整链路只需保留一张图：

```text
PC1/PC2
  ⇢ 杰理扫描、消抖和动作识别
  → 创建并填充局部 struct key_event e
  → key_event_notify(KEY_EVENT_FROM_KEY, &e)
  ⇢ sys_event：type=SYS_KEY_EVENT，payload=e 的内容
  ⇢ paipop_toy_event_handler(app, event)
  → paipop_events_handle_sys_event(event)
  → paipop_events_handle_key((key_event *)event->payload)
  → paipop_fsm_dispatch(PAIPOP_EVT_TOUCH_CLICK, key->value)
```

到这里，平台语义“哪个键发生了什么动作”已经变成产品语义“用户发起一次点击”。`key->value` 仍把 K1/K2 传给 FSM，但当前 `PAIPOP_EVT_TOUCH_CLICK` 分支没有按这个值区分行为，所以两个键的普通单击走相同业务路径。接下来是否结束当前轮次，仍由 FSM 根据状态决定。

## 五、摇一摇链（FLOW-02）：从业务回调进入系统事件

STK8321 初始化、PA5/PA6 中断和 20 ms 确认过程已经在[系列（一）](/posts/paipopai对话玩具解析一从应用启动到眼睛与摇一摇/)展开，这里只回顾事件层需要的前提：

```text
PA5/PA6 边沿
  → ISR 设置 shake.int1_pending / int2_pending
  ⇢ app_core 中的 20 ms 回调
  → I²C 检查 ANY_MOTION 和 600 ms 冷却
  → shake.callback(shake.callback_priv)
```

这两个硬件 pending 与稍后出现的 `fsm.shake_interrupt_pending` 不是同一个变量：

| 标志 | 所在模块 | 访问方式 | 可确认的含义 |
|---|---|---|---|
| `shake.int1_pending/int2_pending` | `paipop_shake.c` | `volatile u8`，ISR 写、20 ms 回调读清 | 原始引脚中断等待确认 |
| `fsm.shake_interrupt_pending` | `paipop_fsm.c` | 在 FSM mutex 下读写 | 业务打断请求已占位，暂不接受重复请求 |

不能仅凭同名后缀推断两者具有相同的同步语义；前者可能合并硬件边沿，后者用于保护项目的 SDK 请求流程。

当前源码注册关系中，`paipop_shake_start(paipop_events_shake_cb, NULL)` 把回调目标限定为 `paipop_events_shake_cb()`。确认有效摇动后，它先过滤 OTA，再把业务事件装进 `SYS_DEVICE_EVENT`：

```c
void paipop_events_shake_cb(void *priv)
{
    if (paipop_ota_is_busy()) {
        return;
    }
    paipop_events_post(PAIPOP_EVT_SHAKE, 0);
}

int paipop_events_post(enum paipop_toy_event event, int value)
{
    struct device_event dev = {0};

    dev.event = (unsigned char)event;
    dev.value = value;
    dev.arg = NULL;
    return sys_event_notify(SYS_DEVICE_EVENT,
                            PAIPOP_DEVICE_EVENT_FROM_APP,
                            &dev, sizeof(dev));
}
```

源码位置：`src/app/paipop_events.c:136-156`。`dev` 的局部生命周期和装包原则已经在第三节说明；对这次摇一摇而言，应用回调收到的外层事件可以具体读成：

```text
event->type    = SYS_DEVICE_EVENT
event->from    = PAIPOP_DEVICE_EVENT_FROM_APP（0x80）
event->payload = struct device_event {
    event = PAIPOP_EVT_SHAKE,
    value = 0,
    arg   = NULL
}
```

事件回到应用后，还要用来源值 `0x80` 防止把 USB、SD、充电等其他设备事件误当成 Paipop 业务消息：

```c
if (event->from != PAIPOP_DEVICE_EVENT_FROM_APP) {
    return false;
}

return paipop_fsm_dispatch(
    (enum paipop_toy_event)dev->event, dev->value) == 0;
```

源码位置：`src/app/paipop_events.c:256-279`。因此两道判断仍然分开：摇一摇服务确认“是不是有效运动”，FSM 再判断“当前状态是否接受这次业务打断请求”。

## 六、两条链在事件层汇合，但三种机制仍要分开

按键、摇一摇和语音 SDK 的来源不同，最终都可以被翻译成玩具业务事件：

```text
按键驱动 ─→ SYS_KEY_EVENT ──────────────────┐
                                             │
摇一摇服务 → 业务回调 → SYS_DEVICE_EVENT ────┼→ paipop_events
                                             │      ↓
PaipopSDK 生命周期回调 → SYS_DEVICE_EVENT ───┘  PAIPOP_EVT_*
                                                     ↓
                                                    FSM
```

把刚才两种投递逐项并排，就能看出它们“信封相同、信纸不同”：

| 对比项 | K1/K2 按键 | 摇一摇 |
|---|---|---|
| 谁确认物理输入 | 杰理按键驱动扫描、消抖和动作识别 | Paipop 摇一摇服务：ISR 留 pending，20 ms 回调检查 STK8321 和冷却 |
| 投递前的局部数据 | `struct key_event e` | `struct device_event dev` |
| 谁进入系统事件接口 | 杰理 `key_event_notify()` 在库内转入 `sys_event_notify()` | 项目的 `paipop_events_post()` 直接调用 `sys_event_notify()` |
| 外层 `sys_event.type` | `SYS_KEY_EVENT` | `SYS_DEVICE_EVENT` |
| 外层 `sys_event.from` | `KEY_EVENT_FROM_KEY` | `PAIPOP_DEVICE_EVENT_FROM_APP`（`0x80`） |
| `payload` 的解释类型 | `struct key_event` | `struct device_event` |
| 应用内分支 | `paipop_events_handle_key()` | `paipop_events_handle_device()` |
| 业务事件何时形成 | 接收后把 `KEY_EVENT_CLICK` 翻译为 `PAIPOP_EVT_TOUCH_CLICK` | 投递前已经写入 `PAIPOP_EVT_SHAKE` |
| 最终汇合点 | `paipop_fsm_dispatch()` | `paipop_fsm_dispatch()` |

投递成功后，两条链都会进入同一个 `paipop_toy_event_handler()`。这不是因为 `event` 指向相同类型的原始对象，而是因为杰理事件框架把不同 payload 都包进了统一的 `struct sys_event`。总入口只负责看 `type` 分流，具体处理函数再按对应结构解释 `payload`。

“投递成功后”这个限定不能省略。当前 `sdk.elf` 可确认 `sys_event_notify()` 在事件缓冲区未初始化或空间不足时会返回 `-ENOMEM`；但按键驱动忽略了 `key_event_notify()` 的返回值，`paipop_events_shake_cb()` 也忽略了 `paipop_events_post()` 的返回值，所以极端情况下本次业务事件会丢失。摇一摇路径在调用业务回调之前已经更新 `last_shake_ms`，因此即使投递失败，600 ms 冷却仍会开始计算。正常运行时这通常不是主线问题，但它说明“发现输入”不等于“应用一定收到事件”。

这里很容易把三种带有“注册”或“回调”字样的机制混为一谈：

| 机制 | 解决的问题 | 当前项目例子 |
|---|---|---|
| 设备操作表 | 调用 `dev_open/read/write/ioctl` 时应该转到哪个驱动 | `iic0 → iic_dev_ops`、`spi1 → spi_dev_ops` |
| 普通回调 | 某个模块以后应该直接调用哪个函数 | GPIO ISR、20 ms 定时回调、`shake.callback` |
| 系统事件 | 消息怎样带着类型和来源，交给当前应用统一分类 | `SYS_KEY_EVENT`、`SYS_NET_EVENT`、`SYS_DEVICE_EVENT` |

`REGISTER_DEVICES` 把设备名字、操作表和硬件参数放入 `.device` 注册区。之后是项目主动调用 `dev_open("iic0")` 或 `dev_write(spi_handle, ...)`，设备框架按句柄转到相应操作函数；I²C 或 SPI 完成一次读写并不会自动生成 `SYS_DEVICE_EVENT`。具体设备表和 `dev_*` 用法见系列（一）。

所以名字相似不代表机制相同：

```text
.device / REGISTER_DEVICES：驱动查找表
SYS_DEVICE_EVENT：系统事件的一种信封类型
```

回调与事件框架在概念上也能独立存在。`shake.callback()` 完全可以直接做业务；项目选择在回调中发布事件，是为了让摇一摇、按键、网络和 SDK 生命周期变化最终在同一个业务入口中按状态串行决策。反过来，事件框架最后仍需通过应用注册的 `.event_handler` 回调把事件交付出去。

## 七、FSM 才决定是否打断对话

`paipop_events` 解决的是“发生了什么”，`paipop_fsm` 解决的是“当前应该怎么办”。其核心可以写成公式：

```text
当前玩具状态 + Paipop 业务事件 = 业务动作与目标状态
```

### 1. 同一个输入在不同状态下含义不同

`PAIPOP_EVT_TOUCH_CLICK` 并不总是打断对话：

- 引擎仍在初始化时，记录“初始化完成后开始”；
- 初始化失败时，重新尝试初始化；
- 已在 `ENGINE_EXIT` 时，开始或排队下一轮；
- 只有正在 `ENGINE_CHAT` 时，才请求退出当前轮次。

聊天状态下，按键和摇一摇才会走到 SDK 退出请求：

```c
case PAIPOP_EVT_TOUCH_CLICK:
    if (state == PAIPOP_TOY_STATE_ENGINE_CHAT &&
        paipop_fsm_mark_exit_requested()) {
        paipop_fsm_start_exit_request_timer();
        ret = paipop_engine_interrupt_chat("touch restart");
    }
    return 0;

case PAIPOP_EVT_SHAKE:
    if (state == PAIPOP_TOY_STATE_ENGINE_CHAT &&
        paipop_fsm_try_begin_shake_interrupt()) {
        paipop_fsm_mark_shake_restart_requested();
        ret = paipop_engine_interrupt_chat("shake interrupt");
    }
    return 0;
```

上面为了突出共同结构省略了失败恢复、提示音和日志，完整代码位于 `src/app/paipop_fsm.c:874-936`。从源码可以确认：按键用 `exit_request_pending` 避免重复请求；摇一摇先在 `paipop_fsm_try_begin_shake_interrupt()` 中持有 FSM mutex，把 `fsm.shake_interrupt_pending` 从 0 置 1，再调用 SDK。若 SDK 同步返回负值，代码会恢复相应标志；未被同步拒绝时，按键和摇一摇分别启用自己的超时保护。超时长度和恢复策略是当前项目规则，不能反推为杰理或灵芯框架的通用要求。

还有一个重要时序：调用 `paipop_engine_interrupt_chat()` 后，代码并没有立即执行玩具状态转换，所以 **FSM 仍是 `ENGINE_CHAT`**。与此同时，PaipopSDK 自己的阶段可以推进到 `INTERRUPTING` 或 `EXITING`。只有后续收到 SDK 的 `EXIT` 生命周期事件，玩具 FSM 才会进入 `ENGINE_EXIT`。

### 2. 请求退出和退出完成是两个时刻

FSM 最终通过项目封装调用 `Paipop_ExitChat()`：

```c
int paipop_engine_interrupt_chat(const char *reason)
{
    return paipop_engine_exit_chat_mode(reason, 1);
}

/* paipop_engine_exit_chat_mode() 内 */
Paipop_GetExitChatDefaultProps(&props);
props.disableCloseWebsocketImmediately = false;
ret = Paipop_ExitChat(&props);
```

源码位置：`src/services/paipop_engine_service.c:529-557`。

`PaipopSDK/paipop_sdk.h:199-202` 只承诺两件事：该接口用于**请求退出**，完成结果通过生命周期回调通知。项目调用点把 `ret < 0` 当作请求被同步拒绝并执行恢复，因此在这层代码里，非负返回值最多只能解释为“没有被同步拒绝”，不能解释成退出已经完成，也不能说明录音、播放器或网络资源已经释放。

初始化对话 SDK 时，项目注册了生命周期监听：

```c
Paipop_GetVoiceChatInitDefaultProps(&props);
props.lifeCycleListener = paipop_engine_lifecycle_event;
ret = Paipop_VoiceChatInit(&props);
```

当 SDK 后续通过生命周期监听报告 `EXIT` 时，回调再发布业务事件：

```c
case PAIPOP_CHAT_LIFE_CYCLE_EVENT_EXIT: {
    Paipop_ExitPayload *ep = (Paipop_ExitPayload *)payload;
    int exit_code = ep ? ep->code : -1;

    /* 省略异常退出附加事件 */
    paipop_events_post(PAIPOP_EVT_ENGINE_EXIT, exit_code);
    break;
}
```

源码位置：`src/services/paipop_engine_service.c:411-448,482-504`。

这个事件经过同一条 `SYS_DEVICE_EVENT` 路径回到 FSM：

```c
case PAIPOP_EVT_ENGINE_EXIT:
    if (state == PAIPOP_TOY_STATE_ENGINE_CHAT) {
        paipop_fsm_prepare_managed_continue(value);
        return paipop_fsm_transition(
            PAIPOP_TOY_STATE_ENGINE_EXIT,
            PAIPOP_EVT_ENGINE_EXIT);
    }
    return 0;
```

### 3. `ENGINE_EXIT` 之后怎样开始下一轮

`PAIPOP_EVT_ENGINE_EXIT` 不是立刻恢复录音。后续顺序由 `paipop_fsm.c` 明确规定：

1. FSM 从 `ENGINE_CHAT` 转入 `ENGINE_EXIT`。进入该状态时会取消退出请求定时器、清除互斥锁保护的 `fsm.shake_interrupt_pending`，把眼睛设为 `IDLE`，按键路径如有需要先播放打断提示音，然后启动 **1.2 秒退出保护定时器**。
2. 保护到期后，`paipop_fsm_exit_guard_timeout()` 设置 `exit_restart_ready`；只有 `restart_after_exit` 仍为真时，才发布 `PAIPOP_EVT_ENGINE_RESTART`。
3. FSM 仅在仍处于 `ENGINE_EXIT` 且 `exit_restart_ready` 为真时调用 `paipop_fsm_restart_chat()`；过期或不满足条件的重启事件会被忽略。
4. 若本地提示音仍在播放，重启函数不会抢占它，而是每 **200 ms** 再检查一次。若 OTA 已经开始，则清除重启标志并取消这次续聊；WebSocket 失败等路径也可以撤销待重启状态。
5. 按键和摇一摇的显式打断都会把 `continue_same_conversation` 置一，因此最终调用 `paipop_engine_continue_chat_round()`。该函数保留原 `conversation_id`、生成新的 `turn_id`、关闭欢迎音并启动一个新的单轮任务；它不是恢复旧音频，也不是创建一段全新 conversation。
6. 新一轮请求没有被同步拒绝后，FSM 才从 `ENGINE_EXIT` 转回 `ENGINE_CHAT`，眼睛回到 `LISTENING`。

重启函数中最能体现顺序的代码是：

```c
if (paipop_tone_is_playing()) {
    sys_timeout_add_to_task("app_core", NULL,
                            paipop_fsm_exit_guard_timeout,
                            PAIPOP_ENGINE_TONE_RECHECK_MS); /* 200 ms */
    return 0;
}

if (paipop_ota_is_busy()) {
    paipop_fsm_clear_restart();
    return 0;
}

ret = continue_same_conversation ?
      paipop_engine_continue_chat_round() :
      paipop_engine_start_new_chat(0);
if (ret < 0) {
    return 0;
}
return paipop_fsm_transition(PAIPOP_TOY_STATE_ENGINE_CHAT,
                             PAIPOP_EVT_ENGINE_RESTART);
```

这是从 `paipop_fsm_restart_chat()` 摘出的控制骨架，省略了锁内取值、日志和定时器句柄保存；分支和调用顺序与 `src/app/paipop_fsm.c:589-649` 一致。

对应证据位于 `src/app/paipop_fsm.c:13-17,216-266,399-410,523-650,673-734,937-970` 与 `src/services/paipop_engine_service.c:247-292,515-526`。闭环可以压缩为：

```text
点击/摇动
  → FSM 请求 Paipop_ExitChat
  → 玩具 FSM 暂时仍为 ENGINE_CHAT
  ⇢ PaipopSDK/灵芯异步处理退出请求，可处于 INTERRUPTING/EXITING
  ⇢ 生命周期回调 EXIT
  → PAIPOP_EVT_ENGINE_EXIT
  ⇢ 系统事件回到 app_core
  → FSM：ENGINE_CHAT → ENGINE_EXIT
  → 1.2s 保护；提示音未完则每 200ms 复查
  → PAIPOP_EVT_ENGINE_RESTART
  → continue_chat_round：同一 conversation 的新 turn
  → FSM：ENGINE_EXIT → ENGINE_CHAT
```

对灵芯库内部具体以何种线程、顺序释放资源，当前源码没有足够证据；本文只追踪到 PaipopSDK 公共接口与项目注册的生命周期回调边界。

## 八、项目里有四层状态，但只有一层是玩具 FSM

这些状态经常同时出现在日志中，但回答的是不同问题：

| 层级 | 代表状态 | 管理者 | 回答的问题 |
|---|---|---|---|
| 杰理应用生命周期 | `APP_STA_START/STOP/DESTROY` | `app_core` | 整个应用是否正在运行 |
| Paipop 玩具业务状态 | `VM_CONFIG/AP_CONFIG/ENGINE_INIT/ENGINE_CHAT/ENGINE_EXIT` | `paipop_fsm` | 产品正在配网、初始化还是对话 |
| PaipopSDK 对话阶段 | `INPUTING/THINKING/OUTPUTING/INTERRUPTING/EXITING` | PaipopSDK/灵芯 | 当前一轮语音进行到哪一步 |
| 眼睛表现状态 | `CLOSED/IDLE/LISTENING/SPEAKING` | 眼睛服务 | 屏幕此刻应该怎样呈现 |

它们是嵌套和映射关系，而不是一个由 `app_core` 统一轮转的大状态机：

```text
APP_STA_START                         杰理应用仍在运行
  └─ PAIPOP_TOY_STATE_ENGINE_CHAT    玩具处于对话模式
       ├─ INPUTING                    SDK 采集/上传用户语音
       │    └─ LISTENING              眼睛显示倾听
       ├─ THINKING                    云端处理
       └─ OUTPUTING                   SDK 播放 AI/TTS 回答
            └─ SPEAKING               眼睛显示说话
```

`app_core` 只直接理解第一层。项目自己的 `paipop_fsm_dispatch()` 读取第二层状态并决定业务；PaipopSDK 推进第三层，并通过生命周期回调告知项目；眼睛服务根据业务或 SDK 阶段更新第四层表现。

这也解释了为什么看起来会有“很多状态机”：每层只管理自己的边界。如果把配网、应用启停、云端语音协议和眼睛动画全部塞进一个枚举，任意一个小变化都会牵动所有模块。

## 九、不是所有改变都要经过 `sys_event`

事件框架很重要，但它不是项目中唯一的数据和控制通道。

### 1. FSM 自身可以直接更新状态

初始化时直接设定初始状态：

```c
memset(&fsm, 0, sizeof(fsm));
fsm.state = PAIPOP_TOY_STATE_VM_CONFIG;
fsm.pending_after_tone = PAIPOP_TOY_STATE_NONE;
```

合法转换也在互斥锁内直接修改：

```c
paipop_fsm_lock();
current = fsm.state;
allowed = paipop_fsm_transition_allowed(current, target, reason);
if (allowed) {
    fsm.state = target;
}
paipop_fsm_unlock();
```

源码位置：`src/app/paipop_fsm.c:117-153,741-758`。

这里虽然会使用“事件”作为转换原因，但并不要求再构造一封杰理 `struct sys_event`。

### 2. 眼睛任务使用共享状态和版本号

眼睛行为变化不会发布 `sys_event`：`paipop_eye_set_behavior()` 在 mutex 下更新 `eye_hdl.behavior` 并执行 `generation++`，动画任务再读取最新快照。它只关心最新表现，不必为每次表情变化排一条系统事件。源码位置：`src/services/paipop_eye_service.c:800-815`。

### 3. 设备数据和 PCM 不适合逐帧包装成系统事件

I²C/SPI 的读写由 `dev_ioctl()`、`dev_read()`、`dev_write()` 直接返回；PCM 是连续、高频、数据量较大的音频流，通常通过缓冲区、生产者/消费者接口或专用回调传递。如果把每几个字节都包装成 `sys_event`，会增加复制、排队和调度开销，还可能堵塞低频控制消息。

可以用下面的选择原则：

| 场景 | 更适合的机制 |
|---|---|
| 明确的一对一通知、硬件中断或定时到期 | 回调 |
| 跨模块、低频、需要统一分类或切到 `app_core` 决策 | 系统事件 |
| 模块内部立即调用并取得结果 | 普通函数调用 |
| 只关心最新状态 | 加锁共享状态/版本号 |
| PCM、图像等高频连续数据 | 缓冲区、队列或流式接口 |

因此更准确的结论不是“所有改变最终都由事件实现”，而是：

> 项目把重要的、低频的、跨模块控制变化统一成业务事件；模块内部状态、高频数据和同步设备操作仍使用更合适的通道。

## 十、几个容易混淆的问题

### Q1：回调和事件框架是独立的吗？

概念上独立。回调解决“以后调用谁”，事件框架解决“消息怎样封装、排队、路由和分类”。回调不一定使用事件框架；事件框架最终通常又通过已注册的回调把事件交给接收者。当前摇一摇正是“硬件回调 → 定时回调 → 业务回调 → 系统事件 → 应用事件回调”的组合。

### Q2：`REGISTER_DEVICES` 和 `SYS_DEVICE_EVENT` 是同一套机制吗？

不是。前者建立设备名字到 `device_operations` 的静态查找表，供 `dev_open/read/write/ioctl` 使用；后者只是一种系统事件类型。名字里都有 `device`，但一个用于主动操作驱动，一个用于传递消息。

### Q3：为什么不把 `paipop_events_handle_key()` 直接注册给 `app_core`？

应用入口签名是 `(application *, sys_event *)`，按键处理函数却只接收 `key_event *`，并且是 `paipop_events.c` 内部的 `static` 函数。统一入口还要面对网络、设备等事件，必须先检查 `event->type` 决定 payload 类型；若事件生产者不完全可信，还应同时校验 `event->len`。

### Q4：I²C、SPI 完成读写后会自动进入 `paipop_toy_event_handler()` 吗？

不会。`REGISTER_DEVICES` 本身只建立设备查找表，不发布系统事件；当前可见的 STK8321/LCD `dev_ioctl()`、`dev_write()` 调用也没有自动发布事件。按键是另一条路径，`key_event_notify()` 会在杰理库内部继续进入事件机制，所以不能把“业务代码直接调用 `sys_event_notify()`”当作唯一入口。

### Q5：`app_default_event_handler()` 与业务 FSM 有什么关系？

没有直接的状态转换关系。它是活动应用没有消费某个系统事件时的后备处理器。当前 Paipop 实现对五种已知类型不做业务处理，只对未知类型断言。

### Q6：`app_core` 串行后还需要互斥锁吗？

要看数据是否只由 `app_core` 访问。眼睛任务、SDK 任务和硬件中断仍可与它并发；普通互斥锁也不能在 ISR 中阻塞使用。当前硬件 pending 是布尔标志，多个边沿可能合并；若要求逐个保留，应使用临界区、原子交换或 ISR 安全队列。

## 十一、用一分钟给别人讲清楚

可以这样概括整个项目的控制链：

> 杰理启动 `paipop_toy` 后，按键驱动扫描、消抖，把局部 `key_event e` 的内容装入 `SYS_KEY_EVENT`；摇一摇先由 PA5/PA6 ISR 留下硬件 pending，再由 `app_core` 中的 20 ms 回调确认 `ANY_MOTION` 和冷却时间，把局部 `device_event dev` 的内容装入自定义 `SYS_DEVICE_EVENT`。投递成功时，应用回调收到的不是原来的 `&e` 或 `&dev`，而是统一的 `sys_event` 信封；`paipop_events` 根据 `type` 把 `payload` 解释成对应结构，再翻译为 `PAIPOP_EVT_TOUCH_CLICK` 或 `PAIPOP_EVT_SHAKE`。只有玩具 FSM 处于 `ENGINE_CHAT` 时，两种输入才会请求 `Paipop_ExitChat`；请求未被同步拒绝后，玩具状态仍暂时保持 `ENGINE_CHAT`，直到 PaipopSDK 用生命周期回调报告 `EXIT`。随后 FSM 进入 `ENGINE_EXIT`，经过 1.2 秒保护并等待本地提示音，OTA 未阻止重启时，再用 `continue_chat_round` 在同一 conversation 中开始新的 turn。FSM 负责决策，PaipopSDK 负责执行；I²C/SPI、PCM 和眼睛共享状态并不会全部走系统事件。

## 十二、源码证据索引

| 主题 | 证据位置 | 性质与限制 |
|---|---|---|
| `app_core` 初始化与消息循环 | 杰理 SDK `apps/common/system/init.c:180-232` | 可验证的公共源码；证明任务循环，不展开库内路由分支 |
| 应用状态和操作表签名 | 杰理 SDK `include_lib/system/app_core.h:16-39` | 可验证的接口契约 |
| `app_core` 库内实现 | `cpu/wl82/liba/system.a(app_core.c.o)`、`sdk.map` | 符号/链接强证据，不是完整源码 |
| 系统事件类型与信封结构 | 杰理 SDK `include_lib/utils/event/event.h:9-25,55-58` | 可验证的接口契约 |
| 按键与设备 payload 结构 | 杰理 SDK `include_lib/utils/event/key_event.h:75-97`；`include_lib/utils/event/device_event.h:40-46` | 可验证的结构和通知接口声明；不等于库内队列实现源码 |
| 按键与通用事件库实现 | `cpu/wl82/liba/event.a(key_event.c.o,event.c.o)`、最终 `sdk.elf` 中 `key_event_notify: 0x02003806-0x0200381c`、`sys_event_notify: 0x02003774-0x02003804` | 当前构建的符号/反汇编证据；确认按键参数、浅拷贝和 `-ENOMEM` 路径，仍不是普通 C 源码 |
| 默认处理器语义 | 杰理 SDK `apps/common/example/system/event/main.c:32-57` | 官方示例；只确认应用消费与默认后备关系 |
| Paipop 生命周期与事件入口 | `apps/Paipop_YP_Toy/app_main.c:80-161` | 可验证的项目注册和回调定义 |
| K1/K2 配置与驱动通知 | `board/wl82/paipop_v1_1_board.c:105-123,209-215`；SDK `apps/common/key/key_driver.c:60-190` | 可验证局部 `e`、扫描和 `key_event_notify()` 调用点；后续进入事件库边界 |
| 系统事件分类与业务发布 | `src/app/paipop_events.c:136-299` | 可验证的项目直接调用与类型转换 |
| 摇一摇回调交接 | `src/services/paipop_shake.c:31-39,79-187` | 注册和项目逻辑已验证；硬件触发未运行观测 |
| 设备操作表与 `.device` | SDK `include_lib/driver/device/device.h:14-43`；`board/wl82/paipop_v1_1_board.c:181-190` | 可验证的注册关系，不代表自动发布事件 |
| 玩具 FSM 与两种 pending | `include/paipop_toy.h:8-38`；`src/app/paipop_fsm.c:19-38,477-507,874-970` | 可验证的状态、互斥和业务决策 |
| 退出保护与同会话新 turn | `src/app/paipop_fsm.c:13-17,216-266,523-650`；`src/services/paipop_engine_service.c:247-292,515-526` | 可验证的项目时序；未观测云端运行 |
| SDK 生命周期回调注册 | `src/services/paipop_engine_service.c:411-504` | 项目回调和事件转换已验证；SDK 调用时机是外部边界 |
| PaipopSDK 阶段与退出契约 | `PaipopSDK/paipop_sdk.h:66-75,199-202` | 可验证的封装层契约；灵芯内部实现不可见 |
| 眼睛共享状态 | `src/services/paipop_eye_service.c:800-815` | 可验证的直接更新，不经过 `sys_event` |

## 总结

按键和摇一摇展示了两种典型输入路径：按键驱动已经能直接生成系统事件；摇一摇则需要项目用硬件回调和定时回调先把原始中断确认成产品语义，再主动发布事件。投递成功后，二者进入 `paipop_events`，被统一翻译为玩具业务事件，最后由 FSM 结合当前状态决策。

理解这条链以后，可以用同一套方法继续追踪网络断开、OTA、音量云端指令和 SDK 生命周期变化：先找“谁发现”，再找“通过回调还是事件通知”，然后看 `paipop_events` 怎样翻译，最后看 FSM 在当前状态下做了什么。这样读项目时就不会把所有异步变化都误认为一条从 `app_main()` 顺序执行到底的普通函数调用。
