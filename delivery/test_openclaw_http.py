#!/usr/bin/env python3
"""从本地 Mac 通过 SSH 隧道与服务器上的 OpenClaw 对话。

仅使用 Python 标准库，不需要安装 requests/httpx。
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, Iterator, Optional, Tuple
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


DEFAULT_SSH_HOST = "dev-modelarts-cnnorth9.huaweicloud.com"
DEFAULT_SSH_PORT = 32061
DEFAULT_SSH_USER = "ma-user"
DEFAULT_IDENTITY_FILE = "/Users/hannah/Downloads/KeyPair-8514.pem"
REMOTE_OPENCLAW_HOST = "127.0.0.1"
REMOTE_OPENCLAW_PORT = 18789


class OpenClawTestError(RuntimeError):
    """本地测试脚本错误。"""


def choose_local_port(requested_port: int) -> int:
    if requested_port:
        return requested_port
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def copy_identity_file(identity_file: Path, temporary_directory: Path) -> Path:
    if not identity_file.is_file():
        raise OpenClawTestError(f"SSH 私钥不存在: {identity_file}")

    temporary_key = temporary_directory / "openclaw-test-key.pem"
    shutil.copyfile(identity_file, temporary_key)
    os.chmod(temporary_key, 0o600)
    return temporary_key


def health_check(base_url: str, timeout: float = 2.0) -> bool:
    try:
        with urlopen(f"{base_url}/health", timeout=timeout) as response:
            data = json.loads(response.read().decode("utf-8"))
        return data.get("ok") is True
    except (OSError, ValueError, URLError):
        return False


@contextlib.contextmanager
def ssh_tunnel(
    ssh_host: str,
    ssh_port: int,
    ssh_user: str,
    identity_file: Path,
    local_port: int,
) -> Iterator[str]:
    """启动 SSH 本地端口转发，退出时关闭并清理临时私钥。"""
    with tempfile.TemporaryDirectory(prefix="openclaw-http-test-") as directory:
        temporary_key = copy_identity_file(identity_file, Path(directory))
        command = [
            "ssh",
            "-i",
            str(temporary_key),
            "-p",
            str(ssh_port),
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "ExitOnForwardFailure=yes",
            "-o",
            "ServerAliveInterval=30",
            "-o",
            "ServerAliveCountMax=3",
            "-N",
            "-L",
            (
                f"127.0.0.1:{local_port}:"
                f"{REMOTE_OPENCLAW_HOST}:{REMOTE_OPENCLAW_PORT}"
            ),
            f"{ssh_user}@{ssh_host}",
        ]

        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        base_url = f"http://127.0.0.1:{local_port}"

        try:
            deadline = time.monotonic() + 15.0
            while time.monotonic() < deadline:
                return_code = process.poll()
                if return_code is not None:
                    stderr = process.stderr.read() if process.stderr else ""
                    raise OpenClawTestError(
                        f"SSH 隧道启动失败，退出码={return_code}: {stderr.strip()}"
                    )
                if health_check(base_url):
                    yield base_url
                    return
                time.sleep(0.25)

            raise OpenClawTestError("SSH 隧道已启动，但 OpenClaw 健康检查超时")
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


def decode_http_error(error: HTTPError) -> str:
    try:
        body = error.read().decode("utf-8", errors="replace")
    except OSError:
        body = ""
    return f"HTTP {error.code}: {body[:2000]}"


def parse_openclaw_response(data: Dict[str, Any]) -> Tuple[str, Dict[str, Any]]:
    choices = data.get("choices")
    if not isinstance(choices, list) or not choices:
        raise OpenClawTestError(f"OpenClaw 响应中没有 choices: {data}")

    first_choice = choices[0]
    if not isinstance(first_choice, dict):
        raise OpenClawTestError("OpenClaw choices[0] 不是 JSON 对象")

    finish_reason = first_choice.get("finish_reason")
    if finish_reason == "length":
        raise OpenClawTestError("OpenClaw 回答因 token 限制被截断")
    if finish_reason not in (None, "stop"):
        raise OpenClawTestError(
            f"OpenClaw 返回非预期 finish_reason={finish_reason}"
        )

    message = first_choice.get("message")
    if not isinstance(message, dict):
        raise OpenClawTestError("OpenClaw 响应中没有 message")

    content = message.get("content")
    if not isinstance(content, str) or not content.strip():
        raise OpenClawTestError("OpenClaw 返回了空回答")

    metadata = {
        "request_id": data.get("id"),
        "model": data.get("model"),
        "finish_reason": finish_reason,
        "usage": data.get("usage") or {},
    }
    return content, metadata


def parse_openclaw_stream(
    lines: Iterable[bytes],
    on_delta: Optional[Callable[[str], None]] = None,
) -> Tuple[str, Dict[str, Any]]:
    """Parse an OpenAI-compatible SSE response and collect its text."""
    content_parts: list[str] = []
    request_id: Any = None
    model: Any = None
    finish_reason: Any = None
    usage: Dict[str, Any] = {}

    for raw_line in lines:
        line = raw_line.decode("utf-8", errors="replace").strip()
        if not line or line.startswith(":") or not line.startswith("data:"):
            continue
        event_data = line[5:].strip()
        if event_data == "[DONE]":
            break

        try:
            event = json.loads(event_data)
        except json.JSONDecodeError as error:
            raise OpenClawTestError(f"OpenClaw SSE 事件不是有效 JSON: {event_data[:1000]}") from error
        if not isinstance(event, dict):
            continue
        if isinstance(event.get("error"), dict):
            raise OpenClawTestError(f"OpenClaw SSE 返回错误: {event['error']}")

        request_id = event.get("id") or request_id
        model = event.get("model") or model
        if isinstance(event.get("usage"), dict):
            usage = event["usage"]

        choices = event.get("choices")
        if not isinstance(choices, list) or not choices:
            continue
        choice = choices[0]
        if not isinstance(choice, dict):
            continue
        if choice.get("finish_reason") is not None:
            finish_reason = choice["finish_reason"]
        delta = choice.get("delta")
        if not isinstance(delta, dict):
            continue
        content = delta.get("content")
        if isinstance(content, str) and content:
            content_parts.append(content)
            if on_delta is not None:
                on_delta(content)

    content = "".join(content_parts)
    if not content.strip():
        raise OpenClawTestError("OpenClaw SSE 流中没有文本回答")
    if finish_reason == "length":
        raise OpenClawTestError("OpenClaw 回答因 token 限制被截断")
    if finish_reason not in (None, "stop"):
        raise OpenClawTestError(
            f"OpenClaw 返回非预期 finish_reason={finish_reason}"
        )

    return content, {
        "request_id": request_id,
        "model": model,
        "finish_reason": finish_reason,
        "usage": usage,
    }


def chat_with_openclaw(
    base_url: str,
    message: str,
    conversation_id: str,
    system_message: Optional[str],
    timeout: float,
    stream: bool = False,
    on_delta: Optional[Callable[[str], None]] = None,
) -> Tuple[str, Dict[str, Any]]:
    messages = []
    if system_message:
        messages.append({"role": "system", "content": system_message})
    messages.append({"role": "user", "content": message})

    payload = {
        "model": "openclaw/default",
        "user": f"conversation:{conversation_id}",
        "stream": stream,
        "messages": messages,
    }
    if stream:
        payload["stream_options"] = {"include_usage": True}
    request_body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    request = Request(
        f"{base_url}/v1/chat/completions",
        data=request_body,
        headers={"Content-Type": "application/json; charset=utf-8"},
        method="POST",
    )

    try:
        with urlopen(request, timeout=timeout) as response:
            if stream:
                return parse_openclaw_stream(response, on_delta=on_delta)
            response_body = response.read().decode("utf-8")
    except HTTPError as error:
        raise OpenClawTestError(decode_http_error(error)) from error
    except URLError as error:
        raise OpenClawTestError(f"无法访问 OpenClaw: {error}") from error

    try:
        data = json.loads(response_body)
    except json.JSONDecodeError as error:
        raise OpenClawTestError(
            f"OpenClaw 未返回有效 JSON: {response_body[:2000]}"
        ) from error

    if not isinstance(data, dict):
        raise OpenClawTestError("OpenClaw 响应不是 JSON 对象")
    return parse_openclaw_response(data)


def print_metadata(metadata: Dict[str, Any]) -> None:
    usage = metadata.get("usage") or {}
    print(
        "[meta] "
        f"request_id={metadata.get('request_id')} "
        f"model={metadata.get('model')} "
        f"finish_reason={metadata.get('finish_reason')} "
        f"prompt_tokens={usage.get('prompt_tokens')} "
        f"completion_tokens={usage.get('completion_tokens')}"
    )


def run_once(
    base_url: str,
    message: str,
    conversation_id: str,
    system_message: Optional[str],
    timeout: float,
    verbose: bool,
    stream: bool,
) -> None:
    if stream:
        print("OpenClaw: ", end="", flush=True)
    try:
        reply, metadata = chat_with_openclaw(
            base_url=base_url,
            message=message,
            conversation_id=conversation_id,
            system_message=system_message,
            timeout=timeout,
            stream=stream,
            on_delta=(lambda delta: print(delta, end="", flush=True)) if stream else None,
        )
    except Exception:
        if stream:
            print()
        raise
    if stream:
        print()
    else:
        print(f"OpenClaw: {reply}")
    if verbose:
        print_metadata(metadata)


def interactive_chat(
    base_url: str,
    conversation_id: str,
    system_message: Optional[str],
    timeout: float,
    verbose: bool,
    stream: bool,
) -> None:
    print(f"SSH 隧道与 OpenClaw 已就绪: {base_url}")
    print(f"当前 conversation_id: {conversation_id}")
    print("输入 /new 创建新对话，输入 /quit 退出。")

    while True:
        try:
            message = input("\n你: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n已退出。")
            return

        if not message:
            continue
        if message in {"/quit", "/exit"}:
            print("已退出。")
            return
        if message == "/new":
            conversation_id = str(uuid.uuid4())
            print(f"已创建新对话: {conversation_id}")
            continue

        try:
            run_once(
                base_url=base_url,
                message=message,
                conversation_id=conversation_id,
                system_message=system_message,
                timeout=timeout,
                verbose=verbose,
                stream=stream,
            )
        except OpenClawTestError as error:
            print(f"[error] {error}", file=sys.stderr)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="从本地通过 SSH 隧道与服务器上的 OpenClaw 对话"
    )
    parser.add_argument("--ssh-host", default=DEFAULT_SSH_HOST)
    parser.add_argument("--ssh-port", type=int, default=DEFAULT_SSH_PORT)
    parser.add_argument("--ssh-user", default=DEFAULT_SSH_USER)
    parser.add_argument("--identity-file", default=DEFAULT_IDENTITY_FILE)
    parser.add_argument(
        "--local-port",
        type=int,
        default=0,
        help="本地转发端口；0 表示自动选择空闲端口",
    )
    parser.add_argument(
        "--conversation-id",
        default=None,
        help="对话 ID；不填时自动生成",
    )
    parser.add_argument(
        "--system-message",
        default="你是运行在 Ascend 910 服务器上的 OpenClaw 助手。请用中文简洁回答。",
    )
    parser.add_argument(
        "--once",
        default=None,
        help="只发送一条消息后退出；不填时进入交互模式",
    )
    parser.add_argument("--timeout", type=float, default=600.0)
    parser.add_argument(
        "--stream",
        action="store_true",
        help="使用 SSE 流式响应并在收到文本时立即输出",
    )
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    local_port = choose_local_port(args.local_port)
    conversation_id = args.conversation_id or str(uuid.uuid4())

    try:
        with ssh_tunnel(
            ssh_host=args.ssh_host,
            ssh_port=args.ssh_port,
            ssh_user=args.ssh_user,
            identity_file=Path(args.identity_file).expanduser(),
            local_port=local_port,
        ) as base_url:
            if args.once:
                run_once(
                    base_url=base_url,
                    message=args.once,
                    conversation_id=conversation_id,
                    system_message=args.system_message,
                    timeout=args.timeout,
                    verbose=args.verbose,
                    stream=args.stream,
                )
            else:
                interactive_chat(
                    base_url=base_url,
                    conversation_id=conversation_id,
                    system_message=args.system_message,
                    timeout=args.timeout,
                    verbose=args.verbose,
                    stream=args.stream,
                )
    except OpenClawTestError as error:
        print(f"[error] {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
