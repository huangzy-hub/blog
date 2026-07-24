---
title: 解决 SCP 传输时 SSH 权限拒绝
published: 2026-03-08
pinned: false
description: 解决嵌入式开发板 SCP 传输时 SSH 权限拒绝
tags: [记录]
category: 嵌入式
draft: false
---


# 解决 SCP 传输时 SSH 权限拒绝（Permission denied）笔记
---

## 一、问题本质
在 Ubuntu 嵌入式开发板（如 KickPi）上，**默认 SSH 配置禁止 root 账号通过密码登录**，导致虚拟机执行 `scp root@开发板IP:/lib/` 时，反复提示 `Permission denied, please try again`。

核心配置项：
```ini
# 默认配置（禁止密码登录）
PermitRootLogin prohibit-password
```

---

## 二、解决步骤（仅在开发板串口终端执行）
### 1. 一键修改 SSH 配置
直接用 `sed` 命令修改配置文件，无需手动编辑：
```bash
# 允许 root 账号密码登录
sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

# 确保密码认证功能开启
sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
```

### 2. 重启 SSH 服务（让配置生效）
Ubuntu 16.04 及衍生版，服务名是 `ssh`（不是 `sshd`）：
```bash
systemctl restart ssh
```

> 验证服务是否正常运行：
> ```bash
> systemctl status ssh
> ```
> 看到 `active (running)` 即生效。

---

## 三、验证权限是否解决
回到虚拟机终端，执行任意 SCP 命令测试：
```bash
# 测试连接（随便传一个小文件或直接测试登录）
ssh root@192.168.1.176  # 替换为你的开发板实际IP
```
- 若能输入密码并登录到 `root@kickpi:~#`，说明权限问题已解决；
- 之后再执行 `scp` 传输文件，就不会再出现 `Permission denied`。

---

## 四、关键提醒
1. **操作入口限制**：必须通过**串口终端**（如 MobaXterm 串口连接）执行以上命令，不能通过 SSH 执行（否则会被拒绝）；
2. **安全风险**：开启 root 密码登录会降低安全性，仅建议开发阶段临时使用；
3. **端口特殊情况**：若开发板 SSH 端口不是 22，SCP 需加 `-P 端口号`（大写 P），如：
   ```bash
   scp -P 2222 文件名 root@192.168.1.176:/lib/
   ```

---

### 一句话总结
Ubuntu 开发板默认禁止 root 密码登录 SSH，只需在串口终端修改 `sshd_config` 并重启 `ssh` 服务，即可解决 SCP `Permission denied` 问题。