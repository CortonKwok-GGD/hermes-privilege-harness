# Todo 工具 Bug 调查手记

**日期：** 2026-07-26  
**发现者：** Hermes (vip-sandbox)  
**状态：** 待深挖，非 VIP 插件问题

## 现象

`todo` 工具在任何参数下均报错：

```
"todos must be a list of objects, got unparseable string"
```

即使最简单的调用也失败（当前模型：deepseek-v4-pro）：

```json
{"todos": [{"content":"test","id":"1","status":"completed"}]}
```

## 根因定位

源码：`tools/todo_tool.py` 第 160-166 行

```python
def todo_tool(todos=None, merge=False, store=None):
    if todos is not None:
        if isinstance(todos, str):           # ← 关键：框架把数组转成了字符串
            try:
                todos = json.loads(todos)    # ← 但这个字符串是损坏的 JSON
            except (json.JSONDecodeError, TypeError):
                return tool_error("todos must be a list of objects, got unparseable string")
```

调用链：`LLM function call → model_tools.py (dispatch) → handler(todos=args.get("todos"))`

**语义分析：**

1. 代码预期 `todos` 是 `list` — 正常的函数调用参数
2. 但 `isinstance(todos, str)` 守卫说明**已知框架有时会把数组参数序列化成字符串**
3. `json.loads(todos)` 失败 → 这个字符串是**损坏的 JSON**（可能是双重序列化？JSON 转义错误？）

所以问题不在 LLM 的函数调用格式，也不在 todo 工具自身的逻辑，而在 **Hermes 核心框架的 tool-call 参数传递层**（`model_tools.py` 或 `agent/fn_call.py` 的反序列化过程）。

## 排除 VIP 插件干扰

审查了 `hermes-vip/hermes-plugin/guard.py`，`todo` 在第 268 行白名单中：

```python
if tool_name in ("todo", "memory", "session_search", ...):
    return None  # 完全放行，不拦截
```

VIP 的 `check()` 返回 `None` 后，`_hook` 也返回 `None`，工具正常执行。**VIP 插件与 todo bug 无关。**

## 下一步深挖方向

1. **找序列化层：** 搜索 `model_tools.py` 或 `agent/` 中 tool-call args 的预处理逻辑
   - 谁把数组 `[{"content":"test",...}]` 转成了字符串？
   - 为什么这个字符串无法 `json.loads()`？
   
2. **可能原因：**
   - 双重 `json.dumps()` — 数组被 `json.dumps()` 了一次，框架又加了外层引号
   - 嵌套引号转义错误 — `"` 和 `\"` 的层级关系出错
   - OpenAI-compatible 接口的 tools 参数格式与 handler 格式不匹配

3. **重现方法：**
   ```bash
   hermes -z "列出三个测试任务" -m <any> --yolo
   # 观察 todo 工具是否报错
   ```

4. **相关文件：**
   - `tools/todo_tool.py:160-166` — 报错点
   - `model_tools.py` — tool dispatch
   - `agent/` — function call 解析
   - `hermes_cli/` — CLI 入口

5. **其他数组参数工具：** 检查 `delegate_task(tasks=[])`、`cronjob` 等是否也有同样的序列化问题。如果只有 todo 报错，可能是 todo schema 的特殊之处。

## 当前 workaround

手工表格代替（功能等同，只是不会自动注入回话上下文）。
