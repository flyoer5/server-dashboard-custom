# Server Dashboard Custom

一个轻量级的自用服务器控制面板，基于单文件 Perl 后端和原生 HTML/JavaScript 前端实现。

当前面板主要用于查看和管理本机服务、Docker 容器、Cloudflare Tunnel，以及 TRSS-Yunzai 的运行状态和日志。

---

## 项目特点

- 无前端构建流程
- 无复杂依赖
- 单 Perl 服务端
- 单 HTML 前端页面
- 适合自用服务器快速部署
- 支持通过 systemd 常驻运行

核心文件：

```text
server-dashboard/
├── dashboard.pl              # Perl 后端服务
└── dashboard/
    └── index.html            # 前端页面
```

默认监听端口：

```text
1111
```

访问地址示例：

```text
http://服务器IP:1111/
```

---

## 功能介绍

### 1. 服务端口

服务端口页用于查看当前服务器上正在监听端口的服务。

主要展示：

- 服务名称
- 服务描述
- 监听端口
- TCP / UDP 协议
- 进程信息
- Docker / systemd 来源识别
- 服务访问链接

面板会尽量识别常见服务，例如：

- SSH
- Docker / containerd
- mihomo
- NapCat
- AstrBot
- PicoClaw
- Server Dashboard 本身

---

### 2. Docker 管理

Docker 管理页用于查看和管理 Docker 容器。

支持：

- 查看容器列表
- 查看容器状态
- 查看镜像
- 查看资源占用
- 启动容器
- 停止容器
- 重启容器
- 查看容器日志
- 日志搜索
- 日志复制
- 日志下载

---

### 3. Cloudflare Tunnel 管理

Tunnel 页面用于查看和管理 Cloudflare Tunnel 映射规则。

支持：

- 查看 cloudflared 服务状态
- 查看 Tunnel ID / Tunnel 名称
- 查看 ingress 映射
- 快捷新增子域名映射
- 自定义新增映射
- 编辑映射
- 删除映射
- 重启 Tunnel
- 查看 `cloudflared tunnel list` 输出

默认配置文件路径：

```text
/etc/cloudflared/config.yml
```

快捷新增时，子域名会自动补全为：

```text
*.lgh123.online
```

---

### 4. TRSS-Yunzai 管理

Yunzai 页面用于查看和管理 TRSS-Yunzai。

支持：

- 查看 PM2 状态
- 查看 Yunzai PID
- 查看重启次数
- 查看 Node.js 版本
- 查看 pnpm 版本
- 查看 Valkey / Redis 状态
- 查看 PM2 自启状态
- 查看 PM2 进程列表保存状态
- 查看 2536 端口监听状态
- 查看 WebSocket 连接状态
- 打开 Guoba 面板

操作按钮：

- 启动
- 重启
- 停止
- 保存进程列表
- 启用 PM2 自启
- 禁用 PM2 自启

相关目录：

```text
/root/Yunzai
```

Guoba 面板地址：

```text
http://服务器IP:2536/guoba
```

---

## Yunzai 日志说明

Yunzai 页包含两种日志视图。

### 页面内日志预览

页面内预览只显示：

```text
/root/.pm2/logs/TRSS-Yunzai-out.log
```

也就是 TRSS-Yunzai 的标准输出日志。

这样可以避免错误日志里很久以前的内容干扰页面预览，更适合日常查看：

- 群消息
- 插件处理记录
- Bot 发送消息
- 运行状态输出

预览行为：

- 首次加载：读取 out 日志最近 120 行
- 后续停留页面期间：增量追加新日志
- 点击“刷新日志”：重新读取 out 日志最近 120 行

### 完整日志弹窗

点击“打开完整日志”后，会打开完整日志弹窗。

完整日志更接近终端命令：

```bash
cd /root/Yunzai
pnpm log
```

也就是等价于：

```bash
pm2 log --lines 100
```

完整日志会包含：

- out 日志
- error 日志

因此如果 error 日志很久没有更新，仍然可能看到较早的错误记录。这是 PM2 日志本身的行为。

---

## 部署方式

### 1. 克隆仓库

```bash
cd /root
git clone https://github.com/flyoer5/server-dashboard-custom.git server-dashboard
```

如果目录已存在，可以先备份或拉取更新：

```bash
cd /root/server-dashboard
git pull origin main
```

---

### 2. 确认 Perl 环境

本项目后端使用 Perl。

检查 Perl：

```bash
perl -v
```

一般 Linux 系统默认自带 Perl。

---

### 3. 直接启动测试

```bash
cd /root/server-dashboard
perl dashboard.pl
```

看到监听 1111 端口后，即可访问：

```text
http://服务器IP:1111/
```

如果在本机测试：

```text
http://127.0.0.1:1111/
```

---

## 使用 systemd 常驻运行

推荐使用 systemd 管理面板服务。

### 1. 创建服务文件

```bash
cat > /etc/systemd/system/server-dashboard.service <<'EOF'
[Unit]
Description=Standalone Server Dashboard
After=network.target

[Service]
Type=simple
WorkingDirectory=/root/server-dashboard
ExecStart=/usr/bin/perl /root/server-dashboard/dashboard.pl
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
EOF
```

---

### 2. 重新加载 systemd

```bash
systemctl daemon-reload
```

---

### 3. 启动服务

```bash
systemctl start server-dashboard.service
```

---

### 4. 设置开机自启

```bash
systemctl enable server-dashboard.service
```

---

### 5. 查看状态

```bash
systemctl status server-dashboard.service
```

---

### 6. 重启服务

```bash
systemctl restart server-dashboard.service
```

---

### 7. 停止服务

```bash
systemctl stop server-dashboard.service
```

---

## 常用维护命令

### 查看 1111 端口占用

```bash
ss -ltnp | grep ':1111'
```

### 查看服务状态

```bash
systemctl status server-dashboard.service
```

### 查看服务日志

```bash
journalctl -u server-dashboard.service -f
```

### 重启面板

```bash
systemctl restart server-dashboard.service
```

### 更新代码后重启

```bash
cd /root/server-dashboard
git pull origin main
systemctl restart server-dashboard.service
```

---

## 相关路径

### 面板项目

```text
/root/server-dashboard
```

### 面板后端

```text
/root/server-dashboard/dashboard.pl
```

### 面板前端

```text
/root/server-dashboard/dashboard/index.html
```

### TRSS-Yunzai

```text
/root/Yunzai
```

### Yunzai PM2 日志

```text
/root/.pm2/logs/TRSS-Yunzai-out.log
/root/.pm2/logs/TRSS-Yunzai-error.log
```

### Cloudflare Tunnel 配置

```text
/etc/cloudflared/config.yml
```

---

## 注意事项

1. 本项目偏自用，不包含复杂权限系统。
2. 建议只在可信网络或内网环境中使用。
3. 如果需要公网访问，建议放在 Cloudflare Tunnel / Nginx 反代 / 防火墙白名单之后。
4. 面板中包含服务启停、Docker 控制、Tunnel 配置修改等能力，请勿暴露给不可信用户。
5. Yunzai 日志预览和完整日志是两个不同视角：
   - 预览：只看 out 日志，更适合日常查看
   - 完整日志：接近 `pnpm log`，包含 error 日志

---

## 仓库

```text
https://github.com/flyoer5/server-dashboard-custom
```
