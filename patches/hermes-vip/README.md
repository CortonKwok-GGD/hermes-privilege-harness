# Hermes VIP 核心补丁（6 件套）

注入机制：`deploy/dd-patches.sh`（anchor-based，幂等）
部署目标：`~/.hermes/hermes-agent/`（runtime）

| 目标文件 | 补丁内容 | 注入函数 |
|---|---|---|
| profiles.py | `_sync_profile_plugins` 全局插件跨 profile 可见（#50937/#65593/#69014） | patch_profiles() |
| moa_config.py | 清空默认 MoA 参考模型 + aggregator（未订阅 provider） | patch_moa_config() |
| config_defaults.py | 内置 default preset 清空 + disabled（# VIP patch 2026-08-05） | patch_config_defaults() |
| inventory.py | picker 只显示 enabled preset（#55187） | patch_inventory() |
| model_switch.py | fallback 空串不落回未订阅 default preset（# VIP patch 2026-08-05） | patch_model_switch() |
| credential_files.py | 媒体路径翻译到 workspace（容器读图） | patch_credential_files() |

状态：
- moa_config / config_defaults / model_switch 已固化进 git main（c03f329e46 等），dd-patches 仅幂等校验。
- inventory.py 的补丁只存在于 dd-patches.sh，未部署过（runtime 快照里无标记，别去快照里找）。
- profile-plugin-clone.py：profile 插件克隆辅助脚本（同主题，随补丁管理）。
