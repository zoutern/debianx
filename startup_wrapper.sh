#!/bin/sh
# 容器启动包装(镜像 ENTRYPOINT):
#   1) 兼容把项目目录挂载到 /project 的托管平台 —— 启动时切入该目录
#   2) exec /entrypoint.sh —— exec 保证 systemd 模式下最终以 PID 1 运行
# 注意: 故意忽略 "$@" —— 托管平台常把 "/sbin/init" 之类作为命令参数传入,
#       转发下去会让 entrypoint 再次 exec systemd, 在无特权环境陷入重启循环。
#       模式选择(systemd/直跑)完全交给 entrypoint.sh 自动探测。
cd /project 2>/dev/null || true
exec /entrypoint.sh
