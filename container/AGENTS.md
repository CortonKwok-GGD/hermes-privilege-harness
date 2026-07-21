# Hermes Container Sandbox — Development Guide

## What This Project Is

Cross-platform container sandbox for Hermes Agent.

| Platform | Runtime | Script | Image |
|----------|---------|--------|-------|
| Linux    | Docker  | `hermes-run` → `docker exec` | `hermes-isolated` (Ubuntu) |
| macOS    | Apple container CLI | `hermes-run` → `container exec` | `hermes-vm:latest` (Alpine) |

## Repo Structure

```
hermes-container/          ← 开发目录（所有改动在此进行）
├── macos/                 ← macOS Apple container 沙箱
│   ├── hermes-run.sh      ← 开发版 hermes-run（部署到 /usr/local/bin/）
│   ├── Dockerfile.hermes-vm
│   └── install.sh
├── config/
│   └── config.vip.yaml
├── AGENTS.md
├── WBS.md
└── README.md
```

## 开发纪律（铁律）

**所有改动先在开发目录进行，验证后再部署到生产。**

```
❌ 错误：直接在 /usr/local/bin/hermes-run 改
✅ 正确：改 macos/hermes-run.sh → dd 到 /usr/local/bin/hermes-run

❌ 错误：直接在 ~/.hermes/plugins/ 改
✅ 正确：改 config/config.vip.yaml → 检查 → 手动 cat 到 ~/.hermes/plugins/
```

## Key Architecture

```
hermes-run  [--no-net]  <command>
    │
    ├── Linux:   printf '%s' "$CMD" | docker exec -i hermes-vm sh
    └── macOS:   printf '%s' "$CMD" | container exec -i hermes-vm sh
```

Both platforms:
- Read config.yaml for mount list
- Use `printf + stdin` pipe to prevent shell injection
- `--no-net` creates isolated container with `--network none`

## Platform Quirks + 踩坑

### macOS 26 特有

| 问题 | 现象 | 对策 |
|------|------|------|
| `/usr/local/bin/` SIP 保护 | `cp`/`install`/`tee` 全部 Permission denied | `dd if=src of=dst` |
| provenance xattr | root 无法读写 `~/.hermes/plugins/` 下文件 | 宿主机终端编辑 |
| VZ 文件不同步 | 容器内写的文件宿主机看不到 | 目录在宿主机创建 |
| container list 无 --filter | `--filter name=xxx` → Unknown option | `grep -x "$CNAME"` |
| XPC 绑定 Aqua session | daemon/_hermes 无法调 container CLI | terminal 工具以 mac 用户执行 |
| 多架构镜像 | docker save 缺 blob | index.json 只保留 amd64 |
| pyyaml 缺失 | config 解析静默失败 | `pip3 install pyyaml` |

### macOS 部署流程

```bash
# 1. 改开发版
vim macos/hermes-run.sh

# 2. 部署到生产
dd if=macos/hermes-run.sh of=/usr/local/bin/hermes-run
chmod 755 /usr/local/bin/hermes-run

# 3. 测试
hermes-run whoami

# 4. 提交
git add -A && git commit -m "..."
git push origin main
git push gitee main
```

## SSH Key / Git Push

SSH key 在 `~/.ssh/id_ed25519`，拷贝到 `~/hermes-workspace/.ssh/id_ed25519`。
容器内因 provenance xattr 不可读，push 需从宿主机终端执行：

```bash
cd ~/hermes-workspace/hermes-container
git push origin main
git push gitee main
```

## Testing

```bash
# Cold start
container rm -f hermes-vm
hermes-run whoami

# Network isolation
hermes-run --no-net curl -s --max-time 3 https://www.baidu.com

# Config sanity
cat /Users/mac/.hermes/plugins/hermes-vip/config.yaml
cat /Users/mac/.hermes/config.yaml

# Injection test
hermes-run echo "hello; id"    # 不应执行 id
```
