# debianx

Debian GNU/Linux 12 (bookworm) 容器镜像，**PID 1 为 systemd**，内置两套一键脚本：

| 命令 | 说明 |
|------|------|
| `sshx` | SSH 一键配置脚本（[scripts/ssh.sh](scripts/ssh.sh)）：交互菜单 + 命令行，管理端口/认证/公钥/密码，重装 sshd |
| `tun`  | Cloudflare Tunnel 管理器（[scripts/tun.sh](scripts/tun.sh) 安装的 sing-box 内嵌 cloudflared）：启停/日志/换 Token/边缘 IP 切换 |

镜像内置的默认值：

- **默认 root 公钥**：`ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbOngF8zJjVVvAlDWjZnGE83jXrt3aDviPCqIIE5Ju6`（已写入 `/root/.ssh/authorized_keys`）
- **默认 Tunnel Token**：已写入 `/etc/tun/token` 与 `/etc/tun/env`，`tun.service` 开机自启

## 启动链（双模式）

```
/startup_wrapper.sh ──exec──▶ /entrypoint.sh
                                  ├─ systemd 可运行(--privileged 等) ──exec──▶ /sbin/init (PID 1)
                                  │                                              ├─ ssh.service (sshd, 端口 22)
                                  │                                              └─ tun.service (Cloudflare Tunnel)
                                  └─ systemd 不可运行(k8s/普通 docker run) ──▶ 直跑模式:
                                                                                 tun 后台自动重启 + sshd 前台 (PID 1)
```

- `startup_wrapper.sh` 兼容把项目挂载到 `/project` 的托管平台（启动时切入该目录）；
- `entrypoint.sh` 自动探测运行模式（`FORCE_SYSTEMD` 可强制指定），保证容器在任何环境都能健康启动；
- `STOPSIGNAL SIGRTMIN+3` 保证 `docker stop` 能让 systemd 优雅关机。

## 构建

```bash
docker build -t debianx .
```

（推送 main 分支后，GitHub Actions 会自动构建 amd64/arm64 双架构镜像并发布到 `ghcr.io/zoutern/debianx`。）

## 运行

**不用任何特殊参数也能跑**（自动降级为直跑模式，sshd + tun 照常工作）：

```bash
docker run -d --name debianx -p 2222:22 debianx
```

需要完整 systemd（PID 1）时，任选其一：

```bash
# 方式一：最简单（特权模式）
docker run -d --name debianx --privileged -p 2222:22 debianx

# 方式二：Docker Engine 26+ 自动适配 systemd
docker run -d --name debianx --systemd=always -p 2222:22 debianx

# 方式三：最小权限方案（不用 privileged，cgroup v2 主机）
docker run -d --name debianx \
  --cgroupns=private \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
  --cap-add SYS_ADMIN \
  -p 2222:22 debianx
```

Podman 无需额外参数，直接 `podman run -d -p 2222:22 debianx`。

systemd 模式验证：`docker exec debianx systemctl is-system-running` 返回 `running` 或 `degraded` 即成功。

### 部署到托管平台（ClawCloud Run / Sealos / k8s 类）

直接填镜像 `ghcr.io/zoutern/debianx:latest` 即可，无需特权：

- 平台是 k8s 环境，entrypoint 会自动进入直跑模式（日志有 `[entrypoint] 进入直跑模式`）；
- **启动命令(Command/Args)留空即可**，填了也会被入口包装忽略（防止平台默认填 `/sbin/init` 导致 systemd 崩溃循环）——运行模式完全由 entrypoint 自动探测；
- 容器健康运行后，平台的**网页终端 / 文件管理**即可正常使用（镜像内含 `/bin/sh`、`/bin/bash`）；
- SSH 端口 22，隧道日志看容器日志或 `/var/log/tun.log`；
- 若平台把端口映射到别的端口，SSH 就连映射后的那个。

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
| `FORCE_SYSTEMD` | `1`=强制 systemd 模式（需特权），`0`=强制直跑模式，缺省自动探测 |

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
