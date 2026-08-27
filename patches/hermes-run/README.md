# hermes-run 子系统

范围：宿主侧命令包装/沙箱 —— `container/hermes-run.sh`、`hermes-plugin/guard.py`、`hermes-plugin/sandbox/`。
容器内**不需要** hermes-run，它本应跑在 Mac 宿主（guard 包装后由宿主执行）。

## 补丁记录

- **guard.py 媒体 staging 拦截**（commit 56acafd）：`_stage_paths_in_cmd()` 在 terminal 命令包装点扫描宿主路径（`/Users/...`、`~/...`），若是媒体文件则拷贝到容器可见目录 `~/hermes-workspace/tmp/hermes-media/flat-images/guard_<ts>_<name>`，再传给 hermes-run。
  - 背景：桌面附件走原始宿主路径，容器看不到 `~/.hermes/cache`；`terminal.backend: docker` 能开字节上传但会破坏宿主侧 hermes-run 执行，故用 guard 拦截替代。
  - 部署：install.sh 从 `hermes-plugin/guard.py` cp 到 `~/.hermes/plugins/hermes-vip/guard.py`（源码即补丁，git 提交即固化）。
  - 验证：v2 已实测通过（截屏 PNG 成功 staging 并被容器解码）。
