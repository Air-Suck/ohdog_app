# 在服务器上通过 HTTP 与 OpenClaw 对话

## 1. 文档目的

本文档说明如何从服务器上的业务程序（例如监听 `8443` 端口的 HTTP
服务）调用 OpenClaw，并解析 OpenClaw 返回的回答。

当前服务器上的 OpenClaw HTTP 接口为：

```text
http://127.0.0.1:18789/v1/chat/completions
```

当前接口只监听服务器本机回环地址，不直接暴露到外网。因此，监听 `8443`
端口的业务服务应当与 OpenClaw 位于同一台服务器上，并通过
`127.0.0.1:18789` 访问 OpenClaw。

## 2. 调用链路

```text
用户或上游客户端
        ↓
业务 HTTP 服务（端口 8443）
        ↓  POST http://127.0.0.1:18789/v1/chat/completions
OpenClaw Gateway
        ↓
OpenClaw Agent
        ↓
MindIE + Qwen2.5-32B + Ascend 910
```

`8443` 服务的职责是：

1. 接收上游用户请求。
2. 进行身份认证、参数校验、限流和日志记录。
3. 把用户指令组装成 OpenClaw Chat Completions 请求。
4. 调用 OpenClaw。
5. 从 OpenClaw 的 JSON 响应中取出最终回答，再返回给上游用户。

## 3. HTTP 请求格式

### 3.1 最小请求

```http
POST /v1/chat/completions HTTP/1.1
Host: 127.0.0.1:18789
Content-Type: application/json

{
  "model": "openclaw/default",
  "stream": false,
  "messages": [
    {
      "role": "user",
      "content": "你好，请介绍一下你自己。"
    }
  ]
}
```

### 3.2 推荐请求

推荐每个对话传入稳定的 `user` 字段：

```json
{
  "model": "openclaw/default",
  "user": "conversation:123456",
  "stream": false,
  "messages": [
    {
      "role": "system",
      "content": "你是机器人对话助手。回答应简洁、准确，不得伪造事实。"
    },
    {
      "role": "user",
      "content": "请告诉我你当前使用的模型。"
    }
  ]
}
```

字段说明：

| 字段 | 是否必需 | 说明 |
| --- | --- | --- |
| `model` | 是 | 固定使用 `openclaw/default`，表示调用 OpenClaw 默认 Agent。 |
| `messages` | 是 | OpenAI Chat Completions 格式的消息数组。 |
| `messages[].role` | 是 | 对话场景通常使用 `system`、`user` 和 `assistant`。 |
| `messages[].content` | 是 | 消息文本。 |
| `user` | 推荐 | 对话标识符。相同值会复用同一 OpenClaw 会话。 |
| `stream` | 否 | `false` 返回完整 JSON；`true` 使用 SSE 流式返回。 |
| `max_completion_tokens` | 否 | 尝试限制本次回答最大 token 数。 |
| `temperature` | 否 | 采样温度，可选范围为 `0` 至 `2`。 |

> `model` 是 OpenClaw Agent 目标，不是 MindIE 的原始模型 ID。请使用
> `openclaw/default`，不要在此填写 `qwen2.5-32b-instruct`。

## 4. 会话上下文

### 4.1 需要连续对话

同一段对话的每次请求都使用相同的 `user` 值：

```json
"user": "conversation:123456"
```

OpenClaw 会根据该值复用对话会话，因此上游服务不需要每次重发所有历史
消息。

推荐用业务系统的会话 ID 生成该字段：

```python
openclaw_user = f"conversation:{business_conversation_id}"
```

不要对所有请求都使用同一个全局 `user` 值，否则不同用户或不同任务可能共享
上下文。

### 4.2 需要无状态对话

如果每次请求都应当是一段全新对话，可以省略 `user`。OpenClaw 会为每次请求
创建新会话。

## 5. curl 示例

### 5.1 返回完整 JSON

```bash
curl -sS http://127.0.0.1:18789/v1/chat/completions \
  -H 'Content-Type: application/json' \
  --data-binary '{
    "model": "openclaw/default",
    "user": "conversation:curl-demo-001",
    "stream": false,
    "messages": [
      {
        "role": "user",
        "content": "你好，请用一句话介绍你自己。"
      }
    ]
  }'
```

### 5.2 只提取回答文本

服务器安装了 `jq` 时：

```bash
curl -sS http://127.0.0.1:18789/v1/chat/completions \
  -H 'Content-Type: application/json' \
  --data-binary '{
    "model": "openclaw/default",
    "user": "conversation:curl-demo-002",
    "stream": false,
    "messages": [
      {"role": "user", "content": "请回复你好。"}
    ]
  }' \
  | jq -r '.choices[0].message.content'
```

## 6. 非流式响应及解析

### 6.1 响应示例

```json
{
  "id": "chatcmpl_664c0b16-c0d3-425a-8bef-b1bb1e478f6f",
  "object": "chat.completion",
  "created": 1786800801,
  "model": "openclaw/default",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "你好，我是运行在 Ascend 910 上的 OpenClaw 助手。"
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 14262,
    "completion_tokens": 15,
    "total_tokens": 14277
  }
}
```

### 6.2 需要解析的字段

| JSON 路径 | 说明 |
| --- | --- |
| `choices[0].message.content` | OpenClaw 最终回答文本。 |
| `choices[0].finish_reason` | 完成原因。正常回答通常为 `stop`。 |
| `usage.prompt_tokens` | 输入 token 数。 |
| `usage.completion_tokens` | 输出 token 数。 |
| `usage.total_tokens` | 输入与输出 token 总数。 |
| `id` | 本次 OpenClaw 请求 ID，可记入日志便于排查。 |

`finish_reason` 常见值：

| 值 | 处理方式 |
| --- | --- |
| `stop` | 正常完成，可以取出 `content`。 |
| `length` | 回答达到 token 限制，内容可能不完整。 |
| `tool_calls` | 仅当 HTTP 客户端自己额外传入客户端工具时需要处理。普通对话不需要传入 `tools`。 |

## 7. Python 非流式示例

### 7.1 基本客户端

```python
from __future__ import annotations

from typing import Any

import requests


OPENCLAW_CHAT_URL = "http://127.0.0.1:18789/v1/chat/completions"


class OpenClawResponseError(RuntimeError):
    pass


def extract_openclaw_reply(data: dict[str, Any]) -> str:
    choices = data.get("choices")
    if not isinstance(choices, list) or not choices:
        raise OpenClawResponseError("OpenClaw 响应中没有 choices")

    first_choice = choices[0]
    if not isinstance(first_choice, dict):
        raise OpenClawResponseError("OpenClaw choices[0] 格式错误")

    finish_reason = first_choice.get("finish_reason")
    if finish_reason == "length":
        raise OpenClawResponseError("OpenClaw 回答因 token 限制被截断")
    if finish_reason not in (None, "stop"):
        raise OpenClawResponseError(
            f"OpenClaw 返回非预期 finish_reason: {finish_reason}"
        )

    message = first_choice.get("message")
    if not isinstance(message, dict):
        raise OpenClawResponseError("OpenClaw 响应中没有 message")

    content = message.get("content")
    if not isinstance(content, str) or not content.strip():
        raise OpenClawResponseError("OpenClaw 返回了空回答")

    return content


def chat_with_openclaw(
    user_message: str,
    conversation_id: str,
    system_message: str | None = None,
) -> str:
    messages: list[dict[str, str]] = []
    if system_message:
        messages.append({"role": "system", "content": system_message})
    messages.append({"role": "user", "content": user_message})

    payload = {
        "model": "openclaw/default",
        "user": f"conversation:{conversation_id}",
        "stream": False,
        "messages": messages,
    }

    response = requests.post(
        OPENCLAW_CHAT_URL,
        json=payload,
        timeout=600,
    )

    try:
        response.raise_for_status()
    except requests.HTTPError as error:
        raise OpenClawResponseError(
            f"OpenClaw HTTP 错误: status={response.status_code}, "
            f"body={response.text[:2000]}"
        ) from error

    try:
        data = response.json()
    except requests.JSONDecodeError as error:
        raise OpenClawResponseError(
            f"OpenClaw 未返回有效 JSON: {response.text[:2000]}"
        ) from error

    return extract_openclaw_reply(data)


if __name__ == "__main__":
    answer = chat_with_openclaw(
        user_message="你好，请用一句话介绍你自己。",
        conversation_id="python-demo-001",
        system_message="回答应当简洁、准确。",
    )
    print(answer)
```

### 7.2 作为 8443 FastAPI 服务的上游

```python
from __future__ import annotations

from typing import Any

import httpx
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field


OPENCLAW_CHAT_URL = "http://127.0.0.1:18789/v1/chat/completions"

app = FastAPI()


class ChatRequest(BaseModel):
    conversation_id: str = Field(min_length=1, max_length=128)
    message: str = Field(min_length=1, max_length=20000)


class ChatResponse(BaseModel):
    reply: str
    request_id: str | None = None
    prompt_tokens: int | None = None
    completion_tokens: int | None = None


def parse_reply(data: dict[str, Any]) -> ChatResponse:
    try:
        choice = data["choices"][0]
        content = choice["message"]["content"]
    except (KeyError, IndexError, TypeError) as error:
        raise ValueError("OpenClaw 响应格式错误") from error

    if choice.get("finish_reason") != "stop":
        raise ValueError(
            f"OpenClaw 未正常完成: {choice.get('finish_reason')}"
        )
    if not isinstance(content, str) or not content.strip():
        raise ValueError("OpenClaw 返回了空回答")

    usage = data.get("usage") or {}
    return ChatResponse(
        reply=content,
        request_id=data.get("id"),
        prompt_tokens=usage.get("prompt_tokens"),
        completion_tokens=usage.get("completion_tokens"),
    )


@app.post("/chat", response_model=ChatResponse)
async def chat(request: ChatRequest) -> ChatResponse:
    payload = {
        "model": "openclaw/default",
        "user": f"conversation:{request.conversation_id}",
        "stream": False,
        "messages": [
            {
                "role": "system",
                "content": "你是机器人对话助手，回答应简洁、准确。",
            },
            {
                "role": "user",
                "content": request.message,
            },
        ],
    }

    try:
        async with httpx.AsyncClient(timeout=600.0) as client:
            response = await client.post(OPENCLAW_CHAT_URL, json=payload)
            response.raise_for_status()
            data = response.json()
        return parse_reply(data)
    except (httpx.HTTPError, ValueError) as error:
        raise HTTPException(status_code=502, detail=str(error)) from error
```

启动示例：

```bash
uvicorn app:app --host 0.0.0.0 --port 8443
```

测试 `8443` 服务：

```bash
curl -sS http://127.0.0.1:8443/chat \
  -H 'Content-Type: application/json' \
  --data-binary '{
    "conversation_id": "demo-001",
    "message": "你好，请说明你能做什么。"
  }'
```

## 8. 流式对话

如果需要边生成边显示，设置：

```json
"stream": true
```

OpenClaw 会返回 `Content-Type: text/event-stream`，数据示例：

```text
data: {"id":"chatcmpl_xxx","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

data: {"id":"chatcmpl_xxx","choices":[{"index":0,"delta":{"content":"你好"},"finish_reason":null}]}

data: {"id":"chatcmpl_xxx","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

data: [DONE]
```

### 8.1 curl 流式示例

```bash
curl -N http://127.0.0.1:18789/v1/chat/completions \
  -H 'Content-Type: application/json' \
  --data-binary '{
    "model": "openclaw/default",
    "user": "conversation:stream-demo-001",
    "stream": true,
    "messages": [
      {"role": "user", "content": "请写一段简短的自我介绍。"}
    ]
  }'
```

### 8.2 Python 流式解析示例

```python
from __future__ import annotations

import json
from collections.abc import Iterator

import requests


OPENCLAW_CHAT_URL = "http://127.0.0.1:18789/v1/chat/completions"


def stream_openclaw_reply(message: str, conversation_id: str) -> Iterator[str]:
    payload = {
        "model": "openclaw/default",
        "user": f"conversation:{conversation_id}",
        "stream": True,
        "messages": [{"role": "user", "content": message}],
    }

    with requests.post(
        OPENCLAW_CHAT_URL,
        json=payload,
        stream=True,
        timeout=600,
    ) as response:
        response.raise_for_status()

        for line in response.iter_lines(decode_unicode=True):
            if not line or not line.startswith("data: "):
                continue

            raw_data = line[6:]
            if raw_data == "[DONE]":
                break

            event = json.loads(raw_data)
            choices = event.get("choices") or []
            if not choices:
                continue

            delta = choices[0].get("delta") or {}
            content = delta.get("content")
            if isinstance(content, str) and content:
                yield content


if __name__ == "__main__":
    for text_delta in stream_openclaw_reply(
        "请用两句话介绍你自己。",
        "python-stream-demo-001",
    ):
        print(text_delta, end="", flush=True)
    print()
```

如果业务不需要实时显示生成过程，建议使用 `stream: false`，服务端代码会更简单，
错误处理也更直接。

## 9. 错误处理

### 9.1 HTTP 错误

OpenClaw 接口可能返回：

| HTTP 状态码 | 说明 |
| --- | --- |
| `400` | 请求 JSON 或参数格式错误。 |
| `401` | 缺少或使用了错误的认证信息。当前 loopback 配置不需要认证。 |
| `403` | 调用者权限不足。 |
| `429` | 请求过多或多次认证失败。 |
| `500` / `502` / `503` | OpenClaw、模型服务或上游调用异常。 |

当 HTTP 状态码不是 `2xx` 时，不要继续按正常 Chat Completions 响应解析，应当记录：

- HTTP 状态码。
- 响应体，建议截断到合理长度。
- 业务会话 ID。
- OpenClaw 响应的 `id`（如果存在）。
- 请求耗时。

### 9.2 超时

OpenClaw 可能在回答前执行 Agent 思考或内部工具调用，因此 HTTP 客户端建议使用
`600` 秒超时。不要使用几秒的默认超时。

对于非幂等用户指令，超时后不应盲目自动重试，否则可能造成同一指令被重复
处理。

### 9.3 空回答或截断

业务服务至少应当检查：

```python
choice = data["choices"][0]

if choice.get("finish_reason") != "stop":
    raise RuntimeError("OpenClaw 未正常完成")

content = choice["message"].get("content")
if not isinstance(content, str) or not content.strip():
    raise RuntimeError("OpenClaw 返回了空回答")
```

## 10. 服务检查

### 10.1 健康检查

使用专用 `/health` 接口：

```bash
curl -sS http://127.0.0.1:18789/health
```

正常返回：

```json
{
  "ok": true,
  "status": "live"
}
```

不要用 `/v1/chat/completions` 做周期健康检查，因为每次对话请求都会启动完整的
Agent 运行。

### 10.2 模型目标检查

```bash
curl -sS http://127.0.0.1:18789/v1/models
```

当前应当能看到：

```text
openclaw
openclaw/default
openclaw/main
```

### 10.3 服务端状态脚本

```bash
/home/ma-user/openclaw-ascend/bin/status.sh
```

## 11. 认证与网络安全

当前 OpenClaw 配置为：

- 只绑定 `127.0.0.1:18789`。
- `gateway.auth.mode` 为 `none`。
- 同机 `8443` 服务调用时不需要 `Authorization` 请求头。

不要将 `18789` 直接映射到公网。外部用户应当只访问你自己的 `8443` 业务
服务，由 `8443` 服务负责认证、授权、限流和请求过滤。

如果未来需要让其他主机直接访问 OpenClaw，应当先改用 Token 或受信代理认证，
而不是单纯把 OpenClaw 绑定到 `0.0.0.0`。

## 12. Docker 注意事项

如果 `8443` 服务运行在 Docker 容器中，容器内的 `127.0.0.1` 指向容器自身，而不是
宿主机。

可选方案：

1. Linux 上让 `8443` 容器使用 host network。
2. 在宿主机上部署一个受控反向代理，由反向代理访问
   `127.0.0.1:18789`。
3. 修改 OpenClaw 绑定地址和认证方式。此方案需要同时配置 Token、防火墙和访问
   白名单，不建议直接对公网开放。

## 13. 建议的生产处理流程

```text
1. 8443 服务接收用户请求
2. 验证身份和请求参数
3. 生成独立的 conversation_id
4. 组装 system/user messages
5. 使用 600 秒超时调用 OpenClaw
6. 检查 HTTP 状态码
7. 检查 choices[0].finish_reason
8. 提取 choices[0].message.content
9. 记录 OpenClaw 请求 ID、耗时和 token 用量
10. 把最终回答返回给用户
```

## 14. 最简接入摘要

只需要记住下面四点：

1. 请求地址：`http://127.0.0.1:18789/v1/chat/completions`。
2. `model` 固定使用 `openclaw/default`。
3. 从 `choices[0].message.content` 取出最终回答。
4. 需要连续对话时，为同一对话复用相同的 `user` 值。

## 15. 从本地 Mac 测试服务器 OpenClaw

同目录提供了一个只使用 Python 标准库的本地测试脚本：

```text
test_openclaw_http.py
```

因为 OpenClaw 只监听服务器的 `127.0.0.1:18789`，脚本会：

1. 读取本地 PEM 私钥。
2. 在临时目录生成权限为 `0600` 的私钥副本，不修改原始 PEM。
3. 自动建立 SSH 本地端口转发。
4. 通过隧道检查 OpenClaw `/health`。
5. 进入交互对话，或只发送一条测试消息。
6. 退出时关闭 SSH 隧道并删除临时私钥。

交互对话：

```bash
cd '/Users/hannah/Documents/ChatGPT/机器狗/deploy-openclaw-ascend'
python3 test_openclaw_http.py --verbose
```

SSE 流式交互对话（用于验证 8443 服务将使用的响应协议）：

```bash
python3 test_openclaw_http.py --stream --verbose
```

`--stream` 会按 SSE `data:` 事件解析响应，收到文本增量后立即输出。
脚本会在交互期间保持同一个 `conversation_id`，因此会同时验证
OpenClaw 的多轮会话历史。

只发送一条消息：

```bash
python3 test_openclaw_http.py \
  --once '请用一句话介绍你自己。' \
  --stream \
  --verbose
```

实际测试的输出形式如下：

```text
OpenClaw: 本地 HTTP 测试成功
[meta] request_id=chatcmpl_... model=openclaw/default finish_reason=stop prompt_tokens=8533 completion_tokens=6
```

交互模式命令：

| 命令 | 说明 |
| --- | --- |
| `/new` | 生成新的 `conversation_id`，开始一段新对话。 |
| `/quit` | 退出脚本并关闭 SSH 隧道。 |

如果 SSH 连接参数变化，可以显式传入：

```bash
python3 test_openclaw_http.py \
  --ssh-host dev-modelarts-cnnorth9.huaweicloud.com \
  --ssh-port 32061 \
  --ssh-user ma-user \
  --identity-file '/Users/hannah/Downloads/KeyPair-8514.pem'
```
