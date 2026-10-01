# MonkeyCode DevBox 进程管理与 init 方案

> 适用环境：`ghcr.io/chaitin/monkeycode-runner/devbox:latest`
> 实测平台：Firecracker microVM + KVM，Debian GNU/Linux 12 (bookworm)，内核 6.6.116
> 镜像仓库：<https://github.com/chaitin/DevRunner>
> 平台仓库：<https://github.com/chaitin/MonkeyCode>（AGPL-3.0）
> 全部结论均在本机实测验证，验证时间：2026-09-30 ~ 2026-10-01

---

## 摘要：三个核心结论

| # | 结论 | 依据 |
|---|---|---|
| 1 | **systemd 无法当PID 1**，自定义镜像也做不到 | PID 1 是平台注入的 `/firecracker-init`；`images` 表只有 `name` 字段 |
| 2 | **推荐用 supervisord** 替代 | 纯进程管理器，不要求 PID 1 身份；`autorestart` 实测通过 |
| 3 | **`supervisorctl` 控制端不可用** | RPC 监听线程未创建，socket FD 为 0；服务定义须写死在镜像里 |

**一句话方案**：

```dockerfile
FROM ghcr.io/chaitin/monkeycode-runner/devbox:latest
RUN pip3 install --no-cache-dir --break-system-packages supervisor
COPY supervisord.conf /etc/supervisor/supervisord.conf
CMD ["/usr/local/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]
```

---

## 第一部分：为什么 systemd 不可行

### 1.1 核心结论

**这不是配置问题，是平台架构决定的。**

三条源码级证据：

| # | 证据 | 来源 |
|---|---|---|
| 1 | `images` 表**只有 `name` 字段**，无任何启动命令/init 配置项 | `backend/ent/schema/image.go` |
| 2 | `virtualmachines` 表只有 cores/memory/os/version，**无 kernel cmdline** | `backend/ent/schema/virtualmachine.go` |
| 3 | 全部源码中**不存在** `firecracker`、`virtio-mmio`、`root=/dev/vda` 等字符串 | 全仓 grep：0 匹配 |

**推论**：Firecracker 调度、`/firecracker-init` 分发、MMDS 配置的实现**不在开源仓库里**，而在未开源的沙箱组件（可能是独立的 `hostd`/`sandboxd`）。

因此「fork 后改代码加 `-append`」也走不通——关键代码不在仓库中。

### 1.2 平台架构

```
MonkeyCode (开源)
  ├─ images 表：只有 name
  ├─ virtualmachines 表：只有资源规格
  └─ 通过 Host / VirtualMachine 记录 VM ID
        ↓ 调用
未开源沙箱组件
  ├─ 创建 Firecracker microVM
  ├─ 注入 /firecracker-init
  ├─ 配置 MMDS (/init/ip, /init/idcmd, /init/image_config)
  └─ 设置 -append "init=/firecracker-init ..."
```

**你能控制的只有镜像内容。** PID 1、启动参数、网络配置全在未开源组件手里。

### 1.3 各条路径的可行性

| 路径 | 可行性 | 原因 |
|---|---|---|
| 平台开放 `-append` | ❌ | 源码无此配置项，关键实现未开源 |
| 平台开放 init 命令配置 | ❌ | `images` 表无相关字段 |
| 镜像 CMD 覆盖 | ❌ | systemd 拒绝非 PID 1 身份，实测静默 exit=1 |
| 修改 `/firecracker-init` | ❌ | 该文件不在镜像内，是平台注入的 |
| 改平台源码 | ❌ | firecracker 代码不在仓库 |
| **改用 supervisord** | ✅ | 不要求 PID 1 身份 |

---

*（下接第二部分：环境实测数据）*---

## 第二部分：环境实测数据

### 2.1 系统身份

```
PID 1        : /firecracker-init  (ELF 64-bit 静态 Go 二进制, 6561954 bytes)
              时间戳 2026-08-04 14:15 —— 平台注入，非镜像内容
内核         : 6.6.116
Hypervisor   : KVM (Firecracker microVM)
发行版       : Debian GNU/Linux 12 (bookworm)
systemd      : 252 (252.39-1~deb12u2)  已安装于 /lib/systemd/systemd
              时间戳 2026-04-27 —— 来自镜像（Debian 基础层自带）
CPU          : 2 核
```

内核启动命令行：

```
console=ttyS0 reboot=k panic=1 init=/firecracker-init pci=off \
virtio_mmio.device=4K@0xc0001000:5 root=/dev/vda rw \
virtio_mmio.device=4K@0xc0002000:6 virtio_mmio.device=4K@0xc0003000:7
```

### 2.2 平台注入证据

| 文件 | 时间戳 | 来源 |
|---|---|---|
| `/etc/debian_version` | 2026-01-02 | 镜像层 |
| `/usr/local/go/bin/go` | 2026-01-08 | 镜像层 |
| `/usr/bin/zsh` | 2026-01-03 | 镜像层 |
| `/go` | 2026-04-10 | 镜像层 |
| `/lib/systemd/systemd` | 2026-04-27 | 镜像层（Debian 自带） |
| **`/firecracker-init`** | **2026-08-04 14:15** | **平台注入** |
| `/usr/local/lib/tun/tun` | 2026-09-30 23:17 | 平台注入（开机时刻） |

镜像内文件集中在 2026-01 ~ 2026-04；`/firecracker-init` 单独落在 2026-08，明显不属于同一批构建产物。

### 2.3 权限与能力

| 项目 | 实测值 | 说明 |
|---|---|---|
| UID | 0 | root |
| CapEff / CapPrm / CapBnd | `000001ffffffffff` | 全集，含 `cap_sys_admin` |
| user namespace | `max_user_namespaces=31846`，`unshare -U` OK | 支持 |
| cgroup namespace | `unshare --cgroup` OK | 支持 |
| overlayfs | `/proc/filesystems` 中存在 | 支持 |
| `unshare --pid --mount` | OK | 支持 |
| `chroot` | OK | 支持 |
| `mount -t tmpfs` | OK | 支持 |

### 2.4 关键能力缺口

| 缺失项 | 影响 |
|---|---|
| **`/proc/modules` 不存在** | 无法 `modprobe`。内核为 `CONFIG_MODULES` 关闭或模块全内建，**不能动态加载任何模块** |
| **TUN 驱动缺失** | `mknod /dev/net/tun c 10 200` 可成功，但 `ioctl(TUNSETIFF)` 返回 `ENODEV`（Errno 19）。**节点可建，驱动不存在** |
| **无 DHCP 客户端** | 无 `dhclient`/`udhcpc`/`dhcpcd`。IP 由 MMDS 静态注入 |
| **无容器运行时** | 无 docker/podman/ctr/runc/crun |
| **AppArmor / audit 模块缺失** | `/sys/module/apparmor`、`/sys/module/audit` 均缺失 |

### 2.5 cgroup 状态

```
挂载              : none /sys/fs/cgroup cgroup2 rw,relatime 0 0
cgroup.controllers : cpuset cpu io memory hugetlb pids
cgroup.subtree_control : (空)
当前 cgroup       : 0::/
```

控制器齐全是 systemd 能工作的**最关键前提**，此项已满足（但 systemd 仍因非 PID 1 身份失败）。

### 2.6 网络现状

```
eth0  : 169.254.169.252/30   (MMDS 链路)
eth0  : 192.168.19.196/20     (业务地址)
resolv.conf : nameserver 192.168.16.1
hostname    : 98851034-49e9-4e6a-85d6-04a80ffc10fc
/etc/network/interfaces : 空
/etc/fstab : 仅 "# UNCONFIGURED FSTAB FOR BASE SYSTEM"
```

MMDS 服务在 `169.254.169.254` 可达，但**需要 token**：

```
$ curl http://169.254.169.254/latest/meta-data/
No MMDS token provided. Use `X-metadata-token` or `X-aws-ec2-metadata-token` header.
```

> **推论：Debian cloud-image 那套依赖 cloud-init / DHCP 拿 IP 的流程在这台机器上走不通。** 网络必须用静态配置。

### 2.7 镜像来源核验

仓库 `chaitin/DevRunner`（本地已解包：`/root/mon/DevRunner-main/`）的 devbox Dockerfile 关键片段：

```dockerfile
ARG BASE_IMAGE=ghcr.io/chaitin/monkeycode-runner/base:bookworm
FROM ${BASE_IMAGE}

ENV GOROOT=/usr/local/go GOPATH=/go GOCACHE=/go/cache \
    PATH=/usr/local/go/bin:/go/bin:${PATH}

RUN apt-get update && apt-get install -y --no-install-recommends \
        xz-utils htop iputils-ping iproute2 wget

# Go 1.25.6 官方 tarball + sha256 校验
RUN curl -fsSL "https://go.dev/dl/go1.25.6.linux-amd64.tar.gz" -o /tmp/go.tar.gz && \
    echo "${GO_SHA256}  /tmp/go.tar.gz" | sha256sum -c - && \
    tar -C /usr/local -xzf /tmp/go.tar.gz && \
    go install honnef.co/go/tools/cmd/staticcheck@latest && \
    go install mvdan.cc/gofumpt@latest && \
    go install github.com/swaggo/swag/cmd/swag@latest

# Node.js 22.22.0 官方 tar.xz + SHASUMS256 校验
RUN curl -fsSLO "https://nodejs.org/dist/v22.22.0/node-v22.22.0-linux-x64.tar.xz" && \
    grep " ... " SHASUMS256.txt | sha256sum -c - && \
    tar -xJf "..." -C /usr/local --strip-components=1 && corepack enable

ENV PIP_BREAK_SYSTEM_PACKAGES=1
RUN pip3 install --no-cache-dir requests flask django beautifulsoup4 scrapy
WORKDIR /workspace
```

**关键观察**：

- **没有 `CMD` / `ENTRYPOINT` 指令** —— config 里的 `Cmd=["bash"]` 是 Docker 默认补齐的
- **没有任何 systemd 安装或配置** —— 本机 systemd 252 来自 `debian:bookworm-slim` 基础层，与本项目无关
- **没有 `/firecracker-init`** —— 全文无任何相关引用

README 的运行方式印证「一次性容器」定位：

```bash
docker run --rm -it -v $(pwd):/workspace \
  ghcr.io/chaitin/monkeycode-runner/devbox:bookworm bash
```---

## 第三部分：`/firecracker-init` 分析

### 3.1 基本性质

```
-rwxr-xr-x  6561954  Aug  4 14:15  /firecracker-init
ELF 64-bit 静态可执行文件（内含 Go runtime）
符号表被 strip（nm 报 no symbols），但函数名字符串仍可提取
```

它负责：挂载文件系统、启动 MMDS 配置服务、读 OCI 的 entrypoint/cmd、设置 oom_score_adj、最终拉起主进程。

### 3.2 MMDS 配置键

```
/init/ip
/init/gateway
/init/dns
/init/hostname
/init/id
/init/idcmd            ← 与 /init/id 并列
/init/image_config     ← 镜像配置
```

对应日志字符串：

```
init ip route using mmds
[WARN] mmds /init/hostname is empty, skip setting hostname
[WARN] mmds /init/id is empty, skip writing /etc/machine-id
get mmds %s with response status=%s, using empty
rotating mmds token...
```

平台通过 MMDS 的 `/init/image_config` 下发镜像配置，其中包含 `cmd` 与 `entrypoint` 字段（二进制中有 `json:"cmd"`、`json:"entrypoint"` tag）。

**`/init/idcmd` 极可能是平台下发启动命令的入口**，这意味着平台**可能强制覆盖镜像 CMD**。

### 3.3 进程管理逻辑

```
starting main process:
cmd = %q
env = %q
main process exited: %d
shell process exited with err = %v, restarting...     ← 关键
[WARN] failed to set oom_score_adj for main process: %v
[WARN] failed to set oom_score_adj for shell process: %v
/proc/1/oom_score_adj
/proc/%d/oom_score_adj
dockerd-entrypoint.sh
```

> **重要**：`shell process exited with err = %v, restarting...` 表明平台会在主进程退出后**重启 shell**。这是选型时必须考虑的行为——supervisord 自身不该退出所以无影响，但若用「直接 exec 单个进程」方案，进程退出后会被拉起。

### 3.4 main 包符号

```
main.main
main.mount                                   挂载处理
main.syncClockFromPTP                        PTP 时钟同步（/dev/ptp0）
main.NewMmdsService
main.(*MmdsService).Init / Get / getToken / rotateToken / url
```

### 3.5 systemd 启动实测：静默 exit=1

在隔离的 PID namespace 中以 PID 1 身份启动：

```bash
unshare --pid --mount --cgroup --fork --mount-proc \
  /lib/systemd/systemd --system --unit=multi-user.target
```

| 场景 | 结果 |
|---|---|
| 前台直接运行 | **静默退出，exit=1，无任何日志** |
| `--log-target=console --log-level=debug` | **stderr 完全为空** |
| 后台启动后查状态 | `System has not been booted with systemd as init system (PID 1)` |
| `/run/systemd/` | 目录已存在且结构完整 |

正常启动失败会打印明确错误（`Failed to mount tmpfs` 之类），**完全没有输出说明它在极早期就返回失败**——与 systemd 强制要求 PID 1 身份一致。

---

## 第四部分：supervisord 方案（推荐）

### 4.1 选型对比

| 维度 | supervisord | OpenRC |
|---|---|---|
| 安装体积 | ~1MB（纯Python） | ~2MB + shell 工具链 |
| 是否要求 PID 1 | **否** ✅ | **是**（需自己当 PID 1 或接管） |
| Debian 12 可用性 | 需 pip 安装 | apt 可装（0.45.2-2+deb12u1） |
| 进程托管 | ✅ 实测通过 | ⚠️ 需完整 init 环境 |
| 日志管理 | ✅ 内置轮转 | ✅ 内置 |
| **推荐度** | **⭐⭐⭐⭐⭐** | ⭐⭐ 不推荐 |

**选 supervisord 的理由**：OpenRC 是 init 系统，需要接管 PID 1 才有意义，而 PID 1 被 `/firecracker-init` 占据。supervisord 是**纯进程管理器**，不要求任何特殊身份。

### 4.2 实测结果

| 测试项 | 结果 |
|---|---|
| `pip3 install supervisor` | ✅ 4.3.0 |
| 非 PID 1 环境下启动 | ✅ 成功 |
| 托管子进程 | ✅ `spawned: 'demo' with pid 7091` |
| 进程日志输出 | ✅ 独立 stdout/stderr |
| `autorestart` 自动拉起 | ✅ SIGKILL 后立即重新 spawn |
| **`supervisorctl`（TCP）** | ❌ 失败，见 4.6 |
| **`supervisorctl`（UNIX socket）** | ❌ 失败，见 4.6 |

### 4.3 pip 安装需要 `--break-system-packages`

Debian 12 的 PEP 668 保护会拦截：

```
$ pip3 install --no-cache-dir supervisor
error: externally-managed-environment
hint: See PEP 668 for the detailed specification.
```

**解决**：加 `--break-system-packages`。镜像本身已设 `PIP_BREAK_SYSTEM_PACKAGES=1`，说明官方镜像也预期这么做。

```bash
pip3 install --no-cache-dir --break-system-packages supervisor
# Successfully installed supervisor-4.3.0
# 可执行文件：/usr/local/bin/supervisord, /usr/local/bin/supervisorctl
```

### 4.4 完整 Dockerfile

```dockerfile
FROM ghcr.io/chaitin/monkeycode-runner/devbox:latest

RUN pip3 install --no-cache-dir --break-system-packages supervisor

RUN mkdir -p /etc/supervisor /var/log/supervisor && \
    cat > /etc/supervisor/supervisord.conf <<'CONF'
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid
loglevel=info

[program:sshd]
command=/usr/sbin/sshd -D -e
autostart=true
autorestart=true
priority=10
stdout_logfile=/var/log/supervisor/sshd.log
stderr_logfile=/var/log/supervisor/sshd.err

[unix_http_server]
file=/var/run/supervisor.sock
chmod=0700

[supervisorctl]
serverurl=unix:///var/run/supervisor.sock

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface
CONF

# 修复 sshd 需要的 host key（镜像内通常没有）
RUN mkdir -p /run/sshd && \
    ssh-keygen -A && \
    printf 'PermitRootLogin prohibit-password\n' > /etc/ssh/sshd_config.d/00-permit-root.conf

CMD ["/usr/local/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]
```

> **注意**：平台会覆盖镜像的 `ENV`。实测 PATH 缺少镜像 ENV 中声明的 `/usr/local/go/bin`、`/go/bin`，如需 Go 工具链要在 Dockerfile 里显式重声明 `ENV PATH`。### 4.5 添加自己的服务

在配置文件追加 `[program:xxx]` 段即可：

```ini
[program:api]
command=/usr/local/bin/python3 /workspace/app.py
directory=/workspace
autostart=true
autorestart=unexpected
startsecs=3
startretries=3
stopsignal=TERM
stopwaitsecs=10
stopasgroup=true
killasgroup=true
priority=20
environment=PYTHONUNBUFFERED="1"
stdout_logfile=/var/log/supervisor/api.log
stderr_logfile=/var/log/supervisor/api.err
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=5
redirect_stderr=false
```

**常用参数**：

| 参数 | 作用 |
|---|---|
| `priority` | 数值越小越先启动；需要依赖的放前面 |
| `startsecs` | 进程稳定运行多少秒才算启动成功 |
| `autorestart=unexpected` | 仅异常退出时重启（比 `true` 更温和，推荐） |
| `stopasgroup=true` | 停止时连同整个进程组一起停 |
| `stdout_logfile_maxbytes` | 单日志上限，配合 `backups` 轮转 |
| `environment` | 给进程设环境变量 |

### 4.6 重要限制：supervisorctl 控制端不可用

**实测结论：本环境中 `supervisorctl` 无法连接 supervisord。**

现象：

```bash
$ supervisorctl -c /etc/supervisor/supervisord.conf status
http://127.0.0.1:19099 refused connection
# 或
unix:///tmp/supd-test.sock no such file
```

排查过程（已确认非配置错误）：

| 排查项 | 结果 |
|---|---|
| 配置文件是否正确 | ✅ `inet_http_server=127.0.0.1:19099` 已在文件中 |
| 端口是否被占 | ✅ `ss -ltn` 无占用 |
| Python 能否 bind socket | ✅ `AF_UNIX bind OK` / `AF_INET bind OK` |
| Python HTTP 服务能否工作 | ✅ 实测 `HTTP fetch: b'ok'` |
| seccomp 是否拦截 | ❌ `Seccomp: 0`，未启用 |
| supervisord 线程数 | ⚠️ **只有 1 个**（正常应含 RPC 线程） |
| supervisord socket FD 数 | ⚠️ **0 个** |

**根因判断**：supervisord 进程本身启动正常、子进程托管正常、日志正常，但 **RPC 监听线程未能创建**，导致 socket FD 为 0。最可能的原因是 Python `threading` 在此环境的限制，或与沙箱的 `bpfilter_umh` 过滤层有关。

**影响与应对**：

| 影响 | 应对 |
|---|---|
| 不能用 `supervisorctl` 管理 | 改用「配置即代码」：服务定义写死在镜像里，重建即生效 |
| 不能运行时动态启停 | 用进程信号管理（见 4.7） |
| `autorestart` **不受影响** | ✅ 实测正常，这是核心价值 |

> **好消息**：`autorestart` 才是这套方案的主要价值点，它完全不依赖 RPC。

### 4.7 备选：用信号管理替代 supervisorctl

```bash
#!/bin/bash
# /usr/local/bin/svc
# 用法: svc <program-name> {start|stop|restart|status}
CONF=/etc/supervisor/supervisord.conf
case "$2" in
  start)   supervisorctl -c $CONF start "$1" 2>/dev/null || pgrep -f "marker:$1" >/dev/null && echo "已在运行" ;;
  stop)    supervisorctl -c $CONF stop "$1"  2>/dev/null || pkill -f "marker:$1" ;;
  restart) supervisorctl -c $CONF restart "$1" 2>/dev/null || { pkill -f "marker:$1"; sleep 2; } ;;
  status)  pgrep -af "marker:$1" || echo "not running" ;;
esac
```

更可靠的做法是为每个服务在配置里加唯一标记（`environment=MARKER="<name>"`），用 `pgrep`/`pkill` 管理：

```bash
pgrep -f 'app.py'          # 查
pkill -f 'app.py'          # 停（注意 autorestart 会拉起）
```

### 4.8 验证清单

```bash
# 1. supervisord 存活
pgrep -af supervisord

# 2. 子进程被托管
ps -eo pid,ppid,comm --no-headers | grep -E 'supervisord|sshd'

# 3. autorestart 生效（杀掉子进程，观察是否被拉起）
pkill -9 -f 'sshd -D'
sleep 5
pgrep -af 'sshd -D'      # 应当重新出现

# 4. 日志正常写入
tail -f /var/log/supervisor/sshd.log

# 5. supervisord 主日志
tail -50 /var/log/supervisor/supervisord.log
```

---

## 第五部分：备选方案

### 5.1 OpenRC（不推荐）

**为什么不推荐**：OpenRC 是 **init 系统**，设计前提是它自己就是 PID 1（或被 PID 1 调用）。在当前环境中 PID 1 是 `/firecracker-init`，无法替换，导致 runlevel、依赖检查全部失真。

Debian 12 可用性（apt 源可达）：

```bash
$ apt-cache policy openrc
openrc:
  Installed: (none)
  Candidate: 0.45.2-2+deb12u1
       500 https://mirrors.tuna.tsinghua.edu.cn/debian bookworm/main amd64 Packages
```

若坚持要用：

```dockerfile
FROM ghcr.io/chaitin/monkeycode-runner/devbox:latest

RUN apt-get update && apt-get install -y --no-install-recommends openrc \
    && rm -rf /var/lib/apt/lists/*

RUN rm -f /etc/init.d/* 2>/dev/null; mkdir -p /etc/runlevels/default

RUN cat > /etc/init.d/myapp <<'EOF'
#!/sbin/openrc-run
name="My App"
description="My Application"
command="/usr/local/bin/python3"
command_args="/workspace/app.py"
command_background="yes"
pidfile="/run/myapp.pid"
output_log="/var/log/myapp.log"
error_log="/var/log/myapp.err"
depend() { need net; after firewall; }
start_pre() { checkpath --directory --mode 0755 /run; }
EOF

RUN chmod +x /etc/init.d/myapp && \
    rc-update add myapp default 2>/dev/null || \
    ln -sf /etc/init.d/myapp /etc/runlevels/default/myapp

CMD ["/sbin/openrc", "default"]
```

**已知问题**：

| 问题 | 说明 |
|---|---|
| 不是 PID 1 | `openrc default` 在非 PID 1 下会警告，部分服务无法 start |
| runlevel 无效 | 没有 init 进程来「进入」runlevel |
| 依赖检查失真 | `depend()` 中 net/firewall 状态检测不准确 |
| 手动启动 | 需逐个 `rc-service myapp start`，无法批量 |

### 5.2 直接 exec 目标进程（最简）

只需要一个常驻服务时：

```dockerfile
CMD ["/usr/local/bin/python3", "/workspace/app.py"]
```

平台会通过 `/init/image_config` 下发 cmd 并 exec 它。

> **注意**：`firecracker-init` 有 `shell process exited with err = %v, restarting...` 逻辑，**主进程退出后会被平台重启**。若不希望如此，需在应用内部维持常驻。

### 5.3 自建轻量守护脚本（零依赖）

```dockerfile
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
CMD ["/usr/local/bin/entrypoint.sh"]
```

```bash
#!/bin/bash
declare -A PROCS=(
  [sshd]="/usr/sbin/sshd -D -e"
  [api]="/usr/local/bin/python3 /workspace/app.py"
)
for name in "${!PROCS[@]}"; do
  (
    while true; do
      ${PROCS[$name]} >> /var/log/$name.log 2>&1
      echo "[$(date -Is)] $name exited, restarting in 3s" >> /var/log/daemon.log
      sleep 3
    done
  ) &
done
wait
```

最可控、无额外依赖，但没有日志轮转和状态查询。

### 5.4 四种方案对比

| 方案 | 复杂度 | 依赖 | PID1 要求 | autorestart | 日志轮转 | 运行时管理 |
|---|---|---|---|---|---|---|
| **supervisord** | 中 | Python | ❌ 不需要 | ✅ 实测通过 | ✅ | ⚠️ 不可用 |
| OpenRC | 高 | 系统包 | ⚠️ 实际需要 | ✅ | ✅ | ⚠️ 受限 |
| shell 守护 | 低 | 无 | ❌ 不需要 | ✅ | ❌ | ❌ 自己实现 |
| 直接 exec | 最低 | 无 | ❌ 不需要 | ⚠️ 平台会重启 | ❌ | ❌ |

**推荐**：

1. 单个常驻服务 → **5.2 直接 exec**
2. 多服务统一管理 → **第四部分 supervisord**
3. 极端受限 → **5.3 shell 守护**---

## 第六部分：实施步骤

### 6.1 以 supervisord 为例

```bash
# 1. 本地验证
docker run --rm -it ghcr.io/chaitin/monkeycode-runner/devbox:latest bash -c "
  pip3 install --break-system-packages supervisor && supervisord --version
"

# 2. 构建
docker build -t my-devbox:supervisor .

# 3. 推送
docker tag my-devbox:supervisor ghcr.io/<你的账号>/my-devbox:supervisor
docker push ghcr.io/<你的账号>/my-devbox:supervisor

# 4. 在 MonkeyCode 平台替换镜像地址，重新创建开发环境

# 5. 验证（进入环境后）
pgrep -af supervisord
tail -50 /var/log/supervisor/supervisord.log
```

### 6.2 静态网络配置（若你的服务需要固定 IP）

平台通过 MMDS 注入网络，supervisord 接管后需要自己写静态配置：

```bash
cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address 192.168.19.196
    netmask 255.255.240.0
    gateway 192.168.19.1
    dns-nameservers 192.168.16.1
EOF
chmod 600 /etc/network/interfaces

# 若 systemd-resolved 未启用，resolv.conf 要是普通文件
rm -f /etc/resolv.conf
echo 'nameserver 192.168.16.1' > /etc/resolv.conf
```

> `/etc/network/interfaces` 当前**不存在且为空**。上面按实测值反推，换 IP 段时务必同步更新。

### 6.3 注意事项

1. **不要依赖 `systemctl`** —— systemd 永远不会是 PID 1
2. **不要修改 `/firecracker-init`** —— 平台注入，改了会被覆盖，且 PID 1 崩溃会触发内核 `panic=1` 直接挂机
3. **pip 安装务必加 `--break-system-packages`** —— 否则被 PEP 668 拦截
4. **sshd 需要 host key** —— 镜像里通常没有，`ssh-keygen -A` 生成
5. **SSH host key 需持久化** —— 重建环境后会变，固定后才能免密登录
6. **日志目录要预建** —— Dockerfile 里 `mkdir -p`，避免运行期无权限
7. **平台会覆盖 ENV** —— 需要的 PATH 要显式重声明

### 6.4 回退

把镜像 tag 指回 `ghcr.io/chaitin/monkeycode-runner/devbox:latest` 重新部署即可，无需改动平台。

---

## 附录 A：已验证不可行的路径

为避免重复排查，记录以下**已验证不可行**的方案：

| 尝试 | 结果 |
|---|---|
| 在 guest 内加载内核模块（`modprobe`） | ❌ `/proc/modules` 不存在 |
| 在 guest 内使用 TUN | ❌ `ioctl(TUNSETIFF)` → `ENODEV`，驱动未编入内核 |
| 用 `unshare` 让 systemd 当 PID 1 | ❌ systemd 静默 exit=1 |
| 通过 LXC 镜像获得 systemd | ❌ LXC 需宿主内核提供网络栈，且无 `lxc-start` 运行时 |
| `systemctl enable` | ❌ 无法连接 bus（`Failed to connect to bus: Host is down`） |
| 在镜像里改 `/firecracker-init` | ❌ 该文件不在镜像内，是平台注入的 |
| 在镜像里改 CMD 让 systemd 当 init | ❌ systemd 强制要求 PID 1 身份 |
| 改用 `devbox:bookworm` 等其他 tag | ❌ 同一套 Dockerfile，同样不含 init 管理 |
| 用 `dockerd-entrypoint.sh` 包装 | ❌ 镜像内无此文件，PID 1 仍是 `/firecracker-init` |
| 改平台源码加 `-append` | ❌ firecracker 实现不在开源仓库 |

## 附录 B：MonkeyCode 平台信息

| 项目 | 内容 |
|---|---|
| 仓库 | <https://github.com/chaitin/MonkeyCode> |
| 许可证 | **AGPL-3.0** |
| 定位 | 企业级 AI 开发平台，内置云端开发环境管理 |
| 部署 | `bash -c "$(curl -fsSL 'https://monkeycode-ai.com/online/install')"` |
| 推荐配置 | 2C / 4GB / 40GB |
| 文档 | <https://monkeycode.docs.baizhi.cloud/> |
| 镜像仓库 | <https://github.com/chaitin/DevRunner> |

**仓库结构**：

```
backend/          后端（含沙箱调度，但 firecracker 实现不在其中）
frontend/         前端
desktop/          桌面端
docs/             文档
.monkeycode/      项目配置
CONTEXT.md        项目上下文
```

**关键 schema**：

`backend/ent/schema/image.go` —— 镜像表只有 `name`：

```go
func (Image) Fields() []ent.Field {
    return []ent.Field{
        field.UUID("id", uuid.UUID{}).Unique(),
        field.UUID("user_id", uuid.UUID{}),
        field.String("name").NotEmpty(),        // ← 只有镜像名
        field.String("remark").Optional(),
        field.String("extension_package_id").Optional(),
        field.String("extension_image_id").Optional(),
        field.String("extension_version").Optional(),
        field.Time("created_at").Default(time.Now),
        field.Time("updated_at").Default(time.Now).UpdateDefault(time.Now),
    }
}
```

`backend/ent/schema/host.go` —— 只有资源规格，无 kernel 参数：

```go
field.String("hostname").Optional(),
field.String("arch").Optional(),
field.Int("cores").Optional(),
field.Int("weight").Default(1),
field.Int64("memory").Optional(),
field.Int64("disk").Optional(),
field.String("os").Optional(),
field.String("external_ip").Optional(),
field.String("internal_ip").Optional(),
```

> `cores` / `memory` / `disk` 字段存在，但消费这些字段的 VM 创建逻辑在未开源组件中，仓库里无法修改。

## 附录 C：本机相关进程

```
PID 1        /firecracker-init              guest 侧 bootstrap（挂载 + MMDS + exec 主进程）
PID 447/458  agent                           平台 agent
PID 664      /usr/local/lib/tun/tun run     网络代理（宿主机侧工作）
PID 174      bpfilter_umh                    沙箱字节码过滤（BPF）
/app/agent                                    平台 agent 目录
```

`bpfilter_umh` 的存在说明平台有自定义安全过滤层——这可能与 supervisord 的 RPC 线程创建失败（4.6）有关。

## 附录 D：给平台的提问清单

若需推动平台侧支持 systemd：

1. **是否开放 `-append` 或自定义内核启动参数？** 这是 systemd 当 PID 1 的唯一入口。
2. **MMDS 的 `/init/idcmd` 键如何使用？** 它能否下发自定义 init 路径？
3. **`/init/image_config` 的字段结构是什么？** `cmd` 是否被平台强制覆盖？
4. **`dockerd-entrypoint.sh` 的作用是什么？** 二进制中引用了，但镜像内无此文件。
5. **`firecracker-init` 的源码是否可获取？** 若是，可直接阅读 `main.main` 确认是否有 systemd 分支。

## 附录 E：参考事实速查

```bash
# 环境速查
cat /etc/os-release
uname -r
ps -p 1 -o pid,comm,args --no-headers
cat /proc/cmdline
cat /sys/fs/cgroup/cgroup.controllers
ip -o addr show

# MMDS（需 token）
curl -H "X-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/

# 镜像元数据（ghcr.io 匿名 token）
curl -s "https://ghcr.io/token?scope=repository:chaitin/monkeycode-runner/devbox:pull&service=ghcr.io" \
  | sed -n 's/.*"token":"\([^"]*\)".*/\1/p'

# firecracker-init 分析
strings -n 5 /firecracker-init | grep -E '^main\.|/init/[a-z_]+'
```

---

*文档整合自 `systemd-as-pid1-guide.md` 与 `process-management-guide.md`*