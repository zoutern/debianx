#!/bin/sh
# 容器启动包装(镜像 ENTRYPOINT):
#   1) 兼容把项目目录挂载到 /project 的托管平台 —— 启动时切入该目录
#   2) exec /entrypoint.sh —— exec 保证 systemd 最终以 PID 1 运行(而非本壳)
cd /project 2>/dev/null || true
exec /entrypoint.sh "$@"
