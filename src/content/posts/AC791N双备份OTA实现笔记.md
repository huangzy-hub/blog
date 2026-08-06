---
title: AC791N 双备份 OTA 实现笔记：从云端认证到安全切换
published: 2026-08-06
pinned: false
description: 记录 Paipop 玩具在杰理 AC791N/WL82 平台上实现 tenBackend Firmware OTA 的完整过程，涵盖双备份布局、HMAC 认证、流式下载、SHA-256 校验、升级状态上报和重启确认。
tags: [AC791N, OTA, 双备份, HMAC, SHA-256, 嵌入式]
category: 嵌入式
draft: false
---

# AC791N 双备份 OTA 实现笔记：从云端认证到安全切换

这次实现的是一套面向杰理 AC791N/WL82 玩具设备的 Firmware OTA。设备连接 Wi-Fi 后向 tenBackend 检查更新，命中新版本时把固件流式写入非活动应用区，完成长度和 SHA-256 校验后切换双备份启动区，重启后再向后台确认结果。

最终链路可以概括为：

```text
USB完整烧录双备份基线
  → Wi-Fi连接并取得DHCP地址
  → 等待设备空闲
  → HMAC认证检查更新
  → 后台灰度策略命中
  → 流式下载OTA包
  → 写入非活动固件区
  → 长度与SHA-256校验
  → 保存待确认记录
  → 切换启动分区并软重启
  → 新固件联网
  → 上报success或failed
```

本文重点记录工程结构和实现方法。示例不会展示真实设备身份、App Key、签名、领取码、下载 Token、Wi-Fi 凭据或 Paipop 认证信息。

> 本文中的 HTTP 地址仅用于受信网络联调。正式产品必须使用 HTTPS，并进一步考虑固件数字签名、安全启动和每台设备独立密钥。

## 一、需求边界

工程位于完整杰理 SDK 的玩具应用目录中，OTA只在玩具层实现。设计时固定了以下边界：

- 不修改 `PAIPOP_JIELI_SDK`；
- 不修改杰理公共升级模块源码；
- 玩具 Makefile 只链接现有的 `apps/common/update/net_update.c`；
- 不增加新的玩具状态机状态；
- 不改变原有按键、配网、对话和提示音逻辑；
- 第一版只升级应用固件，不实现 Resource OTA；
- 不实现断点续传和用户取消；
- 每次开机只检查一轮更新，并进行有限重试；
- 单备份设备不能通过 OTA 迁移到双备份，必须先完整 USB 烧录。

这样做的核心目的是把云端协议和玩具业务隔离开：OTA服务可以等待空闲、下载和切换固件，但不能把原有交互状态机改造成“OTA专用状态机”。

## 二、先理解双备份

单备份设备只有一个正在运行的应用区。如果直接擦除并覆盖这个区域，中途断电就可能留下不完整固件，设备无法继续启动。

双备份可以抽象为两个应用槽位：

```text
Flash
├── Bootloader与启动信息
├── 应用区A：当前固件
├── 应用区B：备用/目标固件
├── VM配置区
└── 音频等预留资源区
```

当设备从A区运行时，新固件写入B区：

```text
运行A区
  → 擦除并写入B区
  → 校验B区
  → 修改下一次启动信息
  → 重启进入B区
```

下一次升级时，A、B角色互换。

下载阶段如果在10%、50%或99%断电，当前活动区并没有被覆盖，Bootloader仍可从旧固件启动。只有新固件完整写入并通过校验，启动信息才会切换。

本工程启用：

```c
#define CONFIG_DOUBLE_BANK_ENABLE 1
```

打包配置使用8 MB Flash，并保留VM和音频资源区域。双备份基线必须先通过完整烧录文件建立；不能让一台仍使用单备份布局的设备直接接收双备份OTA包。

## 三、构建系统会产生哪些文件

这个工程的默认 `make` 并不只是编译，它还会执行后处理脚本和USB下载：

```text
源码
  → .o/.d
  → LTO链接
  → sdk.elf
  → download.bat提取可烧录段
  → app.bin
  → 杰理打包工具
  ├── jl_isd.fw
  ├── jl_isd.ufw
  ├── db_update_data.bin
  ├── db_update_files_data.bin
  └── jl_isd_extend.bin
```

### 1. `sdk.elf`

这是编译和链接后的ELF文件，包含机器码、段地址、符号表和调试信息。它用于调试、反汇编、地址定位和继续打包，不能直接作为后台OTA文件。

### 2. `app.bin`

后处理脚本使用 `llvm-objcopy` 从ELF中提取：

```text
.text
.data
.ram0_data
.cache_ram_data
```

再把它们拼接成 `app.bin`。它接近实际应用机器码，但不包含完整Bootloader、Flash布局和资源，因此也不是完整USB烧录包。

### 3. `jl_isd.fw`

这是完整USB烧录文件，用来建立或恢复整套设备基线，包括双备份布局、应用、配置和资源。

### 4. `db_update_data.bin`

这是杰理双备份升级的原始数据体，主要供打包和升级模块内部使用。

### 5. `db_update_files_data.bin`

本工程在打包时使用：

```text
-update_files normal
```

因此会在原始升级数据前增加一层文件目录封装。实际比较两个文件可以看到，`db_update_files_data.bin` 比 `db_update_data.bin` 多一个64字节头，里面有 `update_data`、`app_core` 等目录项。

tenBackend管理台应上传：

```text
db_update_files_data.bin
```

不要把它改名成 `jl_isd.fw` 做USB完整烧录。

### 6. 为什么需要归档版本产物

不同版本默认都输出到同一个 `cpu/wl82/tools` 目录。再次构建会覆盖之前的ELF、完整固件和OTA包，因此测试时需要按版本归档：

```text
artifacts/
├── v1.1.1_usb_baseline/
│   └── jl_isd.fw
└── v1.2.1/
    └── db_update_files_data.bin
```

典型测试顺序是：

1. 使用 `1.1.1/10101` 构建并保存USB基线；
2. 使用 `1.2.1/10201` 构建并保存OTA目标包；
3. USB完整烧录旧版本；
4. 后台上传新版本OTA包；
5. 观察设备从 `10101` 升级到 `10201`。

## 四、OTA模块如何接入玩具启动流程

应用启动时调用：

```c
paipop_ota_init();
```

它只初始化OTA控制结构并打印适配版本，不会立刻访问后台。

Wi-Fi取得DHCP地址后，配网服务调用：

```c
paipop_ota_network_ready();
```

OTA服务通过 `check_started` 保证本次开机只创建一个检查线程。Wi-Fi断开或模块停止时调用：

```c
paipop_ota_network_down();
```

若此时正在下载，活动HTTP操作会被终止。

## 五、为什么开机后延迟30秒

OTA线程先等待网络有效，再延迟30秒。这样可以让以下流程先完成：

- DHCP和NTP校时；
- Paipop后台配置获取；
- 语音引擎初始化；
- 开机或联网提示音播放；
- 玩具状态机进入等待触发状态。

OTA只在以下状态继续：

```text
ENGINE_EXIT
或 ENGINE_INIT_FAILED
并且当前没有提示音正在播放
```

这里 `ENGINE_INIT -> ENGINE_EXIT` 表示语音引擎初始化完成后进入等待触发状态，不是初始化失败。

如果设备正在对话或播放语音，OTA继续等待，不会强制打断。`force_update` 第一版也只记录，不会改变这一规则。

## 六、OTA凭据与首次领取

tenBackend OTA使用一套独立凭据：

- Base URL；
- App ID；
- App Key；
- Key Version；
- 设备身份。

它们不能复用 PaipopKey、license 或 `ai_app_code`。

当前代码支持三级来源：

```text
源码中配置的App Key
  ↓ 不存在
VM中保存的凭据
  ↓ 不存在
一次性provision_token领取
```

如果启用首次领取，设备调用：

```text
POST /api/device/ws-auth/provision
```

后台返回App Key和Key Version后，设备将凭据写入专用VM记录。记录中包含magic、schema、长度、CRC32和设备身份摘要，写入后立即读回校验。

需要注意：VM只是Flash存储区，不是硬件安全区。CRC32只能发现记录损坏，不能加密App Key，也不能抵抗物理读出。当前把App Key放在源码中同样只是联调方案。

## 七、HMAC认证是如何工作的

设备访问更新检查和状态接口时使用HMAC-SHA256。每次POST都会重新生成13位UTC毫秒时间戳，并组织：

```text
App ID
设备身份
时间戳
```

字段按协议排序并进行RFC3986编码，然后计算：

```text
digest = HMAC-SHA256(App Key, canonical_string)
signature = Base64(digest)
```

请求头携带App ID、设备身份、时间戳、Signature和Key Version。App Key本身不会通过网络发送。

服务器根据设备身份和Key Version找到同一份App Key，重新计算HMAC并比较。匹配说明请求方掌握合法密钥，且参与签名的字段没有被修改。

时间戳用于限制重放。如果设备时间无效，会先进行一次有限超时的NTP校时；校时失败则本次OTA按认证/网络条件不满足处理。

### HMAC和SHA-256不是一回事

两者都使用SHA-256算法，但目的不同：

| 机制 | 输入 | 是否需要密钥 | 作用 |
|---|---|---:|---|
| SHA-256 | 完整固件文件 | 否 | 检查文件内容是否一致 |
| HMAC-SHA256 | 请求认证字段 | 是 | 证明请求方掌握App Key |

可以简单记成：

```text
HMAC：你是谁，请求有没有被伪造？
SHA-256：下载到的文件有没有变化？
```

HMAC不加密请求内容，SHA-256也不能证明固件一定来自官方。正式产品仍需要HTTPS和固件数字签名。

## 八、检查更新接口

设备调用：

```text
POST /api/device/ota/check
```

请求中包含：

- 当前版本和 `version_code`；
- 硬件型号；
- 板型；
- 分区布局；
- 电量；
- Wi-Fi RSSI；
- 是否连接外部电源。

Type-C USB供电、USB从机模式或充电状态都会按外部电源处理，并向后台提供有效电量100%，避免后台把USB测试机误判为低电量。

本地升级门槛为：

```text
电量不低于30%
Wi-Fi RSSI不低于-75 dBm
```

后台命中更新后返回：

- Task ID；
- Firmware ID；
- 目标版本；
- 目标 `version_code`；
- 完整下载URL；
- URL过期时间；
- 文件大小；
- SHA-256；
- `force_update`。

设备还会本地检查：

```text
目标version_code > 当前version_code
URL协议有效
URL不会在30秒内过期
size有效
SHA-256格式有效
电量和RSSI满足门槛
玩具处于空闲状态
```

若后台明确返回无更新，本次开机不再检查。普通网络错误最多检查三次，延迟分别为：

```text
0秒、60秒、300秒
```

## 九、Task ID、Firmware ID与Key Version

这三个字段常被混淆：

```text
Firmware ID：标识固件文件
Task ID：标识一次发布活动
Key Version：标识设备当前使用哪一版HMAC密钥
```

同一个Firmware ID可以用于单设备allowlist、5%灰度和全量发布，每次使用不同Task ID。设备后续上报的下载进度和升级结果都通过Task ID关联到这次发布。

Key Version属于设备认证系统，不属于固件发布表单，因此管理台上传固件时不需要填写。设备会在HMAC请求头中自动携带它。

## 十、流式下载与写入非活动区

下载开始后设置：

```c
ota.busy = 1;
```

玩具层此时阻止新的触摸对话和摇晃打断。检查更新和等待空闲期间不设置busy，因此不影响原有交互。

下载缓冲区只有4 KB：

```c
#define PAIPOP_OTA_DOWNLOAD_BUF_SIZE (4 * 1024)
```

数据链路是：

```text
HTTP响应
  → 4 KB RAM缓冲区
  → SHA-256累计计算
  → net_fwrite()
  → 杰理net_update模块
  → 非活动应用区
```

设备不需要在RAM中保存完整的1 MB固件。

升级写入口是：

```c
net_fopen(CONFIG_UPGRADE_OTA_FILE_NAME, "w");
```

这里的文件名是升级模块提供的虚拟入口，不代表设备存在Windows式目录。`net_fwrite()` 会把数据交给杰理双备份写入任务。

玩具Makefile链接现有的 `apps/common/update/net_update.c`，并在应用任务表中注册 `update` 和 `dw_update`。如果缺少这些任务，底层写入会失败并提示找不到升级任务。

## 十一、下载过程的检查

下载开始时先验证：

```text
HTTP状态码 == 200
Content-Length == 后台size
```

每读取一块数据，同时进行：

```c
mbedtls_sha256_update(...);
net_fwrite(...);
```

设备每跨过约10%上报一次 `downloading` 状态。

下载结束后必须同时满足：

```text
实际接收字节数 == 后台size
本地SHA-256 == 后台SHA-256
每次Flash写入长度 == 输入长度
```

失败时调用：

```c
net_fclose(fd, 1);
```

表示中止升级，不切换启动区。

完整下载最多尝试两次，第一次失败后等待约2秒。若URL即将过期，或者下载服务器返回401/403，设备最多重新调用一次 `/api/device/ota/check` 获取新URL。

## 十二、状态上报

状态接口为：

```text
POST /api/device/ota/status
```

正常状态链是：

```text
detected
→ confirmed
→ downloading 0%
→ downloading 10% ... 100%
→ downloaded
→ 重启
→ success
```

下载、长度、哈希、Flash写入和启动切换失败时上报 `failed`，并使用稳定错误字符串，例如：

```text
firmware_download_failed
firmware_size_mismatch
firmware_sha256_mismatch
ota_write_failed
ota_set_boot_failed
download_url_expired
```

进度上报失败不阻塞安全下载，防止固件正确下载却因为一次遥测失败而被强制中断。

## 十三、保存待确认记录并切换启动区

长度和SHA-256都正确后，设备先在另一个VM项中保存待确认记录，包括：

- magic和schema；
- 校验值；
- Task ID；
- 目标版本；
- 目标 `version_code`；
- 总字节数；
- 当前升级阶段。

只有记录保存成功，才继续上报 `downloaded` 并调用：

```c
net_fclose(update_fd, 0);
```

参数0表示正常结束。杰理公共升级模块完成固件结构校验、写入启动信息并安排软重启。玩具层不额外调用 `system_reset()`，避免在底层启动信息尚未写完时强制复位。

成功路径会看到类似：

```text
image verified, reboot scheduled
```

随后播放短促的OTA提示音，由升级模块自动重启。

## 十四、新固件如何确认升级结果

新固件启动、联网并进入空闲后，OTA服务读取待确认记录：

```text
记录中的目标version_code
        对比
当前固件编译进去的version_code
```

相同则上报：

```text
success
```

仍然运行旧版本则上报：

```text
failed / boot_not_target
```

只有后台明确返回 `accepted=true`，设备才清除待确认记录。若上报时断网，记录继续保留，下次联网再次上报。

当前玩具层无法从公共升级模块明确证明“发生了Bootloader回滚”，因此不会仅凭版本不匹配就上报 `rollback`。

## 十五、实际测试的判断方法

一次完整OTA至少应观察到：

```text
旧固件启动：current=10101
OTA检查命中：target=10201
下载进度：10% ... 100%
长度和SHA-256通过
image verified, reboot scheduled
系统软重启
新固件启动：current=10201
联网后上报success
```

如果重启日志已经显示目标版本，说明双备份切换成功。由于OTA线程在DHCP后还会等待约30秒，只有几秒钟的重启日志通常看不到最终 `success`，建议至少记录启动后40秒。

常见问题可以按下面顺序排查：

### 1. `no update`

检查：

- 当前版本是否已经等于后台目标版本；
- Task是否有效且已到生效时间；
- allowlist是否包含当前设备；
- 硬件型号、板型和分区布局是否完全一致；
- 电量、外部电源和RSSI是否符合策略。

### 2. 找不到 `dw_update`

说明应用任务表没有注册杰理双备份写入任务，或者公共 `net_update.c` 没有链接进入工程。

### 3. SHA-256不匹配

确认后台填写的大小和摘要来自实际上传的 `db_update_files_data.bin`，而不是 `db_update_data.bin` 或同名旧文件。

### 4. OTA成功后仍检查不到新版本

先看启动日志里的当前 `version_code`。后台目标版本必须严格大于当前值；版本名称只是展示，设备判断新旧依赖数字版本号。

## 十六、为什么当前OTA不会覆盖音频资源

当前OTA包大小接近应用代码大小，不包含完整音频预留区。OTA只改写应用槽位，不主动擦除：

- AUPACKRES音频资源；
- Wi-Fi VM配置；
- OTA凭据VM；
- 其他保留区。

如果修改了 `audlogo` 中的MP3，需要重新USB完整烧录，或者后续单独设计Resource OTA。

## 十七、当前方案与量产方案的差距

这套实现已经具备功能闭环：

```text
认证检查
灰度命中
流式下载
长度与SHA-256校验
双备份写入
失败保留旧固件
重启确认
状态上报
```

但它仍是联调和样机级实现，正式量产至少还应补齐：

### 1. 全链路HTTPS

HMAC只认证设备请求，不会加密内容。普通HTTP下，检查响应、下载URL和固件数据都可能被监听或篡改。检查接口、状态接口和固件下载都应使用HTTPS，并正确验证服务器证书。

### 2. 固件数字签名

SHA-256只能证明文件与后台提供的摘要一致。攻击者若能同时替换固件和摘要，普通哈希不能证明固件来自官方。

成熟方案通常是：

```text
发布系统使用私钥签名固件摘要
设备使用内置公钥验证签名
```

### 3. 安全启动和明确回滚

更完整的方案由Bootloader验证固件签名，并把新固件标记为试运行。新固件通过网络、任务和看门狗健康检查后主动确认；若反复崩溃，则Bootloader自动回滚旧槽位，并提供可读取的回滚原因。

### 4. 每台设备独立密钥

量产不应在公共源码中保存所有设备共用的App Key。应在工厂注入每台设备独立凭据，结合OTP、eFuse、安全存储、调试口保护和服务端撤销机制。

### 5. 周期检查与随机抖动

当前每次开机只检查一次。大量设备量产后通常还需要周期检查，并给检查时间加入随机抖动，避免所有设备同时访问服务器。

### 6. 后台自动止损

成熟发布平台会监控升级成功率、启动失败率和回滚率。当失败率超过阈值时自动暂停Task，而不是继续扩大灰度范围。

## 十八、总结

这次实现最重要的不是“把一个 `.bin` 下载下来”，而是打通了完整生命周期：

```text
发布身份
→ 设备认证
→ 策略命中
→ 安全下载
→ 非活动区写入
→ 内容校验
→ 原子切换
→ 重启确认
→ 云端闭环
```

其中几组概念必须分清：

```text
jl_isd.fw：USB完整烧录基线
db_update_files_data.bin：后台OTA包

HMAC-SHA256：设备请求认证
SHA-256：固件内容完整性
数字签名：证明固件由官方签发

Firmware ID：一个固件文件
Task ID：一次发布任务
Key Version：一版设备认证密钥
```

双备份解决的是“升级中断后还能启动”，HMAC解决的是“谁在请求后台”，SHA-256解决的是“文件有没有变化”。只有再配合HTTPS、固件数字签名、安全启动和明确回滚，才是一套更接近成熟量产设备的OTA安全体系。
