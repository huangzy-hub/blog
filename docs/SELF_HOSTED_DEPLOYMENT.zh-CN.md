# 博客直接部署到云服务器

本项目支持绕过 GitHub Pages，直接把本地 Git 提交和构建结果发送到自己的服务器。源码保存在服务器，本地完成 Astro 构建，服务器通过原子符号链接切换静态站点。

## 服务器目录

```text
/srv/git/blog.git       裸 Git 仓库，接收 push
/srv/blog/source        服务器上的完整项目源码
/srv/blog/incoming      正在上传的构建包
/srv/blog/releases      每次成功发布的静态版本
/srv/blog/current       当前生效版本的符号链接
```

Nginx 的站点根目录应指向 `/srv/blog/current`。本地构建或上传失败时不会切换该链接，所以旧版本继续可用。

## 初始化服务器

以具备 SSH 登录权限的部署用户执行：

```sh
install -d -m 0755 /srv/git /srv/blog
git init --bare --initial-branch=main /srv/git/blog.git
install -m 0755 scripts/server-post-receive.sh \
  /srv/git/blog.git/hooks/post-receive
install -m 0755 scripts/server-deploy-static.sh \
  /usr/local/sbin/deploy-blog-static
```

部署用户必须能写入 `/srv/git/blog.git` 和 `/srv/blog`。Node.js、pnpm 和构建依赖只需安装在本地电脑。这样小内存服务器不会因为 Vite 构建挤占 Headscale、FRP 等常驻服务的内存。

## 配置本地远端

```sh
git remote add production ssh://deploy@blog.example.com/srv/git/blog.git
git config branch.main.pushRemote production
```

以后正常编辑并在本地提交，然后执行：

```powershell
.\scripts\deploy-production.ps1 `
  -Server 'deploy@blog.example.com' `
  -IdentityFile '<SSH_PRIVATE_KEY_PATH>'
```

脚本会在本地构建、直接推送源码、上传 `dist` 并核对服务器记录的提交号，全程不经过 GitHub。原来的 GitHub remote 可以保留作可选备份。

## Nginx

静态站点配置的核心是：

```nginx
server_name blog.example.com;
root /srv/blog/current;
index index.html;
```

证书配置和 ACME 验证目录按服务器现有环境保留。修改后先执行 `nginx -t`，验证通过再 reload。

## 回滚

列出历史版本：

```sh
ls -1dt /srv/blog/releases/*
```

确认目标目录包含 `index.html` 后，手动把 `/srv/blog/current` 指向该版本即可。不要在没有核对绝对路径时批量删除历史版本。
