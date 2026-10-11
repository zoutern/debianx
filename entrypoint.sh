#!/bin/sh
# 容器引导脚本(由 /startup_wrapper.sh exec 调用):
#   1. 应用环境变量覆盖(root 公钥 / 隧道 Token)
#   2. 探测 systemd 能否在本容器内运行:
#        可运行   -> exec /sbin/init, systemd 以 PID 1 拉起 ssh/tun 两个服务
#        不可运行 -> 直跑模式: tun 后台自动重启循环, sshd 前台占据 PID 1
#   3. 覆盖了 CMD 时(如 docker run image bash)直接执行该命令, 不走以上逻辑

DEFAULT_ROOT_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbOngF8zJjVVvAlDWjZnGE83jXrt3aDviPCqIIE5Ju6"
TUN_BIN="/usr/local/lib/tun/tun"

log() { printf '[entrypoint] %s\n' "$*"; }

# ---- 1. root 公钥: ROOT_PUBKEY 覆盖镜像内置默认值 ----
if [ -n "${ROOT_PUBKEY:-}" ]; then
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    printf '%s\n' "$ROOT_PUBKEY" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    log "root 公钥已由 ROOT_PUBKEY 环境变量覆盖"
elif [ ! -s /root/.ssh/authorized_keys ]; then
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    printf '%s\n' "$DEFAULT_ROOT_PUBKEY" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    log "authorized_keys 为空, 已写回默认 root 公钥"
fi

# ---- 2. 隧道 Token: TUN_TOKEN 覆盖镜像内置默认值 ----
# tun.service(systemd)从 /etc/tun/env 读取 CF_TUNNEL_TOKEN; 管理命令 tun 读 /etc/tun/token
if [ -n "${TUN_TOKEN:-}" ]; then
    mkdir -p /etc/tun
    printf '%s' "$TUN_TOKEN" > /etc/tun/token
    chmod 600 /etc/tun/token
    printf 'CF_TUNNEL_TOKEN="%s"\n' "$TUN_TOKEN" > /etc/tun/env
    chmod 600 /etc/tun/env
    log "Tunnel Token 已由 TUN_TOKEN 环境变量覆盖"
fi

# ---- 3. 目录准备 ----
mkdir -p /run/sshd
mkdir -p /run/systemd/system 2>/dev/null || true

# ---- 4. 运行模式探测 ----
# FORCE_SYSTEMD: 1=强制 systemd 模式, 0=强制直跑模式, 缺省 auto 自动探测
MODE=""
case "${FORCE_SYSTEMD:-auto}" in
    1|true|yes|systemd)  MODE=systemd ;;
    0|false|no|fallback) MODE=fallback ;;
esac
if [ -z "$MODE" ]; then
    if [ -n "${KUBERNETES_SERVICE_HOST:-}" ]; then
        MODE=fallback            # k8s/PaaS 平台无特权, systemd 起不来
    elif [ ! -w /sys/fs/cgroup ]; then
        MODE=fallback            # cgroup 只读(普通 docker run), systemd 无法挂载
    else
        MODE=systemd
    fi
fi

# ---- 5. 用户覆盖了 CMD 的情况 ----
if [ "$#" -gt 0 ]; then
    exec "$@"
fi

# ---- 6a. systemd 模式 ----
if [ "$MODE" = "systemd" ]; then
    systemctl enable ssh.service >/dev/null 2>&1 || true
    systemctl enable tun.service >/dev/null 2>&1 || true
    log " handing over to systemd (PID 1) ..."
    exec /sbin/init
fi

# ---- 6b. 直跑模式(无 systemd): PID 1 常驻不退出, 保证平台探测/终端/文件管理可用 ----
log "systemd 不可用(k8s/无特权环境), 进入直跑模式: tun 后台守护 + sshd 自动重启"
log "诊断: user=$(id -un 2>&1) sshd=$(command -v sshd 2>/dev/null || echo MISSING) cgroup=$(test -w /sys/fs/cgroup 2>/dev/null && echo rw || echo ro)"

mkdir -p /run/sshd 2>/dev/null || log "警告: mkdir /run/sshd 失败(/run 只读?)"

# tun 读 /etc/tun/edge-ip 决定边缘连接协议(auto/4/6), 与 systemd 模式保持一致
EDGE_ARGS=""
case "$(cat /etc/tun/edge-ip 2>/dev/null)" in
    4) EDGE_ARGS=" --edge-ip-version 4" ;;
    6) EDGE_ARGS=" --edge-ip-version 6" ;;
esac

if [ -s /etc/tun/token ]; then
    touch /var/log/tun.log 2>/dev/null || true
    ( while :; do
          CF_TUNNEL_TOKEN="$(cat /etc/tun/token)" "$TUN_BIN" run$EDGE_ARGS >> /var/log/tun.log 2>&1
          printf '[entrypoint] tun 已退出, 5 秒后自动重启\n'
          sleep 5
      done ) &
    log "tun 已启动(后台自动重启), 日志: /var/log/tun.log 或 docker logs"
else
    log "未配置 Tunnel Token (/etc/tun/token 为空), 跳过 tun"
fi

# sshd 崩溃也不许容器退出: 由 PID 1 循环托管, 错误直接进 stdout/docker logs
log "启动 sshd (端口 22), 若异常退出将自动重启"
while :; do
    /usr/sbin/sshd -D -e 2>&1
    log "sshd 已退出 (code=$?), 2 秒后重启 —— 错误见上一行"
    sleep 2
done
