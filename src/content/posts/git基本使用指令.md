---
title: git基本使用指令
published: 2025-12-16
pinned: false
description: git基本使用指令
tags: [git]
category: 其他
draft: false
---

# Git 基本使用指令


---

# 1. 查看远程仓库（看你关联了谁）
```bash
git remote -v
```

---

# 2. 关联仓库（第一次必须用）
## 关联【自己的仓库】origin
```bash
git remote add origin https://github.com/huangzy-hub/ESP32S3.git
```

## 关联【原项目仓库】upstream（别人的项目）
```bash
git remote add upstream https://github.com/it-cc/ESP32S3.git
```

---

# 3. 修改远程仓库地址（错了可以改）
```bash
git remote set-url origin https://github.com/huangzy-hub/ESP32S3.git
git remote set-url upstream https://github.com/it-cc/ESP32S3.git
```

---

# 4. 分支操作（最常用）
```bash
git branch                # 查看所有分支
git checkout main          # 切回主分支
git checkout my-dev        # 切到你的分支
git checkout -b my-dev     # 创建并切换新分支
```

---

# 5. 查看修改
```bash
git status    # 看哪些文件被修改
git diff      # 看具体改了什么内容
```

---

# 6. 提交代码到本地
```bash
git add .
git commit -m "完成功能修改"
```

---

# 7. 拉取代码（同步云端）
## 拉【原项目】最新代码
```bash
git pull upstream main
```

## 拉【自己仓库】最新代码
```bash
git pull origin main
```

---

# 8. 完全同步云端（强制覆盖本地，最干净）
```bash
git merge --abort
git fetch upstream
git reset --hard upstream/main
git clean -fd
```

---

# 9. 合并分支
```bash
git merge my-dev
```

---

# 10. 推送到云端（最关键）
## 推送到【自己的仓库】origin
```bash
git push origin my-dev    # 推自己的分支
git push origin main      # 推主分支
```

## 推送到【原项目仓库】upstream
```bash
git push upstream my-dev
git push upstream main
```

---

# 🚀 你以后标准开发流程（背这一套）
```bash
# 1. 同步原项目最新代码
git checkout main
git pull upstream main

# 2. 创建自己的分支
git checkout -b my-dev

# 3. 写代码 → 提交
git add .
git commit -m "修改完成"

# 4. 推到自己仓库备份
git push origin my-dev 

# 5. 合并并推到原项目
git checkout main
git pull upstream main
git merge my-dev
git push upstream main
```
