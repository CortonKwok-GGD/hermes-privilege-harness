# Monkey Patch 管理

本项目（hermes-vip）含三个子系统，patch 按子系统分类，严禁混放。

| 子目录 | 子系统 | 内容 |
|---|---|---|
| hermes-vip/ | Hermes VIP 核心 | profiles/moa_config/config_defaults/model_switch/inventory/credential_files 6 件套 |
| hermes-run/ | hermes-run（宿主侧命令包装/沙箱） | guard.py 媒体 staging 拦截等 |
| ctl-container/ | ctl 容器子系统 | container/ 下 ctl.sh、hermes-run.sh、hermes-serve-proxy.sh 相关 |
| archive/ | 历史快照（只读留档） | runtime-diff-20260827/（2026-08-27 runtime 差异备份） |

## 纪律

- **VIP 核心补丁的注入机制**在 `deploy/dd-patches.sh`（anchor-based，幂等，可单文件执行 `bash dd-patches.sh <file>.py`），补丁清单见 `hermes-vip/README.md`。
- **hermes-run / ctl 的改动直接改源码**（`hermes-plugin/`、`container/`），git 提交即补丁；本目录只放说明/索引，不复制代码。
- **版本漂移类差异（upstream 演进）不进本目录**，由 `deploy/deploy-sync.sh`（rsync）解决——上过当：context_compressor/api_server/run.py/memory_tool 曾被误当 VIP 补丁。
