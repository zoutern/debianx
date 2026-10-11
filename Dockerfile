# debianx — Debian GNU/Linux 12 (bookworm) 容器镜像
#   PID 1 = systemd
#   sshx  = SSH 一键配置脚本(scripts/ssh.sh, 交互菜单 + 命令行)
#   tun   = Cloudflare Tunnel(sing-box 内嵌 cloudflared, scripts/tun.sh)
# 启动链: /startup_wrapper.sh -> /entrypoint.sh -> /sbin/init (exec, 保持 PID 1)
FROM debian:bookworm

ARG DEBIAN_FRONTEND=noninteractive

# 基础依赖: systemd(PID 1) + openssh-server + 下载工具
# 容器内 systemd 加固: multi-user 默认 target; mask 容器内必失败/无意义的单元
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      systemd \
      systemd-sysv \
      openssh-server \
      ca-certificates \
      curl \
      bash \
 && systemctl set-default multi-user.target \
 && systemctl mask getty@tty1.service systemd-networkd-wait-online.service systemd-firstboot.service \
 && rm -rf /var/lib/apt/lists/*

# 置空 machine-id, 让 systemd 在每次容器启动时自行生成临时 id
RUN rm -f /etc/machine-id && touch /etc/machine-id

# 集成脚本(固化进镜像, 升级脚本只需重新下载后 docker build)
COPY scripts/ssh.sh /opt/scripts/ssh.sh
COPY scripts/tun.sh /opt/scripts/tun.sh
RUN chmod 755 /opt/scripts/ssh.sh /opt/scripts/tun.sh \
 && ln -sf /opt/scripts/ssh.sh /usr/local/bin/sshx

# ---- SSH: 内置默认 root 公钥, 放行 root 登录 ----
# 仍可用环境变量 ROOT_PUBKEY 在运行时覆盖(见 entrypoint.sh)
ARG DEFAULT_ROOT_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbOngF8zJjVVvAlDWjZnGE83jXrt3aDviPCqIIE5Ju6"
RUN set -eux; \
    mkdir -p /run/sshd /root/.ssh /etc/ssh/sshd_config.d; \
    printf '%s\n' "$DEFAULT_ROOT_PUBKEY" > /root/.ssh/authorized_keys; \
    chmod 700 /root/.ssh; \
    chmod 600 /root/.ssh/authorized_keys; \
    ssh-keygen -A; \
    printf '%s\n' 'PermitRootLogin yes' 'PasswordAuthentication yes' 'PubkeyAuthentication yes' \
      > /etc/ssh/sshd_config.d/50-debianx.conf; \
    systemctl enable ssh.service >/dev/null 2>&1 || \
      ln -sf /lib/systemd/system/ssh.service /etc/systemd/system/multi-user.target.wants/ssh.service

# ---- tun(Cloudflare Tunnel): 构建期安装, 写入默认 Token 并注册开机自启 ----
# 仍可用环境变量 TUN_TOKEN 在运行时覆盖(见 entrypoint.sh)
# 注: tun.sh 通过 /run/systemd/system 目录判断 init 类型, 构建期先创建再清理
ARG DEFAULT_TUN_TOKEN="eyJhIjoiNzc2M2I4YzZjZjg0NDViZDMwMWE0OWIzZjZhMzM1MDUiLCJ0IjoiNjUyODc5YTYtNzFmNy00ODBhLTk3ZTItNGFhZDljMWFiODIwIiwicyI6Ik0ySXpPRGxtTTJRdE5qZ3pZaTAwTW1FMkxUbGpOak10TmpnNFkyRTBOakEwWWpRdyJ9"
RUN set -eux; \
    mkdir -p /run/systemd/system; \
    sh /opt/scripts/tun.sh --token "$DEFAULT_TUN_TOKEN" --no-start; \
    systemctl enable tun.service >/dev/null 2>&1 || true; \
    rm -rf /run/systemd/system

# ---- 启动链 ----
COPY entrypoint.sh /entrypoint.sh
COPY startup_wrapper.sh /startup_wrapper.sh
RUN chmod 755 /entrypoint.sh /startup_wrapper.sh

ENV container=docker

# systemd 作为 PID 1 的标准停止信号
STOPSIGNAL SIGRTMIN+3

ENTRYPOINT ["/startup_wrapper.sh"]
# CMD 写成 shell 形式: 一些托管平台按镜像配置判断"是否 distroless"(无 shell),
# 用 bash 包一层可通过检测; entrypoint 内仍 exec /sbin/init, systemd 依旧占据 PID 1。
# systemd 无法运行的环境(k8s/普通 docker run)下 entrypoint 自动降级为直跑模式。
CMD ["/bin/bash", "-c", "exec /sbin/init"]
