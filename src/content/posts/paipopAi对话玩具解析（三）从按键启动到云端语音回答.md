---
title: paipopAi对话玩具解析（三）：从按键启动到云端语音回答
published: 2026-09-07
updated: 2026-09-07
pinned: false
description: 沿着一次普通点击启动的真实链路，讲清玩具 FSM、PaipopSDK、LingXinSDK、24 kHz PCM 上传、对话阶段回调、流式 MP3 缓冲与杰理 audio_server 怎样协作完成一轮连续语音对话。
tags: [AC791N, Paipop, 嵌入式, 语音对话, 音频流, 状态机]
category: 嵌入式
series: Paipop AI 对话玩具源码解析
seriesOrder: 4
draft: false
---

# paipopAi对话玩具解析（三）：从按键启动到云端语音回答

前一篇已经追踪了按键和摇一摇怎样进入杰理 `sys_event`，再由 `paipop_events` 翻译为玩具业务事件，最终交给 `paipop_fsm` 决定启动、排队还是打断对话。但那篇主要关注控制路径，链路停在“FSM 要求 Paipop 引擎执行”附近。

这篇继续回答控制命令之后的问题：**用户单击按键以后，麦克风 PCM 到底怎样进入云端，ASR 和 AI 文本怎样返回，流式回答又怎样经过缓冲、MP3 解码和 DAC 变成扬声器里的声音？**

先用一句话概括全文：

> 按键只产生启动意图，玩具 FSM 决定何时接受；PaipopSDK 把第一方业务接口转换成 LingXinSDK 能执行的对话请求；LingXinSDK 负责第三方云端会话，杰理音频适配层负责把 24 kHz PCM 交给它、再把流式 MP3 送入 `audio_server` 和 DAC；异步阶段最后通过系统事件回到 `app_core`，由 FSM 串行驱动眼睛和业务状态。

## 阅读导航

1. [杰理 AC79 应用启动与注册机制详解：从 `REGISTER_APPLICATION` 到 `start_app`](/posts/杰理ac79应用启动与注册机制详解/)
2. [paipopAi 对话玩具解析（一）：从 `APP_STA_START` 到眼睛任务与摇一摇服务](/posts/paipopai对话玩具解析一从应用启动到眼睛与摇一摇/)
3. [paipopAi 对话玩具解析（二）：从按键与摇一摇到对话打断](/posts/paipopai对话玩具解析二从按键与摇一摇到对话打断/)
4. **本文**：从普通点击启动一轮对话，追踪 PCM 上传、云端阶段和回答播放。

## 本文范围与证据边界

本文基于独立发布仓库 `Paipop_YP_Toy_release_v128` 的 `main@24a83f9`，对应正式版 `V1.2.8 / 10208`。目标是 AC791N/WL82 正常产品配置，`CONFIG_PAIPOP_VOICE_CHAIN_ONLY` 默认关闭，录音配置为 24 kHz、单声道。本文采用静态源码分析，没有重新编译、烧录或运行设备。

分析范围只覆盖一次普通单击启动的 Cloud VAD 连续对话。长按说话、摇一摇、自然语音抢话、OTA 和配网只在与主链相交时说明，不展开各自分支。

代码归属需要特别分清：

| 层次 | 归属 | 本文怎样处理 |
|---|---|---|
| 玩具事件、FSM、`paipop_engine_service` | Paipop 第一方项目代码 | 追到具体函数、状态和失败分支 |
| PaipopSDK 接口与封装 | Paipop 第一方封装 | 解释公开契约、参数转换和音频桥接 |
| LingXinSDK | 第三方 AI 对话引擎 | 说明本项目依赖的接口行为，不把内部实现当成第一方成果 |
| `app_core`、`sys_event`、`audio_server`、ADC/DAC | 杰理 SDK 与硬件 | 追到平台 API 边界，不虚构预编译库内部源码 |

V1.2.8 发布仓只交付 `libpaipop_sdk.a`、公开头文件和杰理音频端口源码，没有包含 PaipopSDK 核心 `.c`。发布仓中的静态库与 `apps/LINGXIN_JIELI/PAIPOP_JIELI_SDK/release/libpaipop_sdk.a` 的 SHA-256 一致；因此本文用公开头文件确认接口契约，并用对应开发目录源码补充说明 PaipopSDK 怎样桥接 LingXinSDK。涉及第三方引擎内部网络状态机的地方会明确停在边界。

## 一、先分清两套状态：玩具状态不等于对话阶段

这条链路里最容易混淆的不是某个 API，而是两套同时存在的状态。

### 1. 玩具 FSM 管产品处于什么大状态

`paipop_fsm` 管理配网、引擎初始化、聊天和退出等待等产品级状态。本文主线涉及：

```text
ENGINE_INIT
    ↓ 初始化成功
ENGINE_EXIT
    ↓ 用户点击并成功提交启动请求
ENGINE_CHAT
    ↓ 对话真正退出
ENGINE_EXIT
```

`ENGINE_EXIT` 这个名字容易误导。它不是“初始化失败”，而是引擎已经离开活动聊天、可以等待下一次启动的稳定状态。FSM 的合法转换表明确允许：

```text
ENGINE_INIT --ENGINE_INIT_OK--> ENGINE_EXIT
ENGINE_EXIT --TOUCH_CLICK/ENGINE_RESTART--> ENGINE_CHAT
ENGINE_CHAT --ENGINE_EXIT--> ENGINE_EXIT
```

源码位置：`src/app/paipop_fsm.c:100-140`。

### 2. SDK 阶段管一轮交互进行到哪里

PaipopSDK 的 `Paipop_ChatPhaseCode` 描述的是对话内部阶段：

```c
typedef enum {
    PAIPOP_CHAT_PHASE_STANDBY = 0,
    PAIPOP_CHAT_PHASE_STARTING,
    PAIPOP_CHAT_PHASE_INPUTING,
    PAIPOP_CHAT_PHASE_THINKING,
    PAIPOP_CHAT_PHASE_OUTPUTING,
    PAIPOP_CHAT_PHASE_INTERRUPTING,
    PAIPOP_CHAT_PHASE_EXITING,
} Paipop_ChatPhaseCode;
```

正常连续对话主要经历：

```text
STARTING → INPUTING → THINKING → OUTPUTING
                ↑                         │
                └──── 回答结束，下一轮 ───┘
```

源码位置：`PaipopSDK/paipop_sdk.h:68-83`。

所以一次 `ENGINE_CHAT` 可以包含多次 `INPUTING → THINKING → OUTPUTING`。前者是产品粗粒度状态，后者是会话细粒度阶段。把两者混成一个枚举，会让 UI、打断和异常退出逻辑互相缠绕。

> **知识卡：为什么状态名前有 `ENGINE_`，阶段名前有 `CHAT_PHASE_`？**
>
> 这是两个抽象层的提示。`ENGINE_CHAT` 回答“玩具是否正处于一段活动会话”；`CHAT_PHASE_INPUTING` 回答“这段会话当前是否正在收取用户输入”。前者由玩具 FSM 持有，后者由 Paipop/LingXin 生命周期回调报告。

## 二、一张图看完正常对话主链

下面的 `→` 表示源码中的直接调用，`⇢` 表示回调、系统事件、任务切换或第三方引擎的异步推进，不应理解成同一个 C 调用栈。

```text
用户单击 K1/K2
  ⇢ 杰理按键事件
  → paipop_toy_event_handler()
  → paipop_events_handle_sys_event()
  → paipop_events_handle_key()
  → paipop_fsm_dispatch(PAIPOP_EVT_TOUCH_CLICK)
  → paipop_fsm_restart_chat()
  → paipop_engine_start_new_chat(0)
  → paipop_engine_start_managed_round(...)
  → Paipop_StartNewChat()
  → PaipopSDK 转换参数
  → LingXinSDK start_new_chat()                 第三方边界
       │
       ├⇢ STARTING
       ├⇢ INPUTING
       │   ⇢ 打开录音端口
       │   ⇢ 24 kHz/单声道/16 bit PCM
       │   → PaipopSDK 音频桥接
       │   → LingXinSDK/WebSocket 上传
       │
       ├⇢ ASR_TEXT
       ├⇢ THINKING
       ├⇢ AI_TEXT
       ├⇢ OUTPUTING
       │   ⇢ 流式 MP3
       │   → paipop_cloud_audio_play_feed()
       │   → 首播缓存 4 KiB 或 8 KiB
       │   → audio_server MP3 解码
       │   → DAC/扬声器
       │   ⇢ PLAYBACK_STARTED → 眼睛 SPEAKING
       │
       └⇢ 播放结束
           ⇢ 下一轮 INPUTING，或退出会话
```

这张图里同时存在四种信息通道：

| 信息 | 通道 | 原因 |
|---|---|---|
| 点击、阶段变化、退出 | `sys_event`/业务事件 | 低频控制消息，需要在 `app_core` 串行决策 |
| 录音 PCM | 回调与缓冲区 | 高频连续数据，不适合逐帧包装成系统事件 |
| 云端 MP3 | 流式 feed 与循环缓冲区 | 生产速度和解码消费速度不同 |
| 眼睛状态 | 加锁共享状态 | 动画任务只关心最新行为，不要求保留每个历史命令 |

## 三、点击不会直接调用 SDK，而是先进入 FSM

当前应用把统一系统事件入口注册为 `paipop_toy_event_handler()`：

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

`paipop_events_handle_sys_event()` 根据 `event->type` 区分按键、网络和设备事件；`SYS_KEY_EVENT` 才进入 `paipop_events_handle_key()`。源码位置：`app_main.c:158-164`、`src/app/paipop_events.c:549-566`。

按键函数先处理产品约束：

1. 只接收 K1/K2；
2. OTA 期间消费但不执行交互；
3. 消除组合键释放后产生的两次点击；
4. 麦克风回环正在播放时，本次点击只负责停止回环；
5. PTT 状态存在时，先恢复自然交互；
6. 最后才把物理点击翻译成 `PAIPOP_EVT_TOUCH_CLICK`。

主线最终只有一句：

```c
return paipop_fsm_dispatch(PAIPOP_EVT_TOUCH_CLICK,
                           key->value) == 0;
```

源码位置：`src/app/paipop_events.c:347-460`。

为什么不在这里直接调用 `Paipop_StartNewChat()`？因为同一个点击在不同状态下意义不同：

| 当前状态 | 点击的业务含义 |
|---|---|
| `ENGINE_INIT` | 先记住启动意图，初始化完成后再开始 |
| `ENGINE_INIT_FAILED` | 重试初始化，并保留“成功后立即开始”意图 |
| `ENGINE_EXIT` | 启动一段新会话 |
| `ENGINE_CHAT` | 请求中断或切换当前活动轮次 |

按键层只负责报告“用户点击”，FSM 才负责结合当前状态解释这个事实。这让硬件输入与业务策略保持解耦。

## 四、初始化期间的点击怎样做到既不丢失，也不重复启动

收到 `PAIPOP_EVT_TOUCH_CLICK` 后，FSM 首先调用 `paipop_fsm_latch_start_after_init()`：

```c
static unsigned char paipop_fsm_latch_start_after_init(
    enum paipop_toy_state current)
{
    unsigned char waiting_for_init;

    paipop_fsm_lock();
    waiting_for_init = current == PAIPOP_TOY_STATE_ENGINE_INIT ||
                       fsm.pending_after_tone ==
                           PAIPOP_TOY_STATE_ENGINE_INIT;
    if (waiting_for_init) {
        fsm.start_after_init = 1;
    }
    paipop_fsm_unlock();

    return waiting_for_init;
}
```

源码位置：`src/app/paipop_fsm.c:435-452,1663-1685`。

这个字段不是保存完整 `key_event`，也不是按键计数器，而是保存一个业务意图：

```text
用户已经要求开始对话
```

初始化成功后，FSM 进入 `ENGINE_EXIT`，调用 `paipop_fsm_take_start_after_init()` 原子地取出并清除标志，再发布 `PAIPOP_EVT_ENGINE_RESTART`：

```c
start_after_init = paipop_fsm_take_start_after_init();
if (start_after_init) {
    paipop_fsm_queue_restart();
    paipop_events_post(PAIPOP_EVT_ENGINE_RESTART, 0);
}
```

源码位置：`src/app/paipop_fsm.c:455-470,1495-1503`。

这里有三个设计结果：

- 初始化期间的点击不会被简单丢弃；
- 多次点击只会把布尔值反复设为 1，最终合并成一次启动；
- 标志的读写受 FSM mutex 保护，消费时同时清零，避免同一个意图被重复执行。

> **知识卡：锁存意图和排队事件有什么区别？**
>
> 事件队列通常保留“发生了几次”和先后顺序；锁存意图只保留“现在是否仍需要做这件事”。初始化期间连按三次，不应该在初始化完成后启动三轮对话，因此这里选择布尔锁存比事件计数更符合产品语义。

## 五、`Paipop_VoiceChatInit()` 与 `Paipop_StartNewChat()` 分工不同

这两个接口名字相近，但生命周期完全不同。

### 1. `Paipop_VoiceChatInit()` 建立长期能力

FSM 进入 `ENGINE_INIT` 时调用 `paipop_engine_chat_init()`：

```c
case PAIPOP_TOY_STATE_ENGINE_INIT:
    paipop_eye_closed();
    ret = paipop_engine_chat_init();
    if (ret >= 0) {
        paipop_fsm_transition(PAIPOP_TOY_STATE_ENGINE_EXIT,
                              PAIPOP_EVT_ENGINE_INIT_OK);
    } else {
        paipop_fsm_transition(PAIPOP_TOY_STATE_ENGINE_INIT_FAILED,
                              PAIPOP_EVT_ENGINE_INIT_FAIL);
    }
    break;
```

`paipop_engine_chat_init()` 先取得默认参数，再配置：

- 生命周期回调 `lifeCycleListener`；
- 每轮业务参数准备回调 `chatRoundPrepare`；
- business/custom JSON 获取函数；
- 欢迎提示音路径；
- WebSocket 心跳间隔 3 秒、超时 10 秒；
- Flash 缓存路径；
- 定时任务能力；
- 云端动作数量和白名单校验器。

最后调用：

```c
ret = Paipop_VoiceChatInit(&props);
```

源码位置：`src/app/paipop_fsm.c:1406-1421`、`src/services/paipop_engine_service.c:500-535`。

它通常在联网后初始化一次；如果初始化失败，点击可以触发重新初始化。因此更准确的说法是“正常启动只初始化一次，失败时允许重试”，而不是“整个设备生命周期绝对只能调用一次”。

### 2. `Paipop_StartNewChat()` 提交本次会话

当玩具处于 `ENGINE_EXIT` 且允许重启时，点击路径进入 `paipop_fsm_restart_chat()`。它先检查：

- 是否真的存在 `restart_after_exit` 意图；
- 本地提示音是否仍在播放；
- OTA 是否正在占用系统；
- 本次是新 conversation，还是同一 conversation 的继续轮次。

普通点击最终调用：

```c
ret = paipop_engine_start_new_chat(0);
```

它进一步构造参数并调用：

```c
ret = Paipop_StartNewChat(&props);
```

只有返回值非负，FSM 才把玩具状态从 `ENGINE_EXIT` 切换到 `ENGINE_CHAT`。源码位置：`src/app/paipop_fsm.c:1285-1375`、`src/services/paipop_engine_service.c:258-295,538-546`。

两者可以用下表记忆：

| 接口 | 生命周期 | 主要工作 | 成功意味着什么 |
|---|---|---|---|
| `Paipop_VoiceChatInit()` | 正常情况下联网后一次 | 认证、回调、公共参数、网络与音频能力初始化 | 对话模块可接受后续请求 |
| `Paipop_StartNewChat()` | 新会话或受控重启时调用 | 本次模式、上下文、欢迎音和连续策略 | 启动请求已被接受，不等于已经开始录音 |

公开返回码还区分 `NOT_READY` 和 `BUSY`。因此 `Paipop_StartNewChat()` 返回 0 不能被解释为“WebSocket 已连接”或“麦克风已经上传”；真正进入录音阶段必须等待异步 `INPUTING`。

## 六、`chatMode` 与 `singleRound` 是两个正交维度

普通点击通过 `paipop_engine_start_new_chat(0)` 使用：

```c
new_conversation    = 1;
disable_welcome     = 0;
chat_mode           = PAIPOP_CHAT_MODE_CLOUD_VAD;
single_round        = 0;
```

这两个容易混淆的参数分别回答不同问题。

### 1. `chatMode` 决定用户输入怎样结束

```text
PAIPOP_CHAT_MODE_CLOUD_VAD
    云端检测用户是否说完，不需要应用主动停止录音

PAIPOP_CHAT_MODE_MANUAL_STOP
    应用必须在松键或超时时调用 Paipop_StopChatRecord()
```

### 2. `singleRound` 决定回答之后做什么

```text
singleRound = true
    回答播放完成后退出，不自动开始下一轮录音

singleRound = false
    保持连续对话，回答结束后自动进入下一轮录音
```

公开契约位置：`PaipopSDK/paipop_sdk.h:156-187,203-228`。

组合起来看：

| 使用场景 | `chatMode` | `singleRound` |
|---|---|---|
| 自动判断说完并连续聊天 | `CLOUD_VAD` | `false` |
| 自动判断说完但只聊一轮 | `CLOUD_VAD` | `true` |
| 按住说话、松手提交、回答后退出 | `MANUAL_STOP` | `true` |
| 手动控制每轮输入但保留连续策略 | `MANUAL_STOP` | `false` |

当前普通点击属于第一行。Cloud VAD 只说明“本轮怎样判断说完”，连续对话由 `singleRound = false` 决定。

## 七、`conversation_id` 与 `turn_id` 怎样维护上下文

`paipop_engine_service.c` 保存两种 32 字节十六进制 ID：

```c
static char paipop_conversation_id[33];
static char paipop_turn_id[33];
```

它们表达两个层次：

```text
conversation_id = C100
├─ turn_id = T1：用户问“今天天气怎么样”
├─ turn_id = T2：用户问“那明天呢”
└─ turn_id = T3：用户问“需要带伞吗”
```

- `conversation_id` 标识整段连续对话，保持它才能让“那明天呢”引用上一轮上下文；
- `turn_id` 标识其中一轮，用于日志、业务 JSON 和云端请求关联。

开始新 conversation 时，`paipop_engine_start_managed_round()` 生成新的 `conversation_id`，清空上一轮参数；随后把地址填入：

```c
props.conversationId = paipop_conversation_id;
```

初始化阶段还注册了 `chatRoundPrepare = paipop_engine_round_prepare`。SDK 每次真正构造逻辑轮次的 `start_task` 前调用它；该函数生成新的 `turn_id`，再用同一个 ID 同时生成 custom JSON 与 business JSON：

```c
static int paipop_engine_prepare_chat_round(
    unsigned char new_conversation)
{
    if (new_conversation || !paipop_conversation_id[0]) {
        paipop_generate_chat_id(paipop_conversation_id);
    }

    paipop_generate_chat_id(paipop_turn_id);
    paipop_chat_custom_json[0] = '\0';
    paipop_chat_biz_json[0] = '\0';
    return paipop_build_chat_parameters();
}
```

源码位置：`src/services/paipop_engine_service.c:25-35,130-239,242-295`。

这里把“会话启动”和“每轮参数物化”分开，是因为连续模式下 SDK 可以自动开始下一轮；应用未必会再次走一次物理按键启动，却仍然必须为新 turn 生成唯一参数。

> **知识卡：为什么不只使用一个随机 ID？**
>
> 如果每轮都换同一个 ID，云端无法知道哪些轮次属于同一上下文；如果整段聊天始终只用一个 ID，又无法准确定位某轮 ASR、回答和错误。conversation/turn 两级标识同时满足上下文连续性和单轮可追踪性。

## 八、麦克风 PCM 怎样进入第三方对话引擎

### 1. 一帧为什么是 960 字节

当前录音端口固定要求：

```c
#define PAIPOP_VOICE_UPLOAD_SAMPLE_RATE 24000
#define PAIPOP_VOICE_UPLOAD_CHANNELS        1
#define PAIPOP_VOICE_UPLOAD_FRAME_BYTES   960
```

若样本为 16 bit，即每个采样点 2 字节，那么 20 ms 数据量为：

```text
24000 sample/s × 1 channel × 2 byte/sample × 0.02 s
= 960 byte
```

源码位置：`PaipopSDK/port/jl_ac79/src/paipop_audio_recorder.c:8-10`，配置位置：`include/app_config.h:171-179`。

20 ms 是延迟和调用开销之间的折中：帧更小会增加回调、入队和网络发送次数；帧更大则会提高端到端输入延迟。

### 2. 优先复用统一采集服务，避免重复打开 ADC

`paipop_audio_recorder_open()` 先检查玩具层是否提供 `paipop_voice_activity_sink_open()`。若共享采集服务可用，就校验采样率、声道数和帧长，并把 SDK 的数据回调注册成一个 PCM sink：

```c
shared_ret = paipop_voice_activity_sink_open(
    recorder_shared_sink_write,
    recorder_handler,
    recorder_handler->frame_size,
    &recorder_handler->shared_sink_generation);
```

共享服务已经拥有 ADC。若格式不匹配，代码会直接报错，而不是悄悄打开第二个 ADC；注释明确说明这是为了避免 `-14 dual-ADC race`。

只有共享服务没有链接或不可用时，才回退到：

```c
recorder_handler->enc_server =
    server_open("audio_server", "enc");
```

然后以 PCM、mic、指定采样率和帧长发送 `AUDIO_ENC_OPEN`。源码位置：`PaipopSDK/port/jl_ac79/src/paipop_audio_recorder.c:150-194,209-310`。

### 3. PCM 使用回调直达上传链，不走 `sys_event`

共享 sink 收到一帧后先检查：

- recorder 仍在运行；
- 当前确实使用共享 sink；
- generation 与注册时一致；
- 回调和数据有效。

然后调用：

```c
recorder->data_callback(data,
                        len,
                        recorder->data_user_data);
```

源码位置：`PaipopSDK/port/jl_ac79/src/paipop_audio_recorder.c:47-69`。

PaipopSDK 音频桥把平台回调转换为 LingXinSDK 的输入：

```c
static void recorder_data_callback(const void *data,
                                   int len,
                                   void *user_data)
{
    (void)user_data;
    lingxin_process_record_data((void *)data, len);
}
```

补充源码位置：`apps/LINGXIN_JIELI/PAIPOP_JIELI_SDK/src/paipop_audio_port_bridge.c:26-30,58-81`。

从 `lingxin_process_record_data()` 往下进入 LingXinSDK 的录音缓存、WebSocket 和云端协议，属于第三方边界。本文能确认本项目交给第三方引擎的是规定格式的连续 PCM；云端 ASR、模型推理和 TTS 的内部实现不属于本项目源码，也不应在面试中说成自己实现。

## 九、SDK 阶段为什么要转换成玩具事件

初始化时，应用把 `paipop_engine_lifecycle_event()` 注册给 PaipopSDK。回调收到 `CHAT_PHASE_CHANGE` 后，将公开阶段转换成玩具业务事件：

```c
if (cpp->code == PAIPOP_CHAT_PHASE_STARTING) {
    paipop_events_post(PAIPOP_EVT_ENGINE_PHASE_STARTING,
                       cpp->code);
} else if (cpp->code == PAIPOP_CHAT_PHASE_INPUTING) {
    paipop_events_post(PAIPOP_EVT_ENGINE_PHASE_INPUTING,
                       cpp->code);
} else if (cpp->code == PAIPOP_CHAT_PHASE_THINKING) {
    paipop_events_post(PAIPOP_EVT_ENGINE_PHASE_THINKING,
                       cpp->code);
} else if (cpp->code == PAIPOP_CHAT_PHASE_OUTPUTING) {
    paipop_events_post(PAIPOP_EVT_ENGINE_PHASE_OUTPUTING,
                       cpp->code);
}
```

`paipop_events_post()` 再构造 `device_event`，调用：

```c
sys_event_notify(SYS_DEVICE_EVENT,
                 PAIPOP_DEVICE_EVENT_FROM_APP,
                 &dev,
                 sizeof(dev));
```

系统随后从应用事件入口把 `SYS_DEVICE_EVENT` 送回 `paipop_fsm_dispatch()`。源码位置：`src/services/paipop_engine_service.c:414-497`、`src/app/paipop_events.c:325-336,535-546`。

这里存在一次明确的异步边界：

```text
LingXin/网络任务
    ⇢ PaipopSDK 生命周期回调
    → paipop_events_post()
    ⇢ 杰理 sys_event 队列
    ⇢ app_core
    → paipop_fsm_dispatch()
```

这样设计的收益是：

- 第三方 SDK 回调保持轻量；
- 玩具状态统一在应用任务上下文中处理；
- 网络、音频、UI 不会任意交叉修改 FSM；
- `paipop_engine_callbacks_enabled` 可以在 shutdown 时先关闭新事件入口，再拆除资源。

注册回调只证明框架保存了入口；运行时究竟由 LingXinSDK 哪个内部线程触发，当前发布接口没有给出完整调度源码，因此本文不把它写成一个确定的普通函数调用栈。

## 十、四个阶段分别怎样驱动玩具表现

### 1. `STARTING`：请求正在启动，还不能表示麦克风可用

`STARTING` 可能包含旧轮清理、任务建立和网络状态准备。FSM 清理旧播放标志，普通启动时让眼睛保持 `IDLE`，而不是立即显示麦克风。源码位置：`src/app/paipop_fsm.c:1900-1946`。

### 2. `INPUTING`：录音 sink 已经可以接收 PCM

这是应用确认输入链准备完成的阶段。FSM 会：

- 取消上一轮退出等待计时器；
- 清理 `round_output_seen`、`playback_active` 等旧状态；
- 普通 Cloud VAD 模式启动无输入窗口；
- 将眼睛切换为 `LISTENING`；
- 打印 `pcm input ready` 时间点。

源码位置：`src/app/paipop_fsm.c:1846-1899`。

所以 `Paipop_StartNewChat()` 返回成功与 `INPUTING` 到达之间可能有明显延迟。前者是请求被接受，后者才是输入链真正就绪。

### 3. `THINKING`：输入结束，云端正在处理

FSM 清除播放活动标志，眼睛回到 `IDLE`，并把本地语音活动服务切到思考阶段策略。源码位置：`src/app/paipop_fsm.c:1947-1962`。

这里的“思考”是产品视角概括，可能包含云端 VAD 收尾、最终 ASR、模型生成和 TTS 准备；当前应用没有能力从一个阶段码精确拆出每项服务器耗时。

### 4. `OUTPUTING`：协议已经输出，不等于扬声器已经出声

收到 `OUTPUTING` 时，FSM 设置：

```c
fsm.round_output_seen = 1;
fsm.output_phase_pending = 1;
```

但只有 `fsm.playback_active` 已经为 1，眼睛才显示 `SPEAKING`。否则仍保持 `IDLE`。源码甚至明确说明：

```c
/* OUTPUTING precedes real DAC playback. */
```

源码位置：`src/app/paipop_fsm.c:1972-2002`。

这避免了一个常见 UI 错误：云端刚报告输出阶段，设备还在等待 TTS 首包和解码缓冲，屏幕却提前显示正在说话。

> **知识卡：三个“回答开始”不是同一时刻**
>
> `AI_TEXT` 到达表示已经取得回答文字；`OUTPUTING` 表示协议进入输出阶段；`PLAYBACK_STARTED` 表示本地播放器已成功执行解码启动。排查回答延迟时必须分别记录这三个时间点，不能只看一个图标。

## 十一、ASR 文本与 AI 文本怎样回到应用

PaipopSDK 对外提供：

```c
PAIPOP_CHAT_LIFE_CYCLE_EVENT_TEXT_OUT
PAIPOP_CHAT_LIFE_CYCLE_EVENT_ASR_TEXT
PAIPOP_CHAT_LIFE_CYCLE_EVENT_AI_TEXT
```

- `TEXT_OUT`：兼容旧应用的完整 JSON；
- `ASR_TEXT`：用户最终识别文字；
- `AI_TEXT`：AI 回复文字。

公开定义位置：`PaipopSDK/paipop_sdk.h:104-126`。

PaipopSDK 封装层解析旧式 `TEXT_OUT` JSON。如果 `type` 是 `asr_final_text`，额外发出 `ASR_TEXT`；如果是 `agent_response_text`，额外发出 `AI_TEXT`。同时保留原始 `TEXT_OUT`，让旧应用不必立即迁移。补充源码位置：`apps/LINGXIN_JIELI/PAIPOP_JIELI_SDK/src/paipop_chat_api.c:74-99,101-136,254-277`。

当前玩具应用的处理策略是：

```c
case PAIPOP_CHAT_LIFE_CYCLE_EVENT_TEXT_OUT:
    /* 已有直接 ASR_TEXT/AI_TEXT，避免重复处理 */
    break;

case PAIPOP_CHAT_LIFE_CYCLE_EVENT_ASR_TEXT:
    printf("[PAIPOP_TIMING] asr_final ...");
    break;

case PAIPOP_CHAT_LIFE_CYCLE_EVENT_AI_TEXT:
    printf("[PAIPOP_TIMING] ai_text_first ...");
    break;
```

源码位置：`src/services/paipop_engine_service.c:465-477`。

### 回调字符串为什么不能直接保存指针

公开接口规定 `payload` 只在本次回调期间有效。直接保存：

```c
saved_text = payload;   /* 错误：回调结束后可能悬空 */
```

如果要交给 UI 任务、写文件或延迟处理，必须在回调内复制内容，再明确由接收者释放。也不应在网络回调里执行阻塞文件 IO，否则可能拖慢 WebSocket 收包和后续音频数据。

## 十二、流式 MP3 怎样进入 `audio_server` 和 DAC

### 1. PaipopSDK 先把第三方接口桥接到平台端口

PaipopSDK 提供的音频桥把 LingXinSDK 期望的播放接口映射为：

```text
module_bufferPlay_audioInit()
    → paipop_cloud_audio_play_init()

module_bufferPlay_data(buf, len)
    → paipop_cloud_audio_play_feed(buf, len)

module_bufferPlay_audioEnd()
    → paipop_cloud_audio_play_end()

module_bufferPlay_terminate()
    → paipop_cloud_audio_play_stop()
```

并通过 `module_bufferPlay_formatCheck()` 声明当前流格式必须是 MP3。补充源码位置：`apps/LINGXIN_JIELI/PAIPOP_JIELI_SDK/src/paipop_audio_port_bridge.c:122-180`。

### 2. `init` 建立一条新的流代际

`paipop_cloud_audio_play_init()` 不会立刻启动解码。它先等待上一条流的硬停止或终态清理完成，然后：

- 保存播放事件回调；
- 生成新的 `stream_generation`；
- 允许接收 feed；
- 清除 input-ended、首包和暂停状态；
- 通知上层播放器初始化完成。

源码位置：`PaipopSDK/port/jl_ac79/src/paipop_cloud_audio_play.c:1112-1190`。

generation 用来隔离连续轮次：旧 WebSocket 包、旧解码器结束事件或迟到的 stop 只能影响创建它们的那一代流，不能污染新回答。

### 3. 首包采用 4 KiB/8 KiB 自适应缓冲

`paipop_cloud_audio_play_feed()` 收到的是压缩 MP3 数据，不是解码后的 PCM。第一批数据先累积到 `firstData`：

```c
#define FAST_FIRST_DATA_LEN          (4 * 1024)
#define WEAK_LINK_FIRST_DATA_LEN     (8 * 1024)
#define WEAK_LINK_FIRST_ACCUMULATE_MS      650
#define WEAK_LINK_FEED_GAP_MS              220
```

健康链路累计 4 KiB 就启动；如果首包累计超过 650 ms，或相邻 feed 间隔超过 220 ms，则认为链路偏弱，改用 8 KiB 缓冲。源码位置：`PaipopSDK/port/jl_ac79/src/paipop_cloud_audio_play.c:87-95,900-929,932-1046`。

这是首字延迟与稳定性的权衡：

```text
缓冲小 → 更早出声，但网络抖动时容易让解码器断粮
缓冲大 → 播放更稳，但用户要多等一段时间
```

当前实现不是永远固定 4 KiB 或 8 KiB，而是根据首批数据节奏选择。

### 4. 达到阈值后启动 MP3 解码

`audio_buffer_start_generation()` 把首批数据写入循环缓冲区，然后调用：

```text
audio_init(generation)
  → server_open("audio_server", "dec")
  → 注册 dec_server_event_handler 到 app_core
  → 创建循环缓冲区与信号量

audio_buffer_data_out(generation)
  → AUDIO_DEC_OPEN，dec_type = "mp3"
  → 获取数字音量句柄
  → AUDIO_DEC_START
```

解码输出源为 `dac`。开启播放 AEC 配置时，代码提供原始采样率并要求 48 kHz 输出；否则使用播放器采样率。源码位置：`PaipopSDK/port/jl_ac79/src/paipop_cloud_audio_play.c:547-619,638-710,720-850`。

后续 MP3 包通过：

```c
cbuf_write(&__this->save_cbuf, buf, rlen);
```

进入循环缓冲区；杰理解码器通过自定义 `audio_vfs_fread()` 消费。数据暂时不足且流尚未结束时，读端等待；生产者写入新包后唤醒读端。源码位置：`PaipopSDK/port/jl_ac79/src/paipop_cloud_audio_play.c:381-421,953-994`。

### 5. `PLAYBACK_STARTED` 才驱动说话表情

`AUDIO_DEC_START` 成功后，适配层设置 `playback_started_notified`，再调用 `cloud_audio_notify_playback_started()`。它先同步通知 FSM：

```c
fsm.playback_active = 1;
fsm.output_phase_pending = 1;
fsm.round_output_seen = 1;
```

随后发布 `PAIPOP_EVT_ENGINE_PLAYBACK_STARTED`。FSM 只有确认当前仍在 `ENGINE_CHAT`、没有退出或打断请求时，才把眼睛切换为 `SPEAKING`。源码位置：`PaipopSDK/port/jl_ac79/src/paipop_cloud_audio_play.c:698-710,836-850`、`src/services/paipop_engine_service.c:626-644`、`src/app/paipop_fsm.c:391-431,2003-2039`。

严格来说，这个事件表示本地播放器成功接受并启动了解码输出链；物理 DAC 的第一颗采样点仍可能受平台内部缓冲影响。但它比云端 `OUTPUTING` 更接近用户真正听见声音的时刻，因此适合作为产品 UI 的播放开始依据。

### 6. `audioEnd` 不等于立刻停止

`paipop_cloud_audio_play_end()` 的语义是“云端已经没有更多数据”，不是丢弃缓冲并立刻静音。它标记输入结束、唤醒解码器，让循环缓冲区里的剩余 MP3 继续播放。真正收到 `AUDIO_SERVER_EVENT_END` 后，适配层才：

- 确认 generation；
- 停止并释放解码器、缓冲区和信号量；
- 通知 playback stopped；
- 回调 `PLAY_END` 给上层引擎。

源码位置：`PaipopSDK/port/jl_ac79/src/paipop_cloud_audio_play.c:270-359,1051-1103,1232-1253`。

这与 `paipop_cloud_audio_play_stop()` 不同：`stop` 用于中断旧回答，需要主动阻止后续 feed 并尽快拆除播放资源。

## 十三、回答结束后怎样自动进入下一轮

普通点击设置 `singleRound = false`，因此一段回答播放完毕后，Paipop/LingXinSDK 可以自动开始下一逻辑轮次。应用随后再次收到：

```text
STARTING → INPUTING
```

此时不需要用户再按一次，也不需要应用在每段回答结束后手动再次调用 `Paipop_StartNewChat()`。同一连续会话中：

- `conversation_id` 保持不变；
- `chatRoundPrepare` 为新轮生成 `turn_id`；
- 录音端口重新进入输入阶段；
- 眼睛从 `IDLE` 回到 `LISTENING`；
- 云端可以利用前文上下文理解省略表达。

只有用户主动退出、无输入超时、WebSocket 异常或其他终止条件让 SDK 发出 `EXIT`，玩具 FSM 才从 `ENGINE_CHAT` 回到 `ENGINE_EXIT`。退出回调还会区分 WebSocket 建连失败、已连接后断开和普通退出；异常网络退出会额外发布 `PAIPOP_EVT_ENGINE_WS_FAIL`，再统一发布 `PAIPOP_EVT_ENGINE_EXIT`。源码位置：`src/services/paipop_engine_service.c:420-444`、`src/app/paipop_fsm.c:1806-1845`。

## 十四、这条链里的并发与可靠性设计

### 1. 控制事件和音频数据使用不同通道

阶段、退出、点击等低频控制消息走系统事件；PCM 和 MP3 走回调、流接口和缓冲区。这样不会让每 20 ms 一帧的 PCM 挤占 `app_core` 控制事件队列。

### 2. FSM mutex 保护复合业务状态

`start_after_init`、`restart_after_exit`、`playback_active` 等字段会跨系统回调、定时器和播放器通知访问。代码在短临界区内读取或更新，再解锁执行提示音、事件投递和 SDK 调用，避免持锁跨越耗时外部操作。

### 3. stream generation 隔离旧回答

播放器的 feed、decoder 和 terminal event 都携带或检查 generation。新一轮开始后，旧轮迟到数据不能再写入新轮循环缓冲区；旧 `AUDIO_SERVER_EVENT_END` 也不能错误地关闭新解码器。

### 4. 同步状态更新先于异步 UI 事件

播放开始时先同步设置 `playback_active` 和本地语音活动模式，再投递 `PLAYBACK_STARTED`。这样 AEC/语音活动钩子与 UI 不会看到互相矛盾的阶段。

### 5. shutdown 先关闭回调入口

`paipop_engine_shutdown()` 先把 `paipop_engine_callbacks_enabled` 清零，再请求退出对话、停止播放器和清理 ID。即使第三方 SDK 之后还有迟到回调，也不会继续向已拆除的玩具服务发布事件。源码位置：`src/services/paipop_engine_service.c:647-672`。

## 十五、几个容易被追问的问题

### Q1：为什么点击函数不直接调用 `Paipop_StartNewChat()`？

因为点击的语义依赖当前业务状态。事件层只翻译输入，FSM 才能统一处理初始化锁存、失败重试、空闲启动和活动会话切换，防止硬件层和云端生命周期耦合。

### Q2：`Paipop_StartNewChat()` 返回 0，为什么还要等 `INPUTING`？

返回 0 只表示异步启动请求被接受。WebSocket、对话任务和录音端口仍可能在准备；`INPUTING` 才是 SDK 报告输入链已进入采集/上传阶段的生命周期证据。

### Q3：Cloud VAD 和连续对话是同一个功能吗？

不是。`chatMode = CLOUD_VAD` 决定本轮由云端判断说完；`singleRound = false` 决定回答后继续下一轮。两者是正交参数。

### Q4：为什么 PCM 不走 `sys_event`？

24 kHz 单声道 16 bit PCM 每秒约 48 KB，每 20 ms 就有一帧。逐帧包装成系统控制事件会增加复制、排队和调度开销；连续媒体数据更适合回调和专用缓冲区。

### Q5：为什么一帧是 960 字节？

`24000 × 1 × 2 × 0.02 = 960`。分别对应每秒采样点、声道、每采样点字节数和 20 ms 帧长。

### Q6：`OUTPUTING` 为什么不能直接显示说话图标？

它只表示协议进入输出阶段。设备可能仍在等待 TTS 首包、累计 4/8 KiB 首播数据或启动 MP3 解码器；播放器成功执行 `AUDIO_DEC_START` 后的 `PLAYBACK_STARTED` 才是更可靠的本地依据。

### Q7：为什么首播既有 4 KiB 又有 8 KiB？

4 KiB 降低健康网络下的首字延迟；检测到首包积累过慢或包间隔较大时，8 KiB 给弱网更多抗抖余量。它是在低延迟和不卡顿之间做动态权衡。

### Q8：`audioEnd` 与 `stop` 有什么区别？

`audioEnd` 表示生产者不再发送新 MP3，已有缓冲仍需自然播完；`stop` 表示主动终止当前回答，要拒绝后续数据并拆除播放链。

### Q9：回调中的 ASR/AI 字符串能保存地址以后使用吗？

不能。公开契约规定 payload 只在本次回调期间有效。跨线程、写文件或延迟显示前必须复制内容，并明确由哪个模块释放。

### Q10：这个项目中哪些部分属于第一方工作？

玩具事件层、业务 FSM、`paipop_engine_service`、PaipopSDK 封装和杰理音频端口属于 Paipop 第一方实现；LingXinSDK 提供第三方 AI 对话引擎。项目工作的重点是接口抽象、生命周期治理、对话参数管理、音频适配、线程切换和可靠性处理，而不是把第三方云端 ASR/LLM/TTS 说成自己重新实现。

## 十六、怎样用一分钟讲清楚

可以这样复述：

> 用户单击 K1/K2 后，杰理按键事件进入应用统一入口。`paipop_events_handle_key()` 只做 OTA、组合键和模式冲突过滤，再把点击转换为 `PAIPOP_EVT_TOUCH_CLICK`；FSM 根据当前状态决定锁存、重试、启动还是中断。正常空闲时，它通过 `paipop_engine_service` 调用我封装的 PaipopSDK，以 Cloud VAD、连续对话模式提交新会话。`Paipop_VoiceChatInit` 管长期回调和公共能力，`Paipop_StartNewChat` 只提交本次请求，返回成功不等于已经开始录音，真正可收音要等异步 `INPUTING`。
>
> 输入阶段复用统一 ADC 采集服务，以 24 kHz、单声道、16 bit、20 ms/960 字节的 PCM 帧通过 PaipopSDK 音频桥交给第三方 LingXinSDK，再由它上传云端。阶段变化不会直接在 SDK 回调线程修改玩具状态，而是转成 `sys_event` 回到 `app_core`，由 FSM 串行控制眼睛。云端返回 ASR 文字、AI 文字和流式 MP3；MP3 在平台端根据网络情况先缓存 4 KiB 或 8 KiB，再通过杰理 `audio_server` 解码并输出到 DAC。`OUTPUTING` 只是协议阶段，只有本地 `AUDIO_DEC_START` 成功后的 `PLAYBACK_STARTED` 才显示说话状态。回答播放完后，由于 `singleRound` 为 false，SDK 自动进入下一轮输入，保持 conversation_id 并生成新的 turn_id，从而形成有上下文的连续对话。

## 十七、源码证据索引

| 主题 | 证据位置 | 性质与限制 |
|---|---|---|
| V1.2.8、AC791N、正常功能开关与录音格式 | `include/app_config.h:4-25,70-86,171-179` | 已验证的发布配置；本文未重新构建 |
| 应用事件入口 | `app_main.c:158-176` | 已验证的第一方回调定义 |
| 系统事件分类、点击过滤与业务事件投递 | `src/app/paipop_events.c:325-336,347-460,535-566` | 已验证的第一方直接调用；系统队列内部在杰理 SDK 边界 |
| 玩具状态合法转换 | `src/app/paipop_fsm.c:100-180` | 已验证的第一方 FSM 定义 |
| 初始化期间锁存启动意图 | `src/app/paipop_fsm.c:435-470,1495-1503,1663-1685` | 已验证的 mutex 保护状态 |
| 会话重启和 `ENGINE_CHAT` 转换 | `src/app/paipop_fsm.c:1285-1375` | 已验证的第一方同步控制路径 |
| Paipop 对话初始化 | `src/services/paipop_engine_service.c:500-535` | 已验证第一方参数；PaipopSDK/LingXin 执行进入库边界 |
| 新会话参数和 StartNewChat | `src/services/paipop_engine_service.c:258-295,538-554` | 已验证的第一方直接调用与公开 API |
| conversation/turn 与每轮 JSON | `src/services/paipop_engine_service.c:25-35,130-255` | 已验证的第一方状态和生成逻辑 |
| 对话模式、阶段、返回码和回调生命周期 | `PaipopSDK/paipop_sdk.h:68-83,104-126,156-228` | 已验证的 PaipopSDK 公开契约 |
| PaipopSDK 到 LingXin 参数/生命周期桥接 | `apps/LINGXIN_JIELI/PAIPOP_JIELI_SDK/src/paipop_chat_api.c:74-99,254-400` | 对应开发源码与发布库一致性强支持；第三方内部继续停止追踪 |
| 24 kHz PCM 和共享 ADC sink | `PaipopSDK/port/jl_ac79/src/paipop_audio_recorder.c:8-69,150-310` | 已验证的第一方平台适配源码 |
| PCM 进入 LingXinSDK | `apps/LINGXIN_JIELI/PAIPOP_JIELI_SDK/src/paipop_audio_port_bridge.c:26-120` | 已验证桥接定义；上传协议内部是第三方边界 |
| 生命周期阶段转玩具事件 | `src/services/paipop_engine_service.c:414-497` | 已验证回调逻辑；实际线程未运行观测 |
| INPUTING/THINKING/OUTPUTING 与 UI | `src/app/paipop_fsm.c:1846-2039` | 已验证第一方状态处理；云端耗时未运行测量 |
| MP3 播放桥 | `apps/LINGXIN_JIELI/PAIPOP_JIELI_SDK/src/paipop_audio_port_bridge.c:122-180` | 已验证接口映射，来源同上 |
| 首播阈值、循环缓冲和解码启动 | `PaipopSDK/port/jl_ac79/src/paipop_cloud_audio_play.c:87-95,381-421,547-850,900-1046` | 已验证的第一方平台适配源码 |
| 播放开始、结束与 generation 隔离 | `PaipopSDK/port/jl_ac79/src/paipop_cloud_audio_play.c:270-359,1112-1253` | 已验证的软件状态；物理 DAC 首采样未运行观测 |
| shutdown 的迟到回调保护 | `src/services/paipop_engine_service.c:647-672` | 已验证第一方清理顺序 |

## 总结

一次正常语音对话不是“按键函数调用一个云端 API”这么简单，而是四类链路协作的结果：点击通过系统事件进入玩具 FSM；FSM 通过 `paipop_engine_service` 和 PaipopSDK 提交带 conversation/turn 参数的对话请求；24 kHz PCM 通过专用回调与缓冲链进入第三方 LingXinSDK；云端阶段、文本和流式 MP3 再分别通过生命周期回调和播放端口返回。

最值得掌握的四个边界是：**玩具状态与对话阶段分离，控制事件与音频数据分离，PaipopSDK 第一方封装与 LingXinSDK 第三方引擎分离，云端 `OUTPUTING` 与本地 `PLAYBACK_STARTED` 分离。**看清这些边界以后，初始化锁存、连续上下文、PCM 帧长、首播缓冲、generation 和回调生命周期就不再是零散技巧，而是同一套异步语音产品架构中的必然设计。
