# debianx

Debian GNU/Linux 12 (bookworm) 容器镜像，**PID 1 为 systemd**，内置两套一键脚本：

| 命令 | 说明 |
|------|------|
| `sshx` | SSH 一键配置脚本（[scripts/ssh.sh](scripts/ssh.sh)）：交互菜单 + 命令行，管理端口/认证/公钥/密码，重装 sshd |
| `tun`  | Cloudflare Tunnel 管理器（[scripts/tun.sh](scripts/tun.sh) 安装的 sing-box 内嵌 cloudflared）：启停/日志/换 Token/边缘 IP 切换 |

镜像内置的默认值：

- **默认 root 公钥**：`ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbOngF8zJjVVvAlDWjZnGE83jXrt3aDviPCqIIE5Ju6`（已写入 `/root/.ssh/authorized_keys`）
- **默认 Tunnel Token**：已写入 `/etc/tun/token` 与 `/etc/tun/env`，`tun.service` 开机自启

## 启动链

```
PID 1: /startup_wrapper.sh ──exec──▶ /entrypoint.sh ──exec──▶ /sbin/init (systemd)
                                                                    ├─ ssh.service   (sshd, 端口 22)
                                                                    └─ tun.service   (Cloudflare Tunnel)
```

- `startup_wrapper.sh` 兼容把项目挂载到 `/project` 的托管平台（启动时切入该目录）；
- `entrypoint.sh` 处理环境变量覆盖后 `exec /sbin/init`，因此 systemd 占据 PID 1；
- `STOPSIGNAL SIGRTMIN+3` 保证 `docker stop` 能让 systemd 优雅关机。

## 构建

```bash
docker build -t debianx .
```

（推送 main 分支后，GitHub Actions 会自动构建 amd64/arm64 双架构镜像并发布到 `ghcr.io/zoutern/debianx`。）

## 运行

systemd 需要一定权限才能在容器内作为 PID 1 运行，任选其一：

```bash
# 方式一：最简单（特权模式）
docker run -d --name debianx --privileged -p 2222:22 debianx

# 方式二：Docker Engine 26+ 自动适配 systemd
docker run -d --name debianx --systemd=always -p 2222:22 debianx

# 方式三：手动给参数（不用 privileged）
docker run -d --name debianx \
  --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --cgroupns=host \
  --security-opt seccomp=unconfined \
  -p 2222:22 debianx
```

Podman 无需额外参数，直接 `podman run -d -p 2222:22 debianx`。

## SSH 连接

默认已放行 root 登录（公钥 + 密码），root 初始无密码，公钥登录开箱即用：

```bash
ssh -p 2222 root@<宿主机>
```

进容器后可用 `sshx` 调整：

```bash
sshx                      # 交互菜单
sshx --port 2222          # 命令行改端口
sshx --add-key "root:ssh-ed25519 AAAA..."   # 追加公钥
sshx --password-auth no --permit-root prohibit-password   # 收紧认证
```

## 隧道管理

容器启动即自动连接 Cloudflare 边缘（默认 Token）。管理：

```bash
tun status      # 状态
tun log 50      # 日志
tun token <TOKEN>   # 换 Token（写入并自动重启服务）
tun edge 4      # 边缘连接强制 IPv4/IPv6/auto
```

## 环境变量（运行时覆盖默认值）

| 变量 | 作用 |
|------|------|
| `ROOT_PUBKEY` | 覆盖默认 root 公钥（写入 `/root/.ssh/authorized_keys`） |
| `TUN_TOKEN`   | 覆盖默认 Tunnel Token（写入 `/etc/tun/token` 与 `/etc/tun/env`） |

```bash
docker run -d --name debianx --privileged -p 2222:22 \
  -e ROOT_PUBKEY="ssh-ed25519 AAAA... me@host" \
  -e TUN_TOKEN="eyJ..." \
  debianx
```

## 安全提示

- 默认 Token / 公钥固化在镜像与仓库中：仓库和镜像公开时**任何能看到它的人都可使用该隧道**。对外分发请改用 `-e TUN_TOKEN=` 传入，或基于本镜像再构建私有镜像。
- GHCR 首次发布后镜像默认为**私有**，需在 GitHub → Packages → debianx → Package settings 中改为 public。

## 文件结构

```
├── Dockerfile                  # 镜像定义
├── entrypoint.sh               # 引导：环境变量覆盖 → 交给 systemd
├── startup_wrapper.sh          # ENTRYPOINT：/project 兼容 + exec 启动链
├── scripts/
│   ├── ssh.sh                  # SSH 一键配置（注册为 sshx）
│   └── tun.sh                  # Cloudflare Tunnel 安装器（安装出 tun 命令）
├── .github/workflows/
│   └── docker-image.yml        # 构建 amd64/arm64 并发布 GHCR
└── README.md
```
