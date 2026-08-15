# npu_plan_server

昇腾 910 侧薄规划服务（C++）。默认调用本机 OpenClaw（`127.0.0.1:18789`，`model=openclaw/default`）做任务分解。

```bash
make && ./npu_plan_server --http --port 8443 --token robotpi
```

环境变量：

| 变量 | 默认 | 说明 |
|------|------|------|
| `OPENCLAW_URL` | `http://127.0.0.1:18789/v1/chat/completions` | OpenClaw 接口 |
| `OPENCLAW_TIMEOUT_SEC` | `600` | 调用超时（秒） |
| `NPU_STUB` | 未设置 | 设为 `1` 则不调 OpenClaw，返回本地固定序列 |

协议说明见 [delivery/OPENCLAW_HTTP_CHAT.md](../delivery/OPENCLAW_HTTP_CHAT.md)。  
手机经 **中间机** 访问：见仓库 `mid/` 与 [docs/910_server_support.md](../docs/910_server_support.md)。
