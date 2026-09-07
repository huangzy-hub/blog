---
title: paipopAi对话玩具解析（五）：AI 播放时如何实现自然语音打断
published: 2026-09-07
updated: 2026-09-07
pinned: false
description: 从统一麦克风、16 kHz AEC VAD、动态门限、降音复核、预录 PCM、generation 隔离和 FSM 交接七个层次，拆解 Paipop 玩具怎样在 AI 播放期间识别近端用户抢话并无缝开启下一轮。
tags: [AC791N, Paipop, 嵌入式, AEC, VAD, 语音打断, 音频]
category: 嵌入式
series: Paipop AI 对话玩具源码解析
seriesOrder: 6
draft: false
---

# paipopAi对话玩具解析（五）：AI 播放时如何实现自然语音打断

上一篇从 SDK 设计者的角度解释了 PaipopSDK 怎样封装第三方 LingXinSDK；再上一篇则走通了一轮正常语音对话：用户说话、PCM 上传、云端处理、MP3 下发和扬声器播放。

但真实对话不会总是“一人一句、互不打断”。当 AI 回答太长或理解错误时，用户最自然的动作不是等待，而是直接开口：

> “不是，我问的是明天的天气。”

这时设备正在用扬声器播放 AI 的声音，麦克风也会把这段声音采回来。系统怎样知道麦克风里的声音来自用户，而不是来自自己？确认用户抢话以后，怎样停止旧回答、保住用户已经说出的句首，并把它交给下一轮云端录音？

这篇就沿着一次真实的自然语音打断，把检测、复核、音频接管和新旧轮次隔离完整拆开。

先用一句话概括：

> Paipop 的自然语音打断不是“VAD 命中就停止播放”，而是用唯一麦克风采集服务统一管理 16 kHz AEC 检测与 24 kHz ASR 上传；播放期候选声音经过动态门限、AEC 预热和降音复核后才进入 FSM，同时用预录 PCM、pending 队列和 generation 把用户句首安全交给新录音器。

## 阅读导航

1. [杰理 AC79 应用启动与注册机制详解：从 `REGISTER_APPLICATION` 到 `start_app`](/posts/杰理ac79应用启动与注册机制详解/)
2. [paipopAi 对话玩具解析（一）：从 `APP_STA_START` 到眼睛任务与摇一摇服务](/posts/paipopai对话玩具解析一从应用启动到眼睛与摇一摇/)
3. [paipopAi 对话玩具解析（二）：从按键与摇一摇到对话打断](/posts/paipopai对话玩具解析二从按键与摇一摇到对话打断/)
4. [paipopAi 对话玩具解析（三）：从按键启动到云端语音回答](/posts/paipopai对话玩具解析三从按键启动到云端语音回答/)
5. [paipopAi 对话玩具解析（四）：PaipopSDK 如何封装 LingXinSDK](/posts/paipopai对话玩具解析四paipopsdk如何封装lingxinsdk/)
6. **本文**：从 AEC、VAD、预录 PCM 和轮次隔离理解自然语音打断。

## 本文范围与证据边界

本文基于独立正式发布仓库 `Paipop_YP_Toy_release_v128` 的 `main@24a83f9`，版本为 `V1.2.8 / 10208`，目标平台为杰理 AC791N/WL82。

本次采用静态源码复核，没有重新烧录设备或采集新的串口日志。因此：

| 结论 | 可信度 | 依据 |
|---|---|---|
| VAD 模式切换、预录、降音确认和 FSM 交接逻辑 | 已验证 | 正式版源文件中的直接定义与调用 |
| `paipop_voice_activity.c`、录音端口和播放器被目标编译 | 已验证 | `board/wl82/Makefile` |
| 杰理 `audio_server` 提供 VAD/AEC 编码能力 | 已验证到接口边界 | 请求结构、配置宏和事件处理代码 |
| LingXinSDK 在新轮启动时内部怎样终止旧 task | 强证据 | 公共 API、端口回调和产品行为，未在本文展开第三方内部状态机 |
| 默认参数在所有机壳、距离和噪声环境下都最优 | 未证明 | 必须通过整机声学回归确定 |

代码归属也需要分清：

| 组件 ID | 代码 | 归属与职责 |
|---|---|---|
| `COMP-01` | `paipop_voice_activity.c` | Paipop 第一方：统一采集、VAD、预录和参数管理 |
| `COMP-02` | `paipop_fsm.c` | Paipop 第一方：判断当前状态能否接受打断并管理交接 |
| `COMP-03` | `paipop_engine_service.c` | Paipop 第一方：将 FSM 请求转换成 PaipopSDK 对话请求 |
| `COMP-04` | `paipop_audio_recorder.c` | Paipop 音频端口：把 LingXin 录音器接到统一采集 sink |
| `COMP-05` | `paipop_cloud_audio_play.c` | Paipop 音频端口：播放、降音、恢复、硬停止与流 generation |
| `COMP-06` | `audio_server`、ADC、DAC、AEC | 杰理平台能力：本文追到公开请求与事件边界 |
| `COMP-07` | PaipopSDK/LingXinSDK 静态库 | 对话和协议能力：本文只说明交互契约 |

## 一、这不是简单地“检测到声音就打断”

最直观的方案可能是：

```text
麦克风检测到声音
→ 停止 AI 播放
→ 开始下一轮录音
```

但在真实设备上，这种方案几乎一定会误触发。

因为 AI 播放时，扬声器声音也会进入麦克风：

```text
AI 回答音频
    ↓
扬声器发声
    ↓
空气与机壳传播
    ↓
麦克风重新采集
    ↓
普通 VAD 认为“有人说话”
```

除此之外，麦克风还可能采到：

- 房间里的电视或其他人声；
- 玩具移动、敲击和摩擦产生的机械声；
- ADC 和模拟前端底噪；
- DAC 启动、功放开关产生的瞬态；
- 播放停止以后尚未衰减的回声尾；
- AEC 尚未完成收敛时残留的扬声器声音。

所以自然打断实际包含三个独立问题：

```text
能不能检测到用户开口
        +
能不能排除设备自己的声音
        +
能不能保住检测前的用户语音
```

对应到项目：

| 问题 | 机制 |
|---|---|
| 用户是否持续发声 | 杰理硬件 VAD + 持续时间门限 |
| 是否明显高于环境噪声 | 后 AEC PCM 能量 + 动态噪声门限 |
| 是否仍可能是扬声器回声 | AEC/NLP/ANS + 预热窗口 + 降音复核 |
| 播放刚结束是否还有回声尾 | echo-tail guard |
| 检测完成前说出的内容怎么办 | 滚动预录缓冲 + pending 队列 |
| 旧回调会不会污染新一轮 | 多类 generation + FSM phase gate |

因此，`AUDIO_SERVER_EVENT_SPEAK_START` 只是一个候选信号，不是最终打断命令。

## 二、FLOW-05-01：一次播放期自然打断的完整链路

```text
云端 MP3 到达
  → paipop_cloud_audio_play_feed()
  → 解码器启动并确认 AUDIO_DEC_START
  → cloud_audio_notify_playback_started()
  → paipop_fsm_playback_started_sync()
  → VAD 模式切换为 SPEAKING
  → paipop_voice_activity_notify_playback_started()
  → 等待 AEC 预热 450 ms

用户开始说话
  → audio_server 发出 AUDIO_SERVER_EVENT_SPEAK_START
  → 自适应能量门限初筛
  → 锁定最近 1 秒预录 PCM
  → paipop_cloud_audio_play_duck(20)
  → 继续测量约 300 ms
  → 检查语音连续性、有效帧比例和降音后能量

确认近端人声
  → paipop_events_post(PAIPOP_EVT_VOICE_INTERRUPT, SPEAKING)
  ⇢ 通过 sys_event 队列切到 app_core
  → paipop_fsm_dispatch()
  → 校验当前 VAD 模式与对话状态
  → paipop_engine_interrupt_chat()
  → Paipop_StartNewChat()，沿用 conversationId
  → 新录音 sink 打开并获得新 generation
  → 先排空 pending 中的预录 PCM
  → 再转发实时 24 kHz PCM
```

其中 `⇢` 是一次异步队列跳转，不是普通同步函数调用。VAD 服务负责“提出经过验证的候选”，FSM 才负责“当前业务是否接受这个候选”。

关键调用边证据：

| 调用边 | 类型 | 可信度 |
|---|---|---|
| 播放器启动 → FSM 同步播放通知 | 直接调用 | 已验证 |
| 播放器启动 → VAD 播放通知 | 弱符号直接调用 | 已验证于当前目标源码和构建输入 |
| VAD → `PAIPOP_EVT_VOICE_INTERRUPT` | 事件投递 | 已验证 |
| 事件队列 → FSM | 线程/队列跳转 | 已验证到项目事件处理代码 |
| FSM → `paipop_engine_interrupt_chat()` | 直接调用 | 已验证 |
| 产品封装 → PaipopSDK/LingXinSDK | 外部静态库边界 | 强证据 |

## 三、VAD 服务有三种工作模式

公共头文件定义：

```c
enum paipop_voice_activity_mode {
    PAIPOP_VOICE_ACTIVITY_DISABLED = 0,
    PAIPOP_VOICE_ACTIVITY_THINKING,
    PAIPOP_VOICE_ACTIVITY_SPEAKING,
};
```

它不是玩具主 FSM，而是麦克风检测服务的局部状态。

### 1. `DISABLED`

以下情况关闭本地抢话检测：

- 待机、配网和引擎退出；
- 云端正在正常收音的 `INPUTING` 阶段；
- 新旧轮次正在交接；
- 按住说话模式占用业务入口；
- 当前状态不允许自然打断。

这里的“关闭检测”不一定表示立刻关闭 ADC。代码明确区分：

```text
VAD detection disabled
≠
microphone capture must stop
```

如果 LingXin 录音器已经注册了 sink，`desired_mode` 即使是 `DISABLED`，统一采集服务仍需继续给云端提供 PCM。

待机时说话不会启动对话，因此这套机制不是唤醒词系统。用户必须先通过按键进入一次云端会话，之后才能在 AI 思考或回答时自然抢话。

### 2. `THINKING`

云端已经结束用户输入，正在进行 ASR、LLM 或 TTS 处理，通常没有持续的扬声器输出。

这时检测链较短：

```text
硬件 VAD 持续命中
+ 动态能量门限通过
+ 不在播放回声尾保护期
→ 接受为思考期打断
```

### 3. `SPEAKING`

AI 正在真实播放，误触发风险最大。候选必须满足：

```text
AEC/NLP/ANS 可用
+ DAC 播放已真实开始
+ AEC 预热完成
+ 硬件 VAD 命中
+ 自适应能量门限通过
+ 降音后的语音仍连续、仍有足够能量
+ 当前播放器 generation 仍可打断
```

任意条件失效，候选都不能进入 FSM。

## 四、为什么整个系统只能有一个麦克风采集所有者

旧式录音实现通常是每个功能自己打开 ADC：

```text
云端录音器 → 打开一次 audio_server enc
本地 VAD   → 再打开一次 audio_server enc
```

但两个模块争用同一个 ADC、AEC 和编码服务，可能造成：

- 第二次打开返回忙或平台错误；
- 停止其中一个录音器时误伤另一个；
- AEC 参考和 PCM 回调属于不同实例；
- 生命周期竞态导致旧回调落进新对象。

正式版采用相反结构：

```text
                 ┌─ 本地 VAD / AEC 检测
唯一 audio_server enc ─┤
                 └─ 24 kHz PCM sink → LingXin 录音器
```

`paipop_voice_activity.c` 是唯一采集所有者。LingXin 需要录音时，`paipop_audio_recorder.c` 不再默认打开第二个 ADC，而是优先注册：

```c
paipop_voice_activity_sink_open(
    recorder_shared_sink_write,
    recorder_handler,
    recorder_handler->frame_size,
    &recorder_handler->shared_sink_generation);
```

`recorder_shared_sink_write()` 再把统一采集得到的 PCM 交给 LingXin 的 `data_callback`。

三个细节很重要。

### 1. 使用弱符号保留通用性

录音端口将统一采集接口声明为弱符号。玩具目标链接了 `paipop_voice_activity.c`，就使用共享 sink；其他没有该服务的 PaipopSDK 项目仍可使用原来的独立 ADC 录音后备路径。

### 2. 服务已链接但打开失败时不能回退到第二个 ADC

如果共享服务存在但 `sink_open()` 失败，代码直接返回失败，不再悄悄打开传统录音器。否则恰好会重新引入双 ADC 竞态。

### 3. 先检查音频格式

共享 sink 要求：

```text
24000 Hz
单声道
S16 PCM
960 字节/帧
```

960 字节等于：

```text
24000 samples/s × 2 bytes × 20 ms = 960 bytes
```

格式不一致时拒绝注册，避免双方用不同的帧边界解释同一块内存。

## 五、为什么本地检测和云端 ASR 使用两套采集配置

统一所有权不等于永远使用同一种采样配置。源码定义了两个 profile：

```c
PAIPOP_CAPTURE_PROFILE_VAD_AEC_16K
PAIPOP_CAPTURE_PROFILE_ASR_NATIVE_24K
```

选择规则非常直接：

```c
if (sink_active) {
    return ASR_NATIVE_24K;
}
return VAD_AEC_16K;
```

### `VAD_AEC_16K`

用于 AI 思考或播放期间的本地抢话检测：

- 16 kHz；
- 单声道 S16；
- 10 ms、320 字节一帧；
- 开启硬件 VAD；
- 在配置满足时开启 AEC、NLP 和 ANS；
- DAC 参考采样率设为 48 kHz。

### `ASR_NATIVE_24K`

LingXin 新一轮录音 sink 打开以后使用：

- 原生 24 kHz；
- 单声道 S16；
- 20 ms、960 字节一帧；
- 不使用本地 VAD；
- 不将 16 kHz AEC 输出继续作为云端主录音。

为什么不一直把 AEC 后的 16 kHz PCM 升采样到 24 kHz 上传？

因为升采样只能增加样本数量，不能恢复 16 kHz 阶段已经丢失的高频信息。源码注释明确指出，AEC 输出的带宽限制会损失一部分辅音细节，可能影响云端 ASR。

因此这是一种质量取舍：

```text
AI 播放/思考期：优先抗回声检测 → 16 kHz AEC
云端正式收音期：优先识别清晰度 → 原生 24 kHz
```

profile 切换时会先关闭旧 encoder client，再重新打开新配置。这样延迟到达的旧 `END` 事件不会被误认为新 profile 的故障。

## 六、16 kHz 预录 PCM 怎样交给 24 kHz 云端

打断发生时，用户开头的部分语音是在 `VAD_AEC_16K` profile 下采到的。如果直接丢掉，就会出现：

```text
用户说：“不是，我问明天”
云端收到：“我问明天”
```

因此检测期 PCM 会通过一个固定比例的线性 SRC 从 16 kHz 转成 24 kHz。

比例是：

```text
24000 / 16000 = 3 / 2
```

源码不是按每个块孤立插值，而是保存：

- 上一个输入样本 `src_prev`；
- 当前三分之一相位 `src_phase_thirds`；
- 尚未填满的上传帧 `upload_frame`。

这样跨越 10 ms 输入块时不会在块边界突然跳变。每积累到 960 字节，就形成一帧与云端录音器格式一致的 20 ms PCM。

需要诚实说明：线性 SRC 的计算量低、适合 MCU，但滤波质量不如带抗混叠滤波器的专业重采样器。这里它只承担短暂预录片段的格式衔接；正式云端录音会切换回原生 24 kHz。

## 七、为什么不能在 `OUTPUTING` 阶段立即启用播放期打断

LingXinSDK 的 `OUTPUTING` 只表示云端进入输出阶段，并不等于扬声器已经发声：

```text
OUTPUTING
→ 第一批 MP3 到达
→ 建立解码器
→ 首播缓存
→ AUDIO_DEC_START
→ DAC 真正输出
→ PLAYBACK_STARTED
```

如果一收到 `OUTPUTING` 就启用 `SPEAKING` 检测：

- AEC 还没有稳定的播放参考；
- 解码启动瞬态可能被当成人声；
- 本地提示音或上一轮尾音可能被归到当前流。

所以 FSM 在 `OUTPUTING` 到来而 `playback_active == 0` 时主动关闭检测。播放器只有在 `AUDIO_DEC_START` 成功且当前 `stream_generation` 仍有效时，才设置 `playback_started_notified`。

随后调用顺序是刻意设计的：

```text
paipop_fsm_playback_started_sync()
→ FSM 先选择 SPEAKING 模式

paipop_voice_activity_notify_playback_started()
→ VAD 再记录物理播放时刻并启动预热
```

这可以保证 VAD 收到“播放开始”时，业务模式已经同步切换完成。

面试时可以总结为：

> 协议状态不能代替硬件事实。`OUTPUTING` 是云端状态，`PLAYBACK_STARTED` 才是 DAC 生命周期事实。

## 八、AEC 为什么还需要 450 ms 预热

即使 AEC 已经打开，也不能在第一个播放样本出现时立刻相信输出。

AEC 需要根据扬声器参考信号估计声学回声路径，包括：

- DAC 到功放的延迟；
- 扬声器到麦克风的空气传播；
- 机壳反射和共振；
- 当前音量对应的回声幅度。

正式版默认：

```c
warmup_ms = 450;
```

真实播放开始后，系统先记录：

```text
playback_started = 1
warmup_done = 0
barge_in_armed = 0
```

450 ms 计时到期且以下条件仍成立时，才设置：

```text
capture_open
+ aec_ready
+ desired_mode == SPEAKING
+ playback_started
→ barge_in_armed = 1
```

计时器参数携带 `playback_generation`。如果期间切换了播放流、模式或录音器，旧计时器即使晚到也会因 generation 不匹配而退出。

这个预热窗口会牺牲回答开头几百毫秒的可打断性，但能显著降低播放启动阶段的自打断风险。

## 九、第一层筛选：硬件 VAD 不是最终裁判

`VAD_AEC_16K` profile 会配置：

```c
req.enc.use_vad = 2;
req.enc.vad_auto_refresh = 1;
req.enc.vad_start_threshold = speech_ms;
req.enc.vad_stop_threshold = 0;
```

默认 `speech_ms = 350`，表示音频服务需要观察到一段持续活动，才产生 `AUDIO_SERVER_EVENT_SPEAK_START`。

持续时间可以过滤一部分极短撞击声，但不能区分：

- 用户说话；
- 电视里的人声；
- AEC 残余回声；
- 持续机械噪声。

因此硬件 VAD 只负责降低软件处理频率和给出候选事件，后面还要检查后 AEC PCM 的实际能量。

## 十、第二层筛选：动态噪声门限

系统对每个 16 kHz PCM 帧计算平均绝对值：

```text
frame_level = Σ abs(sample[i]) / samples
```

它比峰值更不容易被单个脉冲样本影响，计算量也适合 MCU。

### 噪声底如何学习

只有在以下条件成立时才更新 `noise_floor_level`：

```text
检测模式已启用
+ 当前不是语音段
+ 没有确认任务
+ 没有 pending 预录
+ 尚未锁存打断
```

环境变安静时，噪声底以约 32 帧的指数平均较快下降；环境变吵时，用约 128 帧的平均缓慢上升，并限制单次上升幅度。

慢速上升很重要。如果候选语音刚出现时噪声底立刻跟着升高，用户说话可能会把自己“学习成噪声”。

### 门限公式

完成初始学习后，近似为：

```text
dynamic_gate = max(
    noise_floor × noise_pct / 100,
    noise_floor + headroom,
    startup_gate
)
```

平衡默认值：

```text
noise_pct   = 260%
headroom    = 32
startup_gate = 96
```

在最初 20 帧、噪声底还不可靠时，直接使用 `startup_gate`，避免启动阶段门限为零。

这套门限能适应安静房间和稳定风扇噪声，但它仍不能单独证明“声音来自近端用户”。播放期还要经过降音复核。

## 十一、思考期打断和播放期打断为什么不同

### 思考期

`THINKING` 阶段通常没有持续扬声器输出。通过硬件 VAD 和动态能量门限后，可以直接：

```text
锁存 hit
→ 锁定预录 PCM
→ 发布 VOICE_INTERRUPT(THINKING)
```

### 播放期

`SPEAKING` 阶段设备自己就是最大的声源。此时检测到候选后不能立即打断，而是：

```text
锁定预录
→ 将 AI 音量临时降到 20%
→ 继续观察 300 ms
→ 判断声音是否仍持续
```

这就是项目里的“降音复核”。

## 十二、FUNC-05-01：播放期降音复核怎样工作

入口位于 `paipop_capture_encoder_event()` 对 `AUDIO_SERVER_EVENT_SPEAK_START` 的处理。

候选建立前要满足：

```text
capture_open
+ aec_ready
+ desired_mode == SPEAKING
+ playback_started
+ warmup_done
+ barge_in_armed
+ !cooldown_active
+ !confirm_pending
+ !hit_latched
+ !pending_active
```

建立候选时会快照：

- 候选前 PCM 平均能量；
- 当前动态门限；
- 播放已经持续的时间；
- 当前绝对门限；
- 有效帧比例和保持比例要求；
- 确认窗口长度；
- 临时降音比例。

然后锁定 1 秒预录，并调用：

```c
paipop_cloud_audio_play_duck(duck_pct);
```

默认把当前数字音量降到原音量的 20%，而不是立即暂停或销毁播放器。这是一个可逆操作：如果候选是假信号，可以继续播放未完成的回答。

### 300 ms 内测量什么

前 60 ms 是音量变化和声学路径稳定时间，不计入统计。之后每个 10 ms PCM 帧参与测量：

```text
post_level_sum
post_level_frames
active_level_sum
active_frames
speech_continuous
```

一帧要超过下面三类门限的最大值才算 active：

```text
候选开始时的动态门限
候选前能量 × retain_pct
绝对确认门限
```

### 默认确认条件

窗口结束时同时检查：

- 实际采到的帧数达到期望帧数的 80%；
- active 帧数量达到要求；
- active 帧比例至少 65%；
- 降音后 active 平均能量至少保留候选前的 65%；
- active 平均能量仍高于动态门限；
- active 平均能量仍高于绝对门限；
- 硬件 VAD 语音状态在窗口内没有中断；
- 播放器仍是可打断的活动流。

播放开始后的前 1000 ms 使用更严格的绝对门限 `1024`，之后使用 `512`。这是因为开头阶段 AEC 更容易残留瞬态回声。

### 为什么降音复核有效

如果候选主要来自扬声器：

```text
扬声器降音
→ 麦克风回声同步下降
→ retain_percent 或 active_percent 不达标
→ 判定 echo/noise
```

如果候选来自近端用户：

```text
扬声器降音
→ 用户仍继续说话
→ 后 AEC 能量保持
→ 判定 near-end
```

这不是数学上绝对可靠的声源定位，但在单麦克风、资源受限 MCU 上，是一种成本可控且可解释的工程复核。

## 十三、误触发时为什么不能直接丢掉旧回答

如果确认条件不成立，系统执行：

```text
恢复原始数字音量
→ 取消候选预录
→ 进入 700 ms 冷却期
→ 旧回答继续播放
```

这条回滚路径是自然体验的关键。否则每次玩具碰撞或电视声命中 VAD，AI 回答都会被永久截断。

冷却期内 `barge_in_armed = 0`。计时结束后，只有当前仍然是：

```text
SPEAKING
+ playback_started
+ warmup_done
+ AEC ready
+ 没有其他候选
```

才重新允许打断。

同样，冷却计时器使用自己的 `cooldown_generation`。模式已经变化时，旧冷却回调不能重新打开检测。

## 十四、播放停止以后为什么还要保护 600 ms

DAC 停止并不意味着麦克风中的回声瞬间归零。房间混响、机壳共振和 AEC 滤波器状态可能留下短暂尾音。

播放器停止时，VAD 从 `SPEAKING` 过渡到 `THINKING`。如果立即按思考期宽松规则接受声音，最后一小段 AI 尾音可能触发新一轮。

所以项目启动默认 600 ms 的 echo-tail guard：

```text
播放停止
→ 进入尾音保护期
→ 若出现候选，立即开始保存 PCM
→ 不马上发布事件
→ 保护期结束时再次检查语音是否仍持续
```

如果语音持续到保护期结束，说明它更可能是用户真的在说话，于是接受已经缓存的候选；如果语音停止，则取消预录。

注意这里是“先保存、后确认”。如果等 600 ms 以后才开始录，真实用户的句首会全部丢失。

## 十五、FUNC-05-02：1 秒预录环形缓冲区

统一采集服务始终将生成的 24 kHz、20 ms PCM 帧写入 `preroll_buf`。

容量计算为：

```text
24000 samples/s × 2 bytes × 1000 ms = 48000 bytes
```

它是一个覆盖式环形缓冲：

```text
新帧持续写入
→ 写到末尾后绕回开头
→ 永远保留最近约 1 秒
```

平时这里只保存历史，不上传给下一轮。当候选成立时，`paipop_preroll_arm_window_locked()` 会：

1. 清空本次 pending 队列；
2. 标记 `pending_active = 1`；
3. 记录当前旧 sink generation；
4. 找到环形缓冲中所需窗口的最老位置；
5. 按时间顺序复制到 pending 队列；
6. 后续实时 PCM 也继续追加到 pending。

自然语音和摇一摇使用 1000 ms；物理按键使用较短的 450 ms。按键事件通常比用户真正开口更早到达，较短窗口可以减少无意义静音和上传尾部积压。

### 为什么叫“锁定”而不是“复制一次就结束”

因为新云端录音器不会在候选确认的同一瞬间完成建立。锁定以后，服务还要持续收集：

```text
候选前的历史
+ 确认窗口中的语音
+ FSM 与 SDK 交接期间的语音
```

直到新 sink 打开，整个 pending 才被交给下一轮。

## 十六、pending 队列怎样跨越新旧录音器

pending 默认目标容量是 4 秒：

```text
960 bytes/frame × 200 frames = 192000 bytes
```

如果堆内存不足，初始化会依次尝试：

```text
4 秒 → 3 秒 → 2 秒 → 1 秒
```

至少保留一秒的退化策略比“一次分配失败就完全禁用服务”更适合嵌入式设备。

### 队列满了怎么办

代码优先丢弃最老的完整 960 字节帧，为新帧腾空间。

这是一种明确取舍：在极端交接延迟下，保留用户最近仍在说的内容和句尾，代价是可能损失最早部分。系统同时统计 `pending_drop_count`，便于发现容量或交接性能问题。

### 为什么不能把 pending 发给当前 sink

候选出现时，旧轮录音器可能还没有完全退出。如果马上把“打断用户说的话”送进旧 sink，它会被当成旧问题的尾部。

因此锁定时记录：

```c
pending_after_sink_generation = current_sink_generation;
```

只有新 sink 的 generation 与这个旧值不同，worker 才开始排空 pending。

这条约束可以概括为：

> 触发打断的新语音，绝不能回流到它正在打断的旧录音器。

### 为什么先排 pending 再发 live PCM

新 sink 建立以后，PCM worker 循环执行：

```text
pending 中还有完整帧？
    ├─ 是：按时间顺序发送 pending
    └─ 否：清除 pending_active，转入实时发送
```

从而保证云端收到：

```text
句首 → 确认期 → 交接期 → 当前实时语音
```

而不是先收到实时句尾，再补历史句首。

pending 还设置了 9 秒超时。如果新录音器一直没有建立，就清空缓存，避免故障状态无限占用内存和持续录音。

## 十七、为什么 VFS 回调里只入队，不做复杂处理

杰理 `audio_server` 通过 VFS 风格的 `fwrite` 回调交付 PCM。该回调只负责把原始数据写入 `raw_cbuf` 并唤醒 `paipop_pcm` worker。

SRC、能量计算、预录路由和 LingXin 数据回调都在 worker 中执行。

这样做有三个理由：

- 音频服务回调必须快速返回，避免阻塞底层采集；
- LingXin 数据回调的耗时不应直接占用音频服务上下文；
- sink 打开、关闭和旧回调退出需要明确同步点。

这也是为什么代码专门维护 `sink_inflight` 和 `sink_idle_sem`：关闭 sink 时要等待已经发出的旧回调返回，防止 `user_data` 被释放后仍被访问。

## 十八、generation 不是一个计数器，而是一组生命周期令牌

该模块包含多种 generation：

| generation | 隔离对象 |
|---|---|
| `client_generation` | `audio_server` encoder 实例及其迟到事件 |
| `mode_generation` | 模式切换和采集恢复任务 |
| `playback_generation` | 播放开始、AEC 预热计时器 |
| `confirm_generation` | 降音确认窗口 |
| `cooldown_generation` | 误触发冷却计时器 |
| `tail_guard_generation` | 播放尾音保护计时器 |
| `preroll_generation` | pending 超时与取消操作 |
| `sink_generation` | 云端录音消费者和 PCM 回调 |
| `stream_generation` | 云端播放器、MP3 feed 和终止事件 |

它们解决的是同一类问题：

```text
旧异步操作晚到
→ 先比较它携带的 generation
→ 不属于当前生命周期
→ 直接忽略
```

为什么不能只用一个全局 generation？

因为这些子生命周期并不总是一起变化。例如一次误触发只需要废弃确认计时器，不应该同时让当前播放器和麦克风 sink 失效。分开的 generation 可以更精确地取消旧工作。

计数自增后如果回绕到 0，代码会再自增一次，因为 0 被保留为“没有活动实例”。

## 十九、为什么还要 mutex、generation 和 inflight 三层保护

它们解决不同问题：

```text
mutex
→ 防止多个线程同时读写复合状态

generation
→ 判断异步回调属于旧实例还是当前实例

inflight + semaphore
→ 等待已经进入回调的旧执行路径真正返回
```

只用 mutex 不够：回调可能已经复制出函数指针和 `user_data`，释放锁后才执行。

只用 generation 也不够：它能让回调拒绝新数据，却不能保证旧回调不再访问即将释放的对象。

因此 sink 关闭流程会：

1. 在锁内撤销 `sink_active` 和回调指针；
2. 释放锁；
3. 等待对应 generation 的 inflight 回调归零；
4. 最后允许上层销毁录音器对象。

锁顺序固定为：

```text
sink_mutex → voice mutex
```

统一锁顺序用于避免 ABBA 死锁。

## 二十、VOICE_INTERRUPT 为什么还要经过 FSM 校验

VAD 确认和事件被 `app_core` 消费之间存在时间差。这段时间里可能发生：

- 用户按键已经发起另一种打断；
- 网络断开；
- 播放自然结束；
- FSM 离开 `ENGINE_CHAT`；
- VAD 模式从 `SPEAKING` 切到 `THINKING`；
- 当前候选属于旧模式。

所以事件携带检测时的模式：

```c
PAIPOP_EVT_VOICE_INTERRUPT,
PAIPOP_VOICE_ACTIVITY_SPEAKING
```

FSM 只在以下条件同时满足时接受：

```text
detected_mode != DISABLED
+ fsm.voice_interrupt_mode == detected_mode
+ !exit_request_pending
+ !shake_interrupt_pending
+ state == ENGINE_CHAT
```

不满足时，FSM 不启动新轮，并立即取消 VAD 已经锁定的预录。

这是典型的“生产者初筛、状态机最终仲裁”：VAD 不直接控制对话引擎，避免音频线程绕过业务状态。

## 二十一、FUNC-05-03：确认以后怎样开启下一轮

FSM 接受 `VOICE_INTERRUPT` 后会：

1. 保存旧轮是否已经输出，以及原 VAD 模式；
2. 关闭当前 VAD 模式；
3. 标记 `exit_request_pending`；
4. 打开 `interrupt_phase_gate`；
5. 保留 `interrupt_preroll_ready`；
6. 清除 30 秒无输入窗口；
7. 将眼睛切换为倾听；
8. 调用 `paipop_engine_interrupt_chat()`。

`paipop_engine_interrupt_chat()` 没有先在产品层同步等待 `Paipop_ExitChat()`，而是直接构造新的连续 `CLOUD_VAD` 轮次：

```c
return paipop_engine_start_managed_round(
    0,      /* 不创建新 conversation */
    1,      /* 关闭 welcome audio */
    PAIPOP_CHAT_MODE_CLOUD_VAD,
    0,      /* 保持连续对话 */
    reason);
```

因此：

- `conversationId` 保持不变，保留上下文；
- 新一轮 `turnId` 会重新生成；
- 不播放欢迎音；
- 新录音器打开后直接接管 pending PCM。

底层 LingXinSDK 如何在内部协调旧 task 与新 task 属于第三方实现边界；产品源码能直接证明的是：产品通过 `Paipop_StartNewChat()` 请求同一 conversation 的新轮，并为异步交接准备了旧事件隔离与超时恢复。

## 二十二、新 `STARTING` 为什么可能比旧 `EXIT` 更早

异步系统中不存在“源码调用顺序等于回调到达顺序”。打断后可能出现：

```text
新轮 STARTING
→ 新轮 INPUTING
→ 旧轮 EXIT
```

也可能是：

```text
旧轮 EXIT
→ 新轮 STARTING
→ 新轮 INPUTING
```

如果 FSM 把第一个 `EXIT` 无条件当成当前轮结束，就可能刚建立新录音器又退回空闲。

### `interrupt_phase_gate`

打断开始时打开 phase gate。交接期间到达的旧：

```text
THINKING
OUTPUTING
```

会被忽略，避免旧轮回调重新修改眼睛、VAD 模式和播放状态。

### `interrupt_exit_seen`

如果交接期间先收到符合旧轮语义的 `EXIT`，记录它已经被消费。

### `stale_exit_budget`

如果新轮 `STARTING/INPUTING` 已经先到，而旧 `EXIT` 尚未出现，FSM 在接下来 1500 ms 内允许忽略一次迟到的用户主动退出或无输入退出。

这里使用“预算 1 次”而不是在整个时间窗忽略所有 EXIT，是为了避免把新轮真正发生的异常退出也全部吞掉。

## 二十三、播放器自身也要隔离旧流

开始新轮时，旧 MP3 包和解码器事件也可能晚到。播放器通过 `stream_generation`、`decoder_generation` 和终止所有者处理：

- 新流初始化时生成非零 generation；
- `feed`、解码启动和 decoder event 都检查 generation；
- 硬停止时先关闭 `accepting_feed`；
- 后续迟到 feed 只记录一次并丢弃；
- `PLAY_END` 和 `STOP_END` 竞争时只允许一个终止所有者生效；
- 播放停止通知只发送一次。

这保证旧回答的 MP3 不会写进新回答的环形缓冲，也避免自然播放结束与主动打断同时拆除同一个解码器。

## 二十四、打断失败时怎样恢复

自然打断不是不可逆事务。以下步骤都可能失败：

- 业务事件投递失败；
- 新轮请求返回 busy；
- sink 打开失败；
- 播放恰好自然结束；
- 退出回调迟迟不到；
- audio_server 暂时不可用。

### VAD 事件投递失败

取消预录、清除 `hit_latched`；播放期候选还会恢复原音量。

### 新轮请求在 task 边界返回 busy

FSM 认为这是打断和旧 task 自然结束的竞态，不让设备进入长时间僵死：

- 恢复旧 VAD 模式；
- 恢复被降低的回答音量；
- 取消预录；
- 等待正常连续对话自行进入下一轮。

### 普通交接超时

新轮请求后启动约 1500 ms 看门狗。如果交接仍未完成：

```text
强制快速退出旧会话
→ 标记继续同一 conversation
→ 再等待 4000 ms 恢复窗口
```

如果恢复仍卡死，代码最终执行受控复位。这很激进，但对于无人工维护的玩具，长期卡在半初始化音频状态往往比自动复位更糟。

### 录音服务故障

encoder `ERR/END` 会标记 `encoder_fault`，在仍需要采集时调度最多三次恢复。恢复回调同样通过 mode generation 拒绝过期任务。

## 二十五、参数不是越灵敏越好

正式版平衡默认值包括：

| 参数 | 默认值 | 作用 |
|---|---:|---|
| `speech_ms` | 350 ms | 硬件 VAD 持续时间 |
| `warmup_ms` | 450 ms | 播放开始后的 AEC 预热 |
| `confirm_ms` | 300 ms | 降音复核窗口 |
| `active_pct` | 65% | 确认窗口中有效帧比例 |
| `retain_pct` | 65% | 降音后能量保持比例 |
| `noise_pct` | 260% | 相对噪声底倍率 |
| `headroom` | 32 | 噪声底之上的最小余量 |
| `startup_gate` | 96 | 噪声底未训练时的门限 |
| `cooldown_ms` | 700 ms | 假触发后的冷却 |
| `tail_ms` | 600 ms | 播放停止后的回声尾保护 |
| `duck_pct` | 20% | 复核时的播放音量 |
| `confirm_gate` | 512 | 常规播放期绝对确认门限 |
| `early_ms` | 1000 ms | 播放开头严格窗口 |
| `early_gate` | 1024 | 开头阶段绝对门限 |

### 灵敏参数的代价

降低 `speech_ms`、`warmup_ms`、`confirm_ms` 和各类能量门限：

- 优点：用户更快打断，轻声更容易触发；
- 缺点：回声、碰撞和电视声更容易误触发。

### 稳定参数的代价

提高持续时间、预热和能量门限：

- 优点：误打断减少；
- 缺点：近距离轻声、短词和回答开头的抢话可能漏检。

所以不能只追求“触发率最高”，应该同时统计：

```text
真阳性：用户抢话且成功打断
假阳性：无人说话却打断
假阴性：用户说话但没打断
交接延迟：开口到新 sink ready
语句完整性：ASR 是否丢句首/句尾
```

## 二十六、USB CDC 调参为什么默认只改 RAM

项目支持通过 USB CDC 输入：

```text
tune show
tune stats
tune preset sensitive|balanced|stable
tune set <name> <value>
tune save
tune reset
```

`tune set` 和 preset 默认只修改 RAM。只有显式执行 `tune save` 才写入 VM 区。

这样设计有两个理由：

- 实验错误不会因为重启而永久保留；
- 高频调参不会反复擦写 Flash。

保存记录包含：

```text
magic
schema
length
values
CRC32
```

启动时只有字段全部匹配、CRC 正确且参数范围合法，才恢复保存值；否则回退到平衡默认值。代码还兼容 schema 1，并为新增门限补默认值。

这是一套很典型的嵌入式持久化配置设计：版本化、完整性校验、范围校验和安全默认值缺一不可。

## 二十七、这套设计最值得面试讲的五点

### 1. 单一硬件所有者，多消费者 sink

用一个采集服务统一管理 ADC，LingXin 录音器作为消费者注册，消除了本地 VAD 与云端录音抢硬件的问题。

### 2. 检测质量和识别质量分 profile

播放期使用 16 kHz AEC 保证抗回声，正式云端录音切到原生 24 kHz 保证 ASR 细节，不把一种配置强行用于所有阶段。

### 3. 可逆的降音复核

候选阶段只降低音量，不立即销毁旧播放；确认是假触发时能够恢复未完成回答。

### 4. 预录与消费者 generation 绑定

不仅保存句首，还明确禁止它回流到旧 sink，保证新旧轮次的数据归属。

### 5. 多层异步隔离

子模块 generation、FSM phase gate、一次 stale EXIT 预算和看门狗共同处理乱序回调，而不是假设回调按理想顺序到达。

## 二十八、几个容易被追问的问题

### Q1：自然语音打断是不是唤醒词？

不是。待机时本地检测关闭，用户说话不会启动对话。它只在已经进入云端会话后的思考或播放阶段工作。

### Q2：有了 AEC，为什么还要 VAD 和降音复核？

AEC 只能降低回声，无法保证完全消除，也不能排除电视声、碰撞声和环境人声。VAD 负责持续性候选，动态门限负责环境适应，降音复核进一步判断声音是否随扬声器一起下降。

### Q3：为什么播放刚开始的 450 ms 不允许打断？

AEC 需要参考信号和收敛时间；立即启用容易把启动瞬态和未收敛回声当成近端用户。代价是回答开头存在短暂不可打断窗口。

### Q4：为什么不直接暂停播放再判断？

项目选择数字降音，因为它可逆、对解码器生命周期扰动更小，并继续保持播放参考。暂停/恢复接口虽然存在，但当前确认主路径使用 duck/restore。

### Q5：为什么预录要一秒？

VAD 持续门限和确认窗口本身就会消耗数百毫秒，再加事件与新轮交接。如果没有一秒历史，用户触发词和句首很容易丢失。

### Q6：为什么按键预录只有 450 ms？

物理按键通常先于开口到达，不需要保存整整一秒历史。较短窗口减少静音上传和队列积压。

### Q7：pending 队列为什么丢最老帧？

这是极端溢出时的降级策略。保留最新语音和句尾通常比保留很早的静音更有价值，同时通过 drop 计数暴露问题。

### Q8：为什么本地 VAD 是 16 kHz，云端却要 24 kHz？

杰理 AEC 在 16 kHz profile 下适合抗回声检测；云端 ASR 则使用原生 24 kHz 保留更多语音细节。短暂预录通过 3:2 SRC 衔接格式。

### Q9：`generation` 能代替 mutex 吗？

不能。mutex 保证复合状态的并发一致性；generation 判断异步工作的生命周期；inflight 等待保证旧回调真正退出，三者职责不同。

### Q10：为什么 `VOICE_INTERRUPT` 不直接在音频回调里调用 SDK？

音频服务不应该绕过业务状态机，也不适合执行可能阻塞的 SDK 操作。事件投递把控制权交给 `app_core`，FSM 再结合网络、OTA、当前状态和已有打断做最终决策。

### Q11：为什么旧 `EXIT` 会晚于新 `INPUTING`？

旧 task 清理和新 task 建立是异步流程，回调来自不同工作路径。源码调用顺序不能保证跨线程回调顺序，因此必须显式隔离旧事件。

### Q12：怎么避免把新轮真正的 EXIT 当成旧事件吞掉？

只在限定 1500 ms 时间窗内保留一次 `stale_exit_budget`，而不是忽略全部 EXIT。预算消费后恢复正常处理。

### Q13：降音后用户也停顿了怎么办？

`SPEAK_STOP` 会清除语音连续性，确认窗口到期后候选被拒绝，恢复原音量并进入冷却。短词过短可能因此漏检，这是稳定性和灵敏度的取舍。

### Q14：AEC 不可用时怎么办？

播放期自然打断保持关闭，不在缺少回声抑制时冒险启用；思考期检测和正常云端录音仍可按各自条件工作。

### Q15：怎样验证参数是否合理？

在安静、风扇噪声、电视人声、近讲、远讲、不同音量和机壳姿态下，统计真打断、误打断、漏检、交接延迟、ASR 句首完整性，并结合 `tune stats` 的 candidate/confirmed/rejected、noise、peak 和 drop 计数调整。

### Q16：这套方案最大的限制是什么？

它是单麦克风、能量与 VAD 驱动的工程方案，不能像麦克风阵列那样做可靠方向估计。强外部人声、非常近的扬声器耦合和特殊声学环境仍可能造成误判，需要整机调参验证。

## 二十九、怎样用一分钟讲清楚

> 这个项目的自然语音打断不是检测到声音就停播。我设计了一个统一麦克风服务，避免本地 VAD 和 LingXin 云端录音同时争用 ADC。AI 思考或播放时，服务使用 16 kHz AEC/NLP/ANS profile 做本地检测；新一轮云端录音 sink 打开后切换到原生 24 kHz，保证 ASR 质量。播放真正进入 DAC 后先等待 450 ms AEC 预热，硬件 VAD 命中还要经过动态噪声门限；播放期候选会把回答降到 20%，继续观察 300 ms，只有降音后语音能量和连续性仍满足条件才确认是近端用户。检测期间最近一秒 PCM 和交接期间的新 PCM 都写入 pending 队列，新 sink 获得不同 generation 后先排空历史再发送实时音频。FSM 最终仲裁打断，并用 phase gate、迟到 EXIT 预算和看门狗隔离新旧轮回调。假触发或新轮启动失败时会恢复旧回答和检测状态。

## 三十、源码证据索引

| 结论 | 主要源码位置 |
|---|---|
| 应用启动和停止时初始化/反初始化语音服务 | `app_main.c:100-146` |
| AEC、VAD、24 kHz 录音和 48 kHz DAC 参考配置 | `include/app_config.h:138-179` |
| 语音服务和三个音频端口进入目标构建 | `board/wl82/Makefile:280-303` |
| VAD 模式与共享 sink 公共契约 | `include/paipop_voice_activity.h:7-61` |
| 默认门限、预录与 pending 容量 | `src/services/paipop_voice_activity.c:14-60` |
| 服务状态、各类 generation 和缓冲区 | `src/services/paipop_voice_activity.c:125-254` |
| 调参默认值、范围校验和 VM 恢复 | `src/services/paipop_voice_activity.c:261-350` |
| 双采集 profile 选择 | `src/services/paipop_voice_activity.c:402-422` |
| 预录环形缓冲和 pending 锁定 | `src/services/paipop_voice_activity.c:432-532` |
| pending 超时、外部打断锁定和取消 | `src/services/paipop_voice_activity.c:535-705` |
| pending 优先排空和实时 PCM 路由 | `src/services/paipop_voice_activity.c:904-965` |
| 动态噪声学习与门限公式 | `src/services/paipop_voice_activity.c:967-1045` |
| 16 kHz 到 24 kHz 状态式 SRC | `src/services/paipop_voice_activity.c:1047-1165` |
| 降音确认结果判定 | `src/services/paipop_voice_activity.c:1707-1852` |
| 降音动作与确认计时器建立 | `src/services/paipop_voice_activity.c:1854-1925` |
| 硬件 VAD 事件和候选分流 | `src/services/paipop_voice_activity.c:1927-2138` |
| audio_server 双 profile 打开参数 | `src/services/paipop_voice_activity.c:2215-2391` |
| AEC 预热和真实播放通知 | `src/services/paipop_voice_activity.c:2472-2660` |
| sink generation、打开、关闭和质量统计 | `src/services/paipop_voice_activity.c:2686-2864` |
| pending 内存降级和 PCM worker 创建 | `src/services/paipop_voice_activity.c:2867-2993` |
| 模式切换与旧计时器撤销 | `src/services/paipop_voice_activity.c:2996-3152` |
| USB 调参、显式保存与统计 | `src/services/paipop_voice_activity.c:3155-3421` |
| LingXin 录音器优先接共享 sink | `PaipopSDK/port/jl_ac79/src/paipop_audio_recorder.c:17-29,209-305` |
| 播放器 generation 与物理播放通知顺序 | `PaipopSDK/port/jl_ac79/src/paipop_cloud_audio_play.c:120-198,716-850` |
| 播放硬停止和迟到 feed 拒绝 | `PaipopSDK/port/jl_ac79/src/paipop_cloud_audio_play.c:1194-1350` |
| 降音、恢复和可打断状态检查 | `PaipopSDK/port/jl_ac79/src/paipop_cloud_audio_play.c:1392-1514` |
| FSM 选择 VAD 模式和同步播放状态 | `src/app/paipop_fsm.c:312-432` |
| 自然语音事件的最终仲裁 | `src/app/paipop_fsm.c:877-909,1772-1805` |
| 新旧阶段门控和迟到 EXIT 预算 | `src/app/paipop_fsm.c:359-388,1846-2001` |
| 交接超时、强制退出和受控复位 | `src/app/paipop_fsm.c:1178-1282` |
| 同一 conversation 的新轮请求 | `src/services/paipop_engine_service.c:229-295,606-613` |
| 每轮 conversationId/turnId 参数生成 | `src/services/paipop_engine_service.c:159-255` |

## 总结

Paipop 的自然语音打断可以拆成四层：

```text
声学检测层
硬件 VAD + AEC/NLP/ANS + 动态门限 + 降音复核

音频保存层
1 秒滚动预录 + 最长 4 秒 pending + 16k→24k SRC

异步安全层
mutex + inflight + 多类 generation + 超时回收

业务交接层
VOICE_INTERRUPT 事件 + FSM 仲裁 + phase gate + 同会话新轮
```

最值得记住的是：检测到用户只是开始，真正困难的是在设备自己发声的同时可靠地区分近端语音，并在数百毫秒确认和异步换轮期间不丢掉用户已经说出的内容。

这套方案没有把 AEC 或 VAD 神化成单点答案，而是把多个不完美信号组合起来：硬件 VAD 提供候选，动态门限适应环境，降音复核排除回声，预录队列保护句首，generation 和 FSM 处理乱序生命周期。对于资源有限的单麦克风嵌入式玩具，这是一种可落地、可调试、也能在面试中讲清设计取舍的完整工程方案。
