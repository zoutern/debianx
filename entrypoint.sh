#!/bin/sh
# 容器引导脚本(由 /startup_wrapper.sh exec 调用):
#   1. 应用环境变量覆盖(root 公钥 / 隧道 Token)
#   2. 准备 systemd / sshd 所需目录
#   3. exec /sbin/init —— systemd 占据 PID 1, 由它拉起 ssh.service 与 tun.service
# 覆盖了 CMD 时(如 docker run image bash)则直接执行该命令, 不启动 systemd。

DEFAULT_ROOT_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbOngF8zJjVVvAlDWjZnGE83jXrt3aDviPCqIIE5Ju6"

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
# /run/sshd: sshd 权限分离目录; /run/systemd/system: 供脚本判定 init 类型
mkdir -p /run/sshd /run/systemd/system

# ---- 4. 确保两个服务开机自启(enable 为离线操作, 幂等) ----
systemctl enable ssh.service >/dev/null 2>&1 || true
systemctl enable tun.service >/dev/null 2>&1 || true

# ---- 5. 交棒 ----
if [ "$#" -gt 0 ]; then
    exec "$@"
fi

log " handing over to systemd (PID 1) ..."
exec /sbin/init
