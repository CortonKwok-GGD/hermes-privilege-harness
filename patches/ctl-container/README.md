# ctl 容器子系统

范围：`container/ctl.sh`（容器入口）、`container/hermes-run.sh`、`container/hermes-serve-proxy.sh`、`deploy/deploy-container-permissions.sh`。
容器侧改动直接改源码（git 提交即补丁），本目录只登记与容器运行相关的补丁/改进点。

## 登记

- **ctl.sh 挂载目标缺少存在性检查**（历史发现，待修）：挂载前应 `[ -d "$target" ]`，否则目标不存在时会创建 root 属主空目录，污染宿主。
- **媒体可见性方案**：容器不挂 `~/.hermes/cache`（隔离安全）；媒体经 symlink（`scripts/link-media-to-workspace.sh`）映射到 `~/hermes-workspace/tmp/hermes-media/`，guard staging 写入 flat-images 子目录。
