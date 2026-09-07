---
title: paipopAi对话玩具解析（六）：从开机联网到 AP 网页配网
published: 2026-09-07
updated: 2026-09-07
pinned: false
description: 从 Wi-Fi 回调、VM 历史凭据、DHCP 成功边界、DNS 强制门户、HTTP 配网页面和双键强制切网六条链路，拆解 Paipop 玩具如何完成开机联网、失败回退与网页配网。
tags: [AC791N, Paipop, 嵌入式, WiFi, AP配网, DHCP, 状态机]
category: 嵌入式
series: Paipop AI 对话玩具源码解析
seriesOrder: 7
draft: false
---

# paipopAi对话玩具解析（六）：从开机联网到 AP 网页配网

前五篇已经从应用启动、事件系统、普通语音对话、PaipopSDK 封装，一直讲到 AI 播放期间的自然语音打断。

但所有云端能力都有一个共同前提：设备必须先连上 Wi-Fi，并真正取得可用的网络地址。

对手机和电脑来说，配网通常只是点开系统设置、输入密码；对一台没有键盘、没有触摸屏、只有两个按键和两块小 LCD 的嵌入式玩具来说，问题要复杂得多：

- 上电后应该连接哪个历史网络？
- “连接上路由器”和“已经能访问云端”是不是同一时刻？
- 历史网络失效后，设备怎样让手机把新密码交给它？
- 手机为什么有时会自动弹出配网页面？
- 怎样避免把历史 Wi-Fi 密码回显到网页？
- 用户在对话过程中强制配网时，迟到的连接成功、断开和超时事件会不会把状态机带回旧流程？
- 配网失败后，为什么设备能重新开放热点，而不是卡死在半连接状态？

这篇沿着三种真实场景，把完整链路拆开：

1. 上电后使用最近一次成功的凭据自动联网；
2. 自动联网失败后进入 AP 网页配网；
3. 运行中双键长按，主动中止当前流程并重新配网。

先用一句话概括：

> Paipop 把杰理 Wi-Fi 驱动当作异步执行层，把 `paipop_wifi_provision` 当作联网策略层，再把连接结果转换成系统网络事件交给产品 FSM；设备只有在 DHCP 成功后才认为网络可用并保存凭据，自动连接失败则通过本地 AP、通配 DNS 和简化 HTTP 服务接收新配置，双键强制配网还用 `force_ap_pending` 隔离旧连接产生的迟到事件。

## 阅读导航

1. [杰理 AC79 应用启动与注册机制详解：从 `REGISTER_APPLICATION` 到 `start_app`](/posts/杰理ac79应用启动与注册机制详解/)
2. [paipopAi 对话玩具解析（一）：从 `APP_STA_START` 到眼睛任务与摇一摇服务](/posts/paipopai对话玩具解析一从应用启动到眼睛与摇一摇/)
3. [paipopAi 对话玩具解析（二）：从按键与摇一摇到对话打断](/posts/paipopai对话玩具解析二从按键与摇一摇到对话打断/)
4. [paipopAi 对话玩具解析（三）：从按键启动到云端语音回答](/posts/paipopai对话玩具解析三从按键启动到云端语音回答/)
5. [paipopAi 对话玩具解析（四）：PaipopSDK 如何封装 LingXinSDK](/posts/paipopai对话玩具解析四paipopsdk如何封装lingxinsdk/)
6. [paipopAi 对话玩具解析（五）：AI 播放时如何实现自然语音打断](/posts/paipopai对话玩具解析五ai播放时如何实现自然语音打断/)
7. **本文**：从开机自动联网、失败回退到 AP 网页配网。

## 本文范围与证据边界

本文基于独立正式发布仓库 `Paipop_YP_Toy_release_v128` 的 `main@24a83f9`，产品版本为 `V1.2.8 / 10208`，目标平台为杰理 AC791N/WL82。

本次采用静态源码复核，没有重新烧录设备，也没有采集新的路由器报文或串口日志。因此需要区分以下证据强度：

| 结论 | 可信度 | 依据 |
|---|---|---|
| Wi-Fi 服务、事件层和产品 FSM 的调用关系 | 已验证 | 正式版源码中的直接调用与回调注册 |
| `paipop_wifi_provision.c` 被当前目标编译 | 已验证 | `board/wl82/Makefile` 的源文件列表 |
| 最多保存 6 组历史网络、启动只尝试最近一组 | 已验证 | 常量、杰理公开接口调用和当前选择逻辑 |
| DHCP 成功后才保存凭据并通知业务层 | 已验证 | Wi-Fi 事件回调的直接分支 |
| Android、iOS、Windows 一定自动弹窗 | 未证明 | 设备覆盖常见探测路径，但最终行为由手机系统决定 |
| 开放 AP 和明文 HTTP 满足量产安全要求 | 未证明 | 当前实现是事实，但安全要求取决于产品威胁模型 |

本文涉及的代码归属如下：

| 组件 ID | 组件 | 归属与职责 |
|---|---|---|
| `COMP-01` | `paipop_wifi_provision.c` | Paipop 第一方：凭据策略、AP/STA 切换、DNS 与 HTTP 配网服务 |
| `COMP-02` | `paipop_events.c` | Paipop 第一方：网络事件翻译、双键强制配网入口 |
| `COMP-03` | `paipop_fsm.c` | Paipop 第一方：产品状态迁移、提示音门控和断网清理 |
| `COMP-04` | `paipop_tone.c` | Paipop 第一方：配网成功、失败和进入配网提示音 |
| `COMP-05` | Wi-Fi/VM/DHCP/LwIP 接口 | 杰理 SDK：本文追到公开头文件和回调边界 |
| `COMP-06` | 手机的联网探测与浏览器 | 外部客户端：只说明设备响应，不假设具体系统一定弹窗 |

## 一、先建立全局图：联网不是一个函数，而是一组异步协作

如果只看应用启动代码，联网似乎只有一行：

```c
paipop_wifi_provision_start();
```

但这行代码并不会同步完成“扫描、关联、DHCP、连接云端”全部工作。它只做三件事：

1. 清空 Wi-Fi 策略层上下文；
2. 向杰理 Wi-Fi 模块注册事件回调；
3. 如果 Wi-Fi 尚未开启，则调用 `wifi_on()`。

后续流程由 Wi-Fi 模块异步回调驱动：

```text
APP_STA_START
    │
    └─ paipop_wifi_provision_start()
           │
           ├─ wifi_set_event_callback(callback)
           └─ wifi_on()
                  │
                  ├─ WIFI_EVENT_MODULE_INIT
                  ├─ WIFI_EVENT_MODULE_START
                  ├─ WIFI_EVENT_STA_START / AP_START
                  ├─ WIFI_EVENT_STA_CONNECT_SUCC
                  └─ WIFI_EVENT_STA_NETWORK_STACK_DHCP_SUCC
```

Wi-Fi 回调再把产品真正关心的结果投递给杰理系统事件框架：

```text
杰理 Wi-Fi 回调
→ paipop_apcfg_notify_net()
→ net_event_notify()
→ SYS_NET_EVENT
→ paipop_toy_event_handler()
→ paipop_events_handle_sys_event()
→ paipop_events_handle_net()
→ paipop_fsm_dispatch()
```

这条链中存在一次明确的异步边界：Wi-Fi 回调只报告结果，产品状态迁移最终在应用事件路径中完成。

这样做的意义是，底层 Wi-Fi 模块不需要知道“闭眼、播放提示音、退出语音会话、初始化 PaipopSDK”等产品规则。

## 二、项目里其实有两个状态机

阅读这部分源码时，最容易犯的错误是把 `PAIPOP_APCFG_*` 和 `PAIPOP_TOY_STATE_*` 当成同一套状态。

它们回答的是不同问题。

### Wi-Fi 策略层状态

`paipop_wifi_provision.c` 内部有一套局部状态：

```c
enum paipop_apcfg_state {
    PAIPOP_APCFG_IDLE = 0,
    PAIPOP_APCFG_AP,
    PAIPOP_APCFG_STA_CONNECTING,
    PAIPOP_APCFG_STA_READY,
};
```

它描述的是无线链路当前处于什么阶段：

- `IDLE`：没有稳定的 AP 或 STA 结果；
- `AP`：设备正在作为热点；
- `STA_CONNECTING`：正在连接路由器；
- `STA_READY`：已经通过 DHCP 取得网络配置。

### 产品 FSM 状态

`paipop_fsm.c` 则维护玩具业务状态：

```text
VM_CONFIG
AP_CONFIG
ENGINE_INIT
ENGINE_INIT_FAILED
ENGINE_CHAT
ENGINE_EXIT
```

它描述的是产品此刻应该允许什么交互：

- 是在尝试历史网络；
- 还是等待用户配网；
- 是在初始化语音引擎；
- 还是已经可以聊天。

两者的对应关系不是严格一一映射。例如提示音播放期间，Wi-Fi 底层可能已经开始切换模式，而产品 FSM 仍停留在旧状态，等待 `PAIPOP_EVT_TONE_DONE` 后再完成业务迁移。

面试时可以这样概括：

> Wi-Fi 局部状态机管理链路执行细节，产品 FSM 管理用户可感知的业务流程。局部状态不能越过产品 FSM 直接决定眼睛、提示音和语音引擎生命周期。

## 三、应用启动后，为什么先进入 `VM_CONFIG`

`paipop_fsm_init()` 把产品初始状态设置成：

```c
fsm.state = PAIPOP_TOY_STATE_VM_CONFIG;
```

这里的 VM 指杰理 SDK 用于保存 Wi-Fi 模式和凭据的非易失存储机制。它不表示虚拟机，也不代表设备一定已经有可用凭据。

应用启动顺序中，FSM 先初始化，随后才启动 Wi-Fi：

```text
paipop_fsm_init()
→ 初始状态 VM_CONFIG

paipop_wifi_provision_start()
→ 注册 Wi-Fi 回调
→ wifi_on()
```

因此产品从一开始就处于“等待历史网络结果”的业务状态。底层之后报告成功、失败或没有历史凭据，事件层才能把它转换成对应 FSM 事件。

## 四、为什么能保存 6 组，却只自动连接 1 组

当前常量是：

```c
#define PAIPOP_APCFG_VM_MAX_STA 6
```

Wi-Fi 初始化时还会调用：

```c
wifi_set_store_ssid_cnt(PAIPOP_APCFG_VM_MAX_STA);
```

这表示杰理原生 Wi-Fi VM 最多保留 6 组不同 STA 凭据。

但“能保存 6 组”和“启动时自动尝试 6 组”是两回事。

启动路径调用 `paipop_apcfg_load_last_vm_sta()`，而该函数只把最近一次成功凭据复制到：

```c
apcfg.vm_sta[0]
```

随后明确设置：

```c
apcfg.vm_sta_count = 1;
apcfg.vm_sta_index = 0;
```

因此自动连接策略是：

```text
读取最近一次成功网络
→ 最多尝试这一组
→ 成功则继续
→ 失败则进入 AP 配网
```

其余最多 5 组历史记录并没有丢失，它们只用于配网页面中的人工选择。

这是当前 V1.2.8 的明确产品取舍。早期版本曾经尝试扫描和遍历多个历史网络，但当前实现删除了这条复杂路径，以减少扫描阻塞、重复重连和异步事件竞态。

优点是状态简单、失败时间可预测；缺点是用户换到另一个曾连接过的地点时，设备不会自动尝试更早记录，需要主动进入配网页面选择。

## 五、`WIFI_EVENT_MODULE_INIT` 决定第一次启动模式

Wi-Fi 模块初始化完成后，回调处理 `WIFI_EVENT_MODULE_INIT`。

这一分支先完成公共参数设置：

```text
最多保存 6 组 SSID
STA 连接超时 20 秒
根据 MAC 生成设备 AP 名称
刷新历史记录缓存
```

随后分成两条路径。

### 存在历史凭据

代码把最近一组凭据填入 `wifi_store_info`，设置：

```c
default_info.mode = STA_MODE;
default_info.connect_best_network = 0;
```

然后把局部状态置为 `STA_CONNECTING`。

`connect_best_network = 0` 与 `wifi_set_sta_connect_best_ssid(0)` 的目标一致：不要让 SDK 自己从多个记录里挑信号最强的网络，而是严格连接产品选定的最近一组。

### 不存在历史凭据

代码把默认模式设置成 AP：

```c
default_info.mode = AP_MODE;
```

同时配置本地 LAN，并发布自定义事件：

```c
PAIPOP_NET_EVENT_AP_CONFIG
```

事件层看到产品仍处于 `VM_CONFIG`，会把它翻译成：

```c
PAIPOP_EVT_VM_ALL_FAILED
```

FSM 先播放“进入配网”提示音，再进入 `AP_CONFIG`。

这里有一个细节：没有历史凭据时，Wi-Fi 默认模式已经被设置为 AP，因此物理热点可能在产品提示音完成前开始启动；提示音门控的是产品 FSM 迁移，而不是保证射频模式直到提示音结束才变化。

## 六、为什么“关联成功”还不能算真正联网

连接路由器至少可以拆成两个重要阶段：

```text
STA 关联成功
→ WIFI_EVENT_STA_CONNECT_SUCC

DHCP 成功
→ WIFI_EVENT_STA_NETWORK_STACK_DHCP_SUCC
```

`STA_CONNECT_SUCC` 只能证明设备已经完成 802.11 关联。此时设备未必已经取得 IP、网关和 DNS 配置，也就未必能访问云端。

当前代码在 `WIFI_EVENT_STA_CONNECT_SUCC` 中只记录信道，不通知产品联网成功。

真正的成功边界放在 DHCP 成功事件：

```c
apcfg.state = PAIPOP_APCFG_STA_READY;
paipop_apcfg_store_sta_if_needed();
paipop_apcfg_notify_net(NET_EVENT_CONNECTED);
paipop_ota_network_ready();
```

也就是说，以下三件事发生在同一业务边界之后：

1. 允许保存本次成功凭据；
2. 通知产品 FSM 网络已连接；
3. 通知 OTA 模块网络已就绪。

这是很重要的工程原则：

> 不要把链路层关联成功当作应用层网络可用。至少要等 DHCP 成功；更严格的产品还可以增加 DNS、网关或服务端探活。

当前项目验证到 DHCP 边界，没有在这里额外访问云端健康检查接口。

## 七、为什么新密码必须等 DHCP 成功后再写入 VM

网页提交新的 SSID 和密码后，代码不会立即调用 `wifi_store_mode_info()`。

它只做：

```c
apcfg.pending_save = 1;
wifi_enter_sta_mode(apcfg.pending_ssid, apcfg.pending_pwd);
```

只有后续收到 DHCP 成功事件，`paipop_apcfg_store_sta_if_needed()` 才真正保存。

如果提交后立即保存，会产生一个典型故障：

```text
用户输错密码
→ 错误凭据被写成“最近成功网络”
→ 本次连接失败
→ 设备重启后再次自动尝试错误凭据
→ 用户持续陷入失败流程
```

延迟保存把“用户提交”与“凭据验证通过”分开：

```text
提交只是候选
DHCP 成功才转正
```

这种 pending/commit 两阶段思路也常见于配置文件替换、OTA 元数据和数据库事务。

## 八、MRU 历史记录是怎样维护的

MRU 即 Most Recently Used，最近使用的记录排在前面。

当前保存函数先删除同名 SSID，再重新写入：

```c
wifi_del_stored_sta_info((char *)ssid);
wifi_store_mode_info(STA_MODE, (char *)ssid, (char *)pwd);
```

这样做解决两个问题：

- 相同 SSID 更换密码时，不会生成重复项；
- 再次成功使用某个旧网络时，可以把它更新为最近记录。

读取全部历史时，`paipop_apcfg_load_stored_sta_list()` 还会：

1. 限制最多读取 6 条；
2. 丢弃空 SSID；
3. 按 SSID 去重；
4. 必要时回退到“最后记忆模式”接口；
5. 调用 `paipop_apcfg_order_sta_mru()` 统一成最近优先顺序。

`order_sta_mru()` 处理了杰理接口可能返回“旧到新”或最近记录位于中间的情况：如果最近记录在数组末尾，就整体反转；如果位于其他位置，就把它移动到首位并保持其余记录的相对顺序。

这里需要谨慎表述：源码可以验证项目怎样归一化和重新保存，底层 VM 具体采用什么擦写、磨损均衡和掉电保护策略，则位于杰理 SDK 内部边界，本文不做推断。

## 九、自动联网失败如何进入产品事件系统

以下失败都会被 Wi-Fi 回调接收：

- 找不到目标 SSID；
- 关联失败；
- 关联超时；
- DHCP 超时；
- 强制模式超时。

回调不会直接播放声音或操作眼睛，而是调用：

```c
paipop_apcfg_sta_fail_to_ap(reason, net_event);
```

该函数清理自动连接候选，把局部状态退回 `IDLE`，再通过 `paipop_apcfg_notify_failure_once()` 发布网络事件。

事件经过 `SYS_NET_EVENT` 到达 `paipop_events_handle_net()` 后，会依据产品当前状态二次翻译：

| 产品状态 | 失败事件被翻译为 | 含义 |
|---|---|---|
| `VM_CONFIG` 或其他非 AP 配网状态 | `PAIPOP_EVT_VM_ALL_FAILED` | 自动联网失败，应进入配网 |
| `AP_CONFIG` | `PAIPOP_EVT_AP_CONNECT_FAILED` | 用户刚提交的网络失败，应回到 AP |

同一个底层失败在不同业务阶段含义不同，这就是为什么事件层必须读取 FSM 当前状态，而不能把错误码机械地一一映射。

## 十、为什么需要 `failure_notified`

一次真实连接失败可能伴随多个底层事件，例如先出现关联失败，随后又出现强制模式超时。

如果每个事件都向产品层上报，可能发生：

```text
第一次失败
→ 播放配网提示

第二次迟到失败
→ 再次清 pending
→ 重复播放或重复切换 AP
```

因此代码用：

```c
u8 failure_notified;
```

保证一个连接尝试只上报一次失败。新的连接尝试开始或 DHCP 成功后，再把它清零。

这不是消灭底层重复事件，而是在策略层建立幂等边界。

## 十一、为什么提示音结束后才迁移状态

自动连接失败后，产品不是立即切入 `AP_CONFIG`，而是调用：

```c
paipop_fsm_play_then_transition(
    PAIPOP_TONE_NET_CONFIG,
    PAIPOP_TOY_STATE_AP_CONFIG,
    PAIPOP_EVT_VM_ALL_FAILED);
```

该函数先把目标状态记录到：

```c
fsm.pending_after_tone
```

然后播放 `NetCfgStart.mp3`。

音频结束后，`paipop_tone.c` 发布 `PAIPOP_EVT_TONE_DONE`；FSM 取走 pending 目标并完成迁移：

```text
VM_ALL_FAILED
→ pending_after_tone = AP_CONFIG
→ 播放 NetCfgStart.mp3
→ AUDIO_SERVER_EVENT_END
→ PAIPOP_EVT_TONE_DONE
→ take_pending()
→ transition(AP_CONFIG)
```

如果提示音文件打不开或播放器启动失败，代码会清掉 pending 并直接迁移，保证用户不会因为提示音资源损坏而永远无法配网。

这体现了一个可靠性原则：提示音是用户体验步骤，不应成为核心状态迁移的单点故障。

## 十二、AP 热点是怎样生成的

进入 AP 模式时，SSID 前缀固定为：

```text
JL_AI_TOY_
```

后缀取设备 MAC 地址的最后两个字节，形成类似：

```text
JL_AI_TOY_ABCD
```

这样同一环境里多台设备不至于全部重名。

当前 AP 密码为空：

```c
#define PAIPOP_APCFG_AP_PWD ""
```

局域网固定配置为：

```text
设备地址：192.168.1.1
子网掩码：255.255.255.0
网关：192.168.1.1
首个客户端地址：192.168.1.2
DNS：192.168.1.1
```

设备通过 DHCP Server 告诉手机：“DNS 服务器也是 192.168.1.1”。这是后续强制门户能够工作的基础。

## 十三、手机为什么可能自动弹出配网页面

手机连接一个 Wi-Fi 后，系统通常会访问自己的联网探测地址，例如：

```text
/generate_204
/gen_204
/hotspot-detect.html
/library/test/success.html
/connecttest.txt
/ncsi.txt
/redirect
```

如果收到预期的互联网响应，系统认为该 Wi-Fi 可以正常上网；如果被重定向或收到登录页面，系统可能弹出强制门户窗口。

Paipop 在 AP 模式下做了两层拦截：

```text
任意域名 DNS 查询
→ 解析到 192.168.1.1

常见联网探测 HTTP 请求
→ 直接返回 Paipop 配网页面
```

其他普通 GET/HEAD 请求则返回：

```http
HTTP/1.1 302 Found
Location: http://192.168.1.1/
```

因此无论系统探测哪个常见域名，最终都有机会访问玩具本地页面。

但必须强调：

> 设备只能尽量满足常见强制门户协议，是否自动弹窗由 Android、iOS、Windows 的版本、缓存和安全策略决定。手动访问 `http://192.168.1.1` 才是确定的备用入口。

## 十四、通配 DNS 服务具体做了什么

`paipop_apcfg_dns_task()` 创建一个 UDP socket，绑定本地 53 端口。

收到 DNS 包后，`paipop_apcfg_dns_build_response()` 只处理一个问题，并验证域名标签长度和报文边界。

对于 IN 类的 A 或 ANY 查询，它返回：

```text
Answer = 192.168.1.1
TTL = 30 秒
```

对于其他查询类型，则返回“成功但没有答案”，让客户端有机会回退到 IPv4 A 查询。

这不是完整的通用 DNS 服务器，而是一个针对强制门户的最小实现。它没有递归查询公网 DNS，也不需要知道请求的真实域名。

DNS 任务使用独立线程 `paipop_ap_dns`；停止时先把 `dns_running` 清零，再让 socket 退出阻塞，最后 `thread_kill(..., KILL_WAIT)` 等待线程结束。

## 十五、HTTP 配网服务为什么设计得很小

`paipop_apcfg_http_task()` 创建 TCP 监听 socket：

```text
地址：0.0.0.0
端口：80
listen backlog：1
单次请求缓冲：1460 字节
```

它串行接受连接，每次只读取一块请求并处理以下路径：

| 请求 | 响应 |
|---|---|
| `GET /` | 返回配网页面 |
| 常见 captive probe | 返回配网页面 |
| `GET /config?...` | 解析配置并尝试联网 |
| `POST /config` | 解析配置并尝试联网 |
| 其他 GET/HEAD | 302 跳转到 `192.168.1.1` |
| 其他方法 | 404 |

这种实现资源占用小、依赖少，适合 MCU 临时配网页面；它不是高并发、完整兼容 HTTP/1.1 的 Web 服务器。

由此也能看出边界：代码一次 `sock_recv()` 就尝试解析完整请求，没有实现分片 body 累积、chunked encoding 或长连接。因此页面表单很小且由本机生成时通常够用，但复杂客户端或网络分片场景需要专项验证。

## 十六、8 KiB 动态页面为什么还有降级版本

带历史网络列表的页面使用：

```c
calloc(1, 8192)
```

动态拼接 HTML。

嵌入式设备可能因为堆碎片或瞬时内存不足导致分配失败，也可能因为异常 SSID 造成页面拼接空间不足。因此代码准备了一个不包含历史下拉框的静态手动输入页面。

```text
动态页面分配成功
→ 展示历史 Wi-Fi + 手动输入

动态页面分配失败或溢出
→ 返回静态手动输入页面
```

这是一种功能降级策略：历史选择是增强功能，手动输入才是配网核心能力。

## 十七、为什么历史 SSID 要做 HTML 转义

SSID 是外部输入，可能包含：

```text
&  <  >  "  '
```

如果直接拼进 `<option>`，轻则页面结构损坏，重则产生本地 HTML 注入。

`paipop_apcfg_html_escape()` 会把这些字符转换为实体，同时把控制字符转换成数字实体。

这说明即使页面只运行在设备本地热点中，也不能把路由器广播的 SSID 当成可信字符串。

代码还给转义后的单个 SSID 预留 225 字节，避免原始字符串经过实体扩展后写越界。

## 十八、历史密码为什么不会进入网页

历史页面只输出 SSID 和数组索引：

```html
<option value="0">HomeWiFi</option>
```

不会把密码写进 HTML、JavaScript、HTTP 响应或普通日志。

当用户选择历史网络时，表单提交：

```text
history = 0..5
snapshot = 当前历史快照编号
```

设备端再根据索引从 `apcfg.history_sta[]` 读取内部密码。

这比把密码放进隐藏 input 安全得多，因为隐藏字段依然会被浏览器看到并通过网络传输。

手动输入新网络时：

```text
history = -1
ssid = 用户输入
password = 用户输入
```

两种模式复用同一个 `/config` 处理入口。

## 十九、`history_snapshot` 防的是什么问题

只提交历史数组索引还不够安全。

假设用户打开页面时：

```text
index 0 = Home
index 1 = Office
```

随后设备刷新历史顺序，可能变成：

```text
index 0 = Office
index 1 = Home
```

如果旧页面此时提交 `history=0`，设备就会连接错误网络。

因此每次刷新历史缓存，代码都会增加：

```c
apcfg.history_snapshot
```

页面同时提交 index 和 snapshot。服务端只有在以下条件全部满足时才接受：

- snapshot 与当前缓存一致；
- index 没有越界；
- 对应 SSID 非空。

否则返回 HTTP 400：

```text
history selection is invalid or expired
```

这相当于给数组索引附加一个轻量版本号，避免陈旧 UI 引用已经改变的后端状态。

## 二十、收到表单后为什么先响应，再切 Wi-Fi

解析成功后，HTTP 任务先保存候选配置并向手机返回“已收到 Wi-Fi 信息”的页面。

关闭客户端连接之后，任务才延迟少量 OS tick 并执行 STA 切换。

如果先关闭 AP 或立即切到 STA，手机到玩具的连接会被断开，HTTP 成功页面可能来不及完整发送，用户只会看到浏览器报错。

所以顺序是：

```text
接收并校验表单
→ 复制到 pending_ssid/pending_pwd
→ 返回 HTTP 200
→ 关闭客户端与监听服务
→ 短暂让出执行时间
→ 停止 captive DNS
→ 切换到目标 STA
```

源码使用 `os_time_dly(20)`；其精确墙上时间取决于系统 tick 配置，不能仅凭参数 20 就断言一定是 20 ms 或 200 ms。

## 二十一、为什么切换 STA 前还要修改 `default_info`

网页提交新网络后，代码不只是调用：

```c
wifi_enter_sta_mode(new_ssid, new_pwd);
```

它还先构造 `wifi_store_info`，把内存中的强制默认 STA 改成新 SSID，再调用 `wifi_set_default_mode()`。

源码注释给出了原因：杰理 Wi-Fi 驱动可能仍在重试开机时的默认 SSID。如果只调用切换接口，第一次扫描过程中旧默认网络可能重新取得控制权。

因此当前顺序是：

```text
关闭 DNS
→ 清除旧自动连接候选
→ 禁止 best-SSID 策略
→ 清空扫描结果
→ 把内存默认 STA 指向新凭据
→ wifi_enter_sta_mode(new)
```

这是一个典型的异步驱动竞态修复：不能只发“连接新网络”命令，还要清理旧策略可能留下的控制输入。

## 二十二、配网失败后怎样回到 AP

用户提交的新网络如果找不到、密码错误或 DHCP 失败，Wi-Fi 层发布连接失败事件。

此时产品已经处于 `AP_CONFIG`，所以事件层把错误翻译为：

```c
PAIPOP_EVT_AP_CONNECT_FAILED
```

FSM 的处理是：

```text
播放 NetCfgFail.mp3
→ 调用 paipop_wifi_provision_enter_ap()
→ 清空失败的 pending 凭据
→ 刷新历史缓存
→ 重设 AP 默认模式
→ wifi_enter_ap_mode()
→ AP_START 后重启 DNS 与 HTTP
```

这里的失败提示音使用 `notify_done=0`，也就是不等待提示音结束才恢复 AP。它告诉用户本次配置失败，但不会把恢复配网能力依赖在提示音完成事件上。

## 二十三、运行时断网会清理哪些业务状态

设备已经取得 DHCP 后，如果收到 `WIFI_EVENT_STA_DISCONNECT`，Wi-Fi 服务会：

1. 通知 OTA 网络已断开；
2. 把局部状态从 `STA_READY` 退回 `IDLE`；
3. 发布 `NET_EVENT_DISCONNECTED`。

事件进入 FSM 后，清理范围很广：

- 取消按住说话状态；
- 清除初始化期间锁存的点击；
- 清除按键打断提示；
- 清除摇一摇打断；
- 清除旧轮重启请求；
- 清除 30 秒无输入窗口；
- 取消预录 PCM；
- 清空提示音后的 pending 状态；
- 停止当前提示音；
- 如果正在聊天，请求退出当前对话。

随后产品进入 `VM_CONFIG`，重新读取最近一次成功凭据并尝试连接。

这说明断网不是单纯把一个 `connected` 布尔值改为 0，而是一次跨音频、会话、提示音和 OTA 的资源收敛过程。

## 二十四、为什么 `AP_CONFIG` 收到断网不能回 `VM_CONFIG`

状态迁移校验明确规定：

```c
target == VM_CONFIG
```

时，当前状态不能是 `AP_CONFIG`。

原因是 AP 配网本身就会经历模式切换、手机离开热点、STA 连接失败等网络变化。如果每次 `NET_DISCONNECTED` 都把产品切回 VM 自动连接，就可能形成振荡：

```text
AP 配网
→ 模式切换产生断网
→ 回 VM
→ 最近凭据失败
→ 再回 AP
→ 再产生断网
```

所以 AP 状态收到断网时只做：

```text
清 pending
→ 停提示音
→ 闭眼
→ 重新进入 AP
```

产品状态仍保持 `AP_CONFIG`。

这是一条业务硬约束：

> AP 配网只能因真正获得 DHCP 成功而离开，不能被普通断网事件带回自动连接流程。

## 二十五、双键长按怎样触发主动配网

K1、K2 是低电平有效 GPIO。事件服务每 20 ms 在 `app_core` 任务中读取一次两个引脚。

双键同时保持约 3 秒后：

```text
combo_key.fired = 1
→ 设置两个按键的 click 抑制掩码
→ paipop_events_post(PAIPOP_EVT_FORCE_AP_CONFIG)
```

释放按键后，普通点击抑制最多保留 500 ms，避免一次“双键长按”又被解释成两个普通点击，从而误启动语音对话。

如果单键长按正在进行麦克风回环测试，第二个键按下后会先取消回环，因为手势已经从“单键测试”升级成“双键配网”。

OTA 忙时，组合键计时会被清零，主动配网不会触发，避免升级写入期间切换网络。

## 二十六、`force_ap_pending` 怎样隔离迟到事件

主动配网可以从任意业务阶段发生，包括：

- 正在连接旧 Wi-Fi；
- 正在初始化语音引擎；
- 正在录音或播放 AI 回答；
- 正处于空闲等待。

FSM 收到 `PAIPOP_EVT_FORCE_AP_CONFIG` 后，第一步不是立即调用 `wifi_enter_ap_mode()`，而是：

```c
paipop_wifi_provision_prepare_force_ap();
```

该函数设置：

```c
apcfg.force_ap_pending = 1;
```

并清除旧 STA 候选与待保存凭据。

之后 FSM 清理对话相关状态，必要时请求退出当前聊天，播放进入配网提示音；提示音结束后才真正迁移到 `AP_CONFIG` 并切 AP。

为什么不先切 AP？因为 STA 切 AP 会产生断网事件，而普通断网处理会停止当前提示音并转入 VM 流程。

`force_ap_pending` 建立了一段保护期：

```text
用户已经决定强制配网
→ 旧 STA 的成功、失败、DHCP、断开事件陆续到达
→ Wi-Fi 回调和事件层检查 force_ap_pending
→ 忽略与新意图冲突的旧事件
→ AP_START 后清除保护标志
```

这与第五篇中的 generation、phase gate 思想相同：异步系统无法阻止旧事件已经在路上，只能给新流程建立身份或意图门禁。

## 二十七、网络事件为什么还会取消麦克风回环

`paipop_events_handle_net()` 在处理任何网络状态变化前都会：

```c
paipop_mic_loopback_cancel();
paipop_mic_loopback_stop_playback();
```

麦克风回环是本地测试模式，会占用录音或播放资源。网络变化可能启动语音引擎、提示音、配网流程或会话清理，如果保留回环就可能与这些音频资源冲突。

因此网络事件不仅改变 Wi-Fi 状态，也被当成“退出诊断音频模式”的统一边界。

## 二十八、DNS、HTTP、Wi-Fi 回调分别运行在哪里

这条链并不是单线程顺序执行：

| 执行上下文 | 主要工作 |
|---|---|
| 杰理 Wi-Fi 内部任务/回调 | 报告模块、STA、AP、关联和 DHCP 事件 |
| `paipop_ap_dns` | UDP 53 端口的强制门户 DNS |
| `paipop_ap_http` | TCP 80 端口的页面与表单处理 |
| `sys_event` / `app_core` 路径 | 把网络结果翻译成产品事件并驱动 FSM |
| `audio_server` 回调到 `app_core` | 提示音结束后完成 pending 状态迁移 |

共享的 `apcfg` 结构同时保存状态、socket、线程 PID、历史缓存和候选密码。

当前代码没有为整个 `apcfg` 增加统一 mutex，而是主要依赖以下时序约束：

- 刷新历史前先停止 HTTP/DNS；
- HTTP 接受配置后自行退出监听循环；
- 停止线程时让 socket 退出阻塞并等待线程结束；
- `force_ap_pending` 屏蔽切换期旧回调；
- `failure_notified` 保证失败上报幂等。

这种实现节省同步开销，但维护时必须小心新增跨线程读写。如果以后让网页支持刷新、并发请求或后台扫描历史网络，就应重新审查共享字段的同步和对象生命周期。

## 二十九、当前实现的安全边界与不足

这一部分面试时不能回避。

### 已经做的保护

- 普通日志只打印脱敏 SSID，不打印密码；
- 历史密码不进入 HTML 和 HTTP 响应；
- SSID 输出前进行 HTML 转义；
- 历史索引带 snapshot，拒绝陈旧选择；
- 缓冲区复制普遍保留结尾 `\0`；
- 局部密码数组使用后会清零；
- 新凭据只有 DHCP 成功后才写入 VM。

### 仍然存在的产品安全边界

当前 AP 是开放热点，配网页面使用明文 HTTP。任何处于无线覆盖范围、能连接该热点的客户端，都可能观察或提交配网流量。

页面自身使用 POST，但服务端为了兼容还接受 GET `/config?...`。若使用 GET 传密码，参数还可能进入浏览器历史或中间日志，因此正式产品应优先只允许 POST。

此外，当前实现没有看到以下能力：

- AP 一次性随机密码或设备侧确认；
- HTTPS 或应用层加密；
- 配网会话 token；
- 请求频率限制；
- 配网超时自动关闭；
- 删除单条或清空全部历史凭据的用户界面。

因此准确说法是：

> 当前方案适合用户近距离、可信环境下的低成本局域网配网；如果量产威胁模型要求抵抗邻近攻击者，需要增加设备身份确认、临时密钥、加密提交和会话超时。

这不是否定当前实现，而是明确成本、体验和安全之间的取舍。

## 三十、当前实现还有哪些工程限制

### 只支持手动 SSID 或历史选择

配网页面没有主动扫描周围网络列表。这样代码简单、RAM 和射频状态更可控，但用户必须准确输入新 SSID。

### HTTP 请求只读取一次

1460 字节缓冲适合当前小表单，但没有通用 HTTP 分片重组。特殊字符很多、请求头过长或 TCP 分片时，需要实机兼容性测试。

### 没有服务可达性探活

DHCP 成功就通知网络就绪。路由器可能没有互联网、DNS 可能不可用、云端也可能故障；这些问题留给后续 PaipopSDK/WebSocket 初始化和错误提示处理。

### AP 自动弹窗无法保证

设备覆盖了常见路径，但手机系统可能因缓存、蜂窝网络并行、HTTPS 探测或厂商策略不弹窗。

### 同步初始化仍可能占用应用路径

网络成功提示音结束后，FSM 同步调用 `paipop_engine_chat_init()`。如果 SDK 初始化耗时较长，`app_core` 的其他产品事件可能受到影响。这个问题属于网络成功后的引擎初始化边界，而不是 Wi-Fi 驱动本身。

## 三十一、三条完整调用链

### `FLOW-01`：历史网络自动连接成功

```text
APP_STA_START
→ paipop_fsm_init(): state = VM_CONFIG
→ paipop_wifi_provision_start()
→ wifi_set_event_callback()
→ wifi_on()
→ [callback] WIFI_EVENT_MODULE_INIT
→ 读取最近成功 STA
→ wifi_set_default_mode(STA, force=1, store=0)
→ [callback] WIFI_EVENT_STA_START
→ [callback] WIFI_EVENT_STA_CONNECT_SUCC
→ [callback] WIFI_EVENT_STA_NETWORK_STACK_DHCP_SUCC
→ 保存/置顶成功凭据
→ net_event_notify(NET_EVENT_CONNECTED)
→ [系统事件队列]
→ paipop_events_handle_net()
→ paipop_fsm_dispatch(PAIPOP_EVT_NET_CONNECTED)
→ pending_after_tone = ENGINE_INIT
→ 播放 NetCfgSucc.mp3
→ [audio_server 回调]
→ PAIPOP_EVT_TONE_DONE
→ transition(ENGINE_INIT)
→ paipop_engine_chat_init()
```

### `FLOW-02`：没有历史网络或自动连接失败

```text
WIFI_EVENT_MODULE_INIT
→ 没有历史 STA
→ 默认模式设为 AP
→ 发布 PAIPOP_NET_EVENT_AP_CONFIG

或者

STA 关联/DHCP 失败
→ notify_failure_once(error)

共同进入
→ SYS_NET_EVENT
→ PAIPOP_EVT_VM_ALL_FAILED
→ 播放 NetCfgStart.mp3
→ TONE_DONE
→ transition(AP_CONFIG)
→ paipop_wifi_provision_enter_ap()
→ WIFI_EVENT_AP_START
→ 启动 paipop_ap_dns
→ 启动 paipop_ap_http
→ 手机打开配网页面
```

### `FLOW-03`：网页提交新网络

```text
POST /config
→ 解析 history/snapshot 或 ssid/password
→ 校验历史选择是否过期
→ 复制 pending_ssid/pending_pwd
→ 返回 HTTP 200
→ 关闭 HTTP 连接和监听
→ 停止 DNS
→ 清旧扫描/旧默认 STA 控制
→ wifi_enter_sta_mode(new)
→ 关联成功
→ DHCP 成功
→ 保存新凭据并置为 MRU
→ NET_EVENT_CONNECTED
→ 播放联网成功提示音
→ ENGINE_INIT
```

## 三十二、关键函数身份与职责

| 函数 ID | 函数 | 来源 | 关键职责 |
|---|---|---|---|
| `FUNC-01` | `paipop_wifi_provision_start(void)` | 项目手写代码 | 清上下文、注册 Wi-Fi 回调并开启模块 |
| `FUNC-02` | `paipop_apcfg_wifi_event_callback(void *, enum WIFI_EVENT)` | 项目手写代码 | 把底层 Wi-Fi 生命周期转换为策略动作和产品网络事件 |
| `FUNC-03` | `paipop_apcfg_enter_sta_from_vm(const char *)` | 项目手写代码 | 只读取并尝试最近一次成功 STA |
| `FUNC-04` | `paipop_apcfg_enter_ap_internal(u8)` | 项目手写代码 | 配置 LAN、AP 默认模式并启动热点 |
| `FUNC-05` | `paipop_apcfg_dns_task(void *)` | 项目手写代码 | 实现最小通配 DNS 应答 |
| `FUNC-06` | `paipop_apcfg_http_task(void *)` | 项目手写代码 | 提供页面、解析表单并发起 STA 切换 |
| `FUNC-07` | `paipop_apcfg_store_sta_if_needed(void)` | 项目手写代码 | DHCP 成功后提交候选凭据 |
| `FUNC-08` | `paipop_events_handle_net(struct net_event *)` | 项目手写代码 | 根据 FSM 当前状态翻译网络事件 |
| `FUNC-09` | `paipop_fsm_dispatch(enum paipop_toy_event, int)` | 项目手写代码 | 清理业务资源并决定状态迁移 |
| `FUNC-10` | `wifi_enter_sta_mode()` 等 | 杰理 SDK API | 执行无线模式切换，内部实现停在 SDK 边界 |

## 三十三、这部分最值得面试讲的六个设计点

### 1. 把 DHCP 成功定义为产品联网边界

关联成功不等于网络可用。保存凭据、启动引擎和通知 OTA 都等 DHCP 成功后进行。

### 2. 凭据采用 pending/commit 两阶段保存

用户提交只形成候选；验证成功后才写 VM，避免错误密码污染最近成功配置。

### 3. 保存 6 组，但自动路径只尝试最近 1 组

用确定的失败时间和简单状态机换取少量人工选择成本，避免多网络扫描与重复回调竞态。

### 4. 历史密码不回显，索引再带 snapshot

网页只看见经过转义的 SSID；密码留在设备内部，snapshot 防止陈旧索引连错网络。

### 5. DNS + HTTP 实现无 App 配网

用最小 UDP DNS 和 TCP HTTP 服务覆盖常见强制门户探测，不依赖手机安装专用 App。

### 6. 用 `force_ap_pending` 保护新业务意图

用户已经要求配网后，旧 STA 的迟到成功、失败和断开事件不再有权改变新流程。

## 三十四、面试官可能继续追问什么

### Q1：为什么不是 `WIFI_EVENT_STA_CONNECT_SUCC` 就启动 PaipopSDK？

因为它只代表 802.11 关联成功，设备可能还没有 IP、网关和 DNS。当前项目等 DHCP 成功后才发布 `NET_EVENT_CONNECTED`。

### Q2：为什么只自动连接最近一个网络？

多历史网络自动扫描和遍历会延长启动时间，并增加关联失败、超时、扫描完成和模式切换事件之间的竞态。当前版本选择确定性：最近网络失败就进入 AP，其余历史项由用户在网页选择。

### Q3：为什么保存前先删除同名 SSID？

为了更新密码并维持 MRU，而不是产生重复项。成功使用旧网络后重新保存，还能把它变成最近记录。

### Q4：为什么不在网页提交时立即保存？

提交内容尚未验证。只有取得 DHCP 才证明 SSID、密码和基本网络配置可用，之后再提交到 VM。

### Q5：没有历史凭据时为什么发布自定义 `PAIPOP_NET_EVENT_AP_CONFIG`？

Wi-Fi 策略层需要告诉产品 FSM“自动路径没有候选，应进入配网”，但它不应该直接播放提示音或改变产品状态，所以通过网络事件桥接。

### Q6：DNS 为什么把所有域名都解析到设备？

AP 配网时设备不提供公网 DNS，通配解析能把手机的联网探测引到本地门户。这个 DNS 只在 AP 模式临时运行。

### Q7：为什么其他 DNS 类型返回空成功，而不是都返回 A 记录？

AAAA 等类型不能用 IPv4 A 记录格式回答。空成功允许客户端继续请求 IPv4 A，避免构造错误类型的数据。

### Q8：为什么页面要对 SSID 做 HTML 转义？

SSID 来自外部无线环境，可能包含 HTML 特殊字符。直接拼接会破坏页面，甚至形成注入。

### Q9：`history_snapshot` 和 generation 有什么相似点？

二者都给易变化的对象附加版本身份。snapshot 防止旧网页索引引用新数组，generation 防止旧音频或回调污染新轮次。

### Q10：为什么收到配置后不能马上关 AP？

要先把 HTTP 200 响应发给手机并关闭连接，否则浏览器容易显示提交失败。之后再切 STA。

### Q11：为什么切 STA 前要重写默认模式？

防止驱动继续执行开机遗留的默认 SSID 重试，让旧网络在新一轮扫描中重新取得控制权。

### Q12：为什么自动连接失败和网页配网失败要映射成不同事件？

前者意味着应播放进入配网提示并首次建立 AP；后者意味着用户提交失败，应播失败音并恢复已有 AP 页面。业务恢复路径不同。

### Q13：为什么 AP 状态断网不能回 VM？

AP/STA 模式切换本身会产生断网。若回 VM，会在 AP 和自动连接之间振荡。AP 配网只能由 DHCP 成功离开。

### Q14：强制配网为什么需要 pending 标志？

切网是异步的。用户发出新意图后，旧连接产生的回调仍可能到达；pending 标志让旧事件失去状态迁移权限。

### Q15：这套 HTTP 服务能否替代通用 Web Server？

不能。它是一次性、小请求、串行处理的 MCU 配网服务，没有完整 HTTP 分片、chunked、并发和 TLS 能力。

### Q16：当前方案最大的安全风险是什么？

开放 AP 与明文 HTTP 不能抵抗无线覆盖范围内的邻近攻击者。量产若有更高要求，需要临时凭据、设备确认、加密提交和配网超时。

### Q17：怎样测试这套配网链路？

至少覆盖：无历史凭据、正确历史凭据、SSID 不存在、密码错误、关联成功但 DHCP 超时、提交新网络成功、历史密码变更、陈旧 snapshot、特殊字符 SSID、双键配网期间迟到 DHCP、配网中断电、连续七个不同网络、Android/iOS/Windows 自动弹窗与手动访问。

### Q18：怎样确认没有泄露密码？

检查串口日志、HTML 源码、HTTP 抓包、错误响应、浏览器历史和崩溃转储；还应检查请求缓冲释放前是否需要显式清零，以及正式版本是否继续支持 GET 带密码路径。

## 三十五、怎样用一分钟讲清楚

> 这个项目没有把联网写成一个阻塞函数，而是给杰理 Wi-Fi 模块注册回调，由策略层处理模块启动、STA 关联、DHCP、AP 和超时事件，再通过 `SYS_NET_EVENT` 交给产品 FSM。设备最多保存 6 组历史 Wi-Fi，但开机只自动连接最近一次成功网络，20 秒内关联或 DHCP 失败就进入 AP 配网，避免多网络扫描造成长等待和重复事件。关联成功还不算联网，只有 DHCP 成功后才保存候选密码、通知 FSM 和 OTA。AP 使用 MAC 后缀生成名称，在 `192.168.1.1` 上运行最小通配 DNS 和 HTTP 服务，让手机尽量自动弹出配网页面。历史页面只输出转义后的 SSID，密码留在设备内部，并用 snapshot 防止旧页面索引连错网络。用户双键长按 3 秒可以从任意状态强制配网，`force_ap_pending` 会屏蔽旧 STA 迟到的成功、失败和断开事件。整个设计的重点是把底层异步网络事件、用户提示流程和语音引擎生命周期分层处理。

## 三十六、源码证据索引

| 结论 | 主要源码位置 |
|---|---|
| Wi-Fi 服务进入当前目标构建 | `board/wl82/Makefile:52,286-288` |
| 应用启动与停止时启停 Wi-Fi 服务 | `app_main.c:100-150` |
| 产品初始状态为 `VM_CONFIG` | `src/app/paipop_fsm.c:1511-1529` |
| Wi-Fi 内部状态、共享句柄和关键常量 | `src/services/paipop_wifi_provision.c:15-62` |
| SSID 脱敏与 MRU 保存 | `src/services/paipop_wifi_provision.c:71-108` |
| 最近单条凭据读取 | `src/services/paipop_wifi_provision.c:129-170,259-270` |
| 六条历史记录去重与 MRU 归一化 | `src/services/paipop_wifi_provision.c:173-286` |
| AP LAN、DHCP DNS 和热点名 | `src/services/paipop_wifi_provision.c:296-356` |
| 最小通配 DNS 应答 | `src/services/paipop_wifi_provision.c:358-545` |
| URL 解码与 GET/POST 表单解析 | `src/services/paipop_wifi_provision.c:547-725` |
| captive probe 列表和重定向 | `src/services/paipop_wifi_provision.c:727-778` |
| SSID HTML 转义 | `src/services/paipop_wifi_provision.c:803-863` |
| 动态历史页面和手动降级页 | `src/services/paipop_wifi_provision.c:865-991` |
| pending 配置切换到 STA | `src/services/paipop_wifi_provision.c:1015-1050` |
| HTTP 服务、snapshot 校验和成功响应 | `src/services/paipop_wifi_provision.c:1052-1231` |
| 进入 AP 与重启 portal | `src/services/paipop_wifi_provision.c:1233-1272` |
| 只自动尝试最近 STA | `src/services/paipop_wifi_provision.c:1274-1318` |
| 强制 AP pending 与 DHCP 后保存 | `src/services/paipop_wifi_provision.c:1320-1391` |
| Wi-Fi 模块、AP、STA、DHCP 和失败回调 | `src/services/paipop_wifi_provision.c:1393-1560` |
| 服务启动、回调注册与停止 | `src/services/paipop_wifi_provision.c:1562-1585` |
| 双键 20 ms 检查、3 秒触发和 500 ms 抑制 | `src/app/paipop_events.c:20-33,210-323` |
| 网络事件按产品状态翻译 | `src/app/paipop_events.c:466-513` |
| 业务状态迁移硬约束 | `src/app/paipop_fsm.c:95-140` |
| 提示音 pending 与完成事件 | `src/app/paipop_fsm.c:190-214,1378-1396,2040-2055` |
| 联网成功、失败和断网处理 | `src/app/paipop_fsm.c:1584-1637` |
| 双键强制配网完整清理 | `src/app/paipop_fsm.c:1638-1662` |
| 提示音播放器与 `TONE_DONE` 发布 | `src/services/paipop_tone.c:24-150` |
| 杰理 Wi-Fi 事件与公开接口契约 | `include_lib/net/wifi/wifi_connect.h:41-143,188-193,300-432` |

## 总结

Paipop 的联网与配网可以分成五层：

```text
无线执行层
杰理 Wi-Fi 模块 + STA/AP + DHCP

策略层
最近凭据选择 + pending 保存 + MRU + 失败去重

本地门户层
通配 DNS + HTTP 页面 + 历史 snapshot

事件桥接层
Wi-Fi callback → SYS_NET_EVENT → Paipop 业务事件

产品控制层
FSM + 提示音门控 + 语音/OTA/预录清理
```

最值得记住的不是某个 Wi-Fi API 名字，而是三个边界：

1. 关联成功不等于网络可用，当前项目以 DHCP 成功作为提交点；
2. 用户提交不等于凭据有效，候选配置只有验证成功后才写入 VM；
3. 新的配网意图不等于旧异步流程已经消失，必须主动屏蔽迟到事件。

这三点分别对应网络分层、事务式配置和异步状态隔离。把它们讲清楚，面试官继续追问 DHCP、Flash 凭据、强制门户、线程竞争或异常恢复时，就不会只剩下“我调用了一个 Wi-Fi 配网接口”这种表面回答。
