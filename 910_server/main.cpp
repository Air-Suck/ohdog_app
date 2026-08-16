/**
 * Ascend 910 端云协同 — 薄 HTTP(S) 规划服务
 *
 * 职责：
 *   1) 监听端口，接收手机 POST /v1/plan（自然语言指令）
 *   2) 规划侧常驻 kMetaActionSystemPrompt（元操作字典）；手机不传字典
 *   3) 调用本机 OpenClaw：POST http://127.0.0.1:18789/v1/chat/completions
 *      model=openclaw/default；从 choices[0].message.content 取规划结果
 *   4) 将模型输出解析为 actions 数组或 beyond_capability，再返回给上游
 *
 * 协议（JSON UTF-8）：
 *   POST /v1/plan
 *     Header: Authorization: Bearer <token>   （可用环境变量 NPU_TOKEN，默认 robotpi）
 *             Content-Type: application/json
 *     Body:   {"v":1,"request_id":"...","text":"..."}
 *     Resp:   {"v":1,"request_id":"...","ok":true,"actions":[...],"msg":"..."}
 *
 *   GET /health  →  {"ok":true,"service":"npu_plan_server"}
 *
 * 环境变量：
 *   NPU_PORT / NPU_TOKEN — 本服务监听与鉴权
 *   OPENCLAW_URL         — 默认 http://127.0.0.1:18789/v1/chat/completions
 *   OPENCLAW_TIMEOUT_SEC — 调用超时秒数，默认 600
 *   NPU_STUB=1           — 强制走本地 stub（不调 OpenClaw，便于断网联调）
 *
 * 编译 / 运行见同目录 Makefile 与 docs/910_server_support.md
 * OpenClaw 协议见 delivery/OPENCLAW_HTTP_CHAT.md
 */

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <csignal>
#include <cstring>
#include <iostream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#if defined(NPU_ENABLE_TLS)
#include <openssl/err.h>
#include <openssl/ssl.h>
#endif

namespace {

/** 监听端口，可用环境变量 NPU_PORT 覆盖 */
constexpr int kDefaultPort = 8443;

/** 默认鉴权 token，可用环境变量 NPU_TOKEN 覆盖 */
constexpr const char* kDefaultToken = "robotpi";

/** OpenClaw Chat Completions（仅本机 loopback；见 OPENCLAW_HTTP_CHAT.md） */
constexpr const char* kDefaultOpenClawUrl = "http://127.0.0.1:18789/v1/chat/completions";
constexpr const char* kOpenClawModel = "openclaw/default";
constexpr int kDefaultOpenClawTimeoutSec = 600;

std::atomic<bool> g_running{true};

/** 监听套接字；信号里 close/shutdown 以打断阻塞的 accept */
std::atomic<int> g_listen_fd{-1};

/**
 * SIGINT/SIGTERM：置退出标志并关闭监听 fd。
 * 配合 sa_flags=0（无 SA_RESTART），accept 会立刻失败并退出主循环。
 * close/shutdown 均为 async-signal-safe。
 */
void on_signal(int) {
  g_running = false;
  const int fd = g_listen_fd.exchange(-1);
  if (fd >= 0) {
    ::shutdown(fd, SHUT_RDWR);
    ::close(fd);
  }
}

/** 安装可中断阻塞 syscall 的信号处理器（不用 std::signal，避免 SA_RESTART） */
void install_stop_signals() {
  struct sigaction sa {};
  sa.sa_handler = on_signal;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = 0;  // 明确关掉 SA_RESTART
  if (sigaction(SIGINT, &sa, nullptr) < 0) {
    perror("sigaction SIGINT");
  }
  if (sigaction(SIGTERM, &sa, nullptr) < 0) {
    perror("sigaction SIGTERM");
  }
}

/** 从环境变量读取，缺省用 fallback */
std::string env_or(const char* key, const char* fallback) {
  const char* v = std::getenv(key);
  return (v && *v) ? std::string(v) : std::string(fallback);
}

int env_port() {
  const char* v = std::getenv("NPU_PORT");
  if (!v || !*v) {
    return kDefaultPort;
  }
  int p = std::atoi(v);
  return (p > 0 && p < 65536) ? p : kDefaultPort;
}

int env_openclaw_timeout_sec() {
  const char* v = std::getenv("OPENCLAW_TIMEOUT_SEC");
  if (!v || !*v) {
    return kDefaultOpenClawTimeoutSec;
  }
  int t = std::atoi(v);
  return (t > 0 && t <= 3600) ? t : kDefaultOpenClawTimeoutSec;
}

bool env_stub_mode() {
  const char* v = std::getenv("NPU_STUB");
  return v && (std::strcmp(v, "1") == 0 || std::strcmp(v, "true") == 0 ||
               std::strcmp(v, "TRUE") == 0);
}

/** JSON 字符串转义（含控制字符，便于嵌入 OpenClaw 请求体） */
std::string json_escape(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 16);
  for (unsigned char c : s) {
    switch (c) {
      case '\\':
        out += "\\\\";
        break;
      case '"':
        out += "\\\"";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        if (c < 0x20) {
          char buf[8];
          std::snprintf(buf, sizeof(buf), "\\u%04x", c);
          out += buf;
        } else {
          out.push_back(static_cast<char>(c));
        }
        break;
    }
  }
  return out;
}

/** 反转义 JSON 字符串内容（仅处理常见转义） */
std::string json_unescape(const std::string& s) {
  std::string out;
  out.reserve(s.size());
  for (size_t i = 0; i < s.size(); ++i) {
    if (s[i] == '\\' && i + 1 < s.size()) {
      const char n = s[i + 1];
      if (n == '"' || n == '\\' || n == '/') {
        out.push_back(n);
        ++i;
      } else if (n == 'n') {
        out.push_back('\n');
        ++i;
      } else if (n == 'r') {
        out.push_back('\r');
        ++i;
      } else if (n == 't') {
        out.push_back('\t');
        ++i;
      } else if (n == 'u' && i + 5 < s.size()) {
        // 粗略跳过 \\uXXXX（元操作 JSON 一般不含）
        i += 5;
      } else {
        out.push_back(s[i]);
      }
    } else {
      out.push_back(s[i]);
    }
  }
  return out;
}

/**
 * 从 JSON body 中粗提取字符串字段（测试桩够用，非完整 JSON 解析器）。
 * 查找 "key":"value" 形式。
 */
std::string extract_json_string(const std::string& body, const std::string& key) {
  const std::string pat = "\"" + key + "\"";
  size_t pos = body.find(pat);
  if (pos == std::string::npos) {
    return "";
  }
  pos = body.find(':', pos + pat.size());
  if (pos == std::string::npos) {
    return "";
  }
  pos = body.find('"', pos + 1);
  if (pos == std::string::npos) {
    return "";
  }
  size_t end = pos + 1;
  while (end < body.size()) {
    if (body[end] == '\\' && end + 1 < body.size()) {
      end += 2;
      continue;
    }
    if (body[end] == '"') {
      break;
    }
    ++end;
  }
  if (end >= body.size()) {
    return "";
  }
  return body.substr(pos + 1, end - pos - 1);
}

/** 在 from 之后查找字符串字段；找不到返回空。 */
std::string extract_json_string_after(const std::string& body, size_t from,
                                      const std::string& key) {
  const std::string pat = "\"" + key + "\"";
  size_t pos = body.find(pat, from);
  if (pos == std::string::npos) {
    return "";
  }
  pos = body.find(':', pos + pat.size());
  if (pos == std::string::npos) {
    return "";
  }
  pos = body.find('"', pos + 1);
  if (pos == std::string::npos) {
    return "";
  }
  size_t end = pos + 1;
  while (end < body.size()) {
    if (body[end] == '\\' && end + 1 < body.size()) {
      end += 2;
      continue;
    }
    if (body[end] == '"') {
      break;
    }
    ++end;
  }
  if (end >= body.size()) {
    return "";
  }
  return body.substr(pos + 1, end - pos - 1);
}

std::string trim_ws(const std::string& s) {
  size_t b = 0;
  while (b < s.size() && (s[b] == ' ' || s[b] == '\t' || s[b] == '\r' || s[b] == '\n')) {
    ++b;
  }
  size_t e = s.size();
  while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t' || s[e - 1] == '\r' || s[e - 1] == '\n')) {
    --e;
  }
  return s.substr(b, e - b);
}

/** 去掉模型偶发的 markdown 代码围栏。 */
std::string strip_markdown_fence(std::string s) {
  s = trim_ws(s);
  if (s.size() >= 3 && s.compare(0, 3, "```") == 0) {
    size_t nl = s.find('\n');
    if (nl != std::string::npos) {
      s = s.substr(nl + 1);
    }
    size_t end = s.rfind("```");
    if (end != std::string::npos) {
      s = s.substr(0, end);
    }
    s = trim_ws(s);
  }
  return s;
}

/**
 * 常驻系统提示：元操作库（与 task/910_server.md / docs/910_server_support.md 一致）。
 * 对接 openclaw / LLM 时作为 system（或等价）prompt；手机请求体只带用户自然语言，不附带本字典。
 */
static const char kMetaActionSystemPrompt[] = R"META(
你是机器狗任务规划器。根据【元操作字典】将用户自然语言分解为元动作，或判定超出能力。

【元操作字典】仅允许两种 op，不得发明其它 op / 字段：
1) mode — {"op":"mode","key":"<k>"}
   合法 key：r 阻尼；z 站立；v 行走；b 后空翻；j 跳跃；k 挥手
   禁止 key=x（空闲）：该模式会释放关节，存在安全隐患，规划结果中不得出现
2) vel — {"op":"vel","fwd":<f>,"side":<f>,"yaw":<f>,"duration_ms":<n>}
   坐标系：fwd>0 前进、<0 后退；side>0 左移、<0 右移；yaw>0 左转、<0 右转
   duration_ms 必须为 >0 的整数；建议 |fwd|≤0.7、|side|≤0.5、|yaw|≤0.7
   距离类指令用「名义速度×时长」近似，勿发明 distance 字段

【自然语言别名 → mode.key】常见中文口令必须映射到已有 key，不得当作未定义动作或 beyond_capability：
- 坐下 / 趴下 / 阻尼 / 放松关节 / 空闲 / 待机 → key "r"（阻尼；口语「空闲/待机」也用 r，禁止输出 key=x）
- 站立 / 起立 / 站起来 → key "z"
- 行走 / 走路 / 开始走 → key "v"（非零 vel 前常先切 v）
- 跳跃 / 跳一下 → key "j"
- 后空翻 / 翻个跟头 → key "b"
- 打招呼 / 打个招呼 / 招手 / 挥手 → key "k"（挥手姿态，不是语音对话）

【规划约束】
- 非零 vel 前通常先 {"op":"mode","key":"v"}；结束可视需要切回阻尼 {"op":"mode","key":"r"}（勿用 x）
- 能用字典完成时：只输出一个 JSON 数组（不要 markdown、不要解释），例如：
  [{"op":"mode","key":"v"},{"op":"vel","fwd":0.4,"side":0.0,"yaw":0.0,"duration_ms":5000},{"op":"mode","key":"r"}]
- 姿态/手势正例（直接输出数组即可）：
  坐下 → [{"op":"mode","key":"r"}]
  打个招呼 → [{"op":"mode","key":"k"}]
  站起来 → [{"op":"mode","key":"z"}]

【超出能力】
beyond_capability 仅用于真正无法用 mode/vel 完成的任务（例如：开门、抓取、飞行、游泳、精确地图导航到某地、语音说话/对话聊天、识别特定物体后操作、爬楼梯闭环等）。
坐下、趴下、打招呼、招手、站立、行走、跳跃、后空翻等常见狗姿态/手势口令属于上表别名，必须输出对应 mode，禁止 beyond_capability。
若确属超出能力，则不要输出 actions 数组，只输出下面这个 JSON 对象（不要 markdown）：
  {"ok":false,"reason":"beyond_capability","msg":"<简短中文说明：缺什么能力、为何做不到>"}
)META";

/** 规划结果：成功带 actions；超出能力时 ok=false 且 actions 为空数组。 */
struct PlanResult {
  bool ok = false;
  std::string reason;       // 成功可空；失败常用 beyond_capability / openclaw_error
  std::string actions_json; // 成功为 [...] ；失败为 []
  std::string msg;
};

struct HttpClientResult {
  bool ok = false;
  int status = 0;
  std::string body;
  std::string error;
};

/** 解析 http://host:port/path 形式的 URL（仅支持 http，供本机 OpenClaw 使用）。 */
bool parse_http_url(const std::string& url, std::string& host, int& port, std::string& path) {
  const std::string prefix = "http://";
  if (url.compare(0, prefix.size(), prefix) != 0) {
    return false;
  }
  std::string rest = url.substr(prefix.size());
  size_t slash = rest.find('/');
  std::string hostport = (slash == std::string::npos) ? rest : rest.substr(0, slash);
  path = (slash == std::string::npos) ? "/" : rest.substr(slash);
  if (hostport.empty()) {
    return false;
  }
  size_t colon = hostport.find(':');
  if (colon == std::string::npos) {
    host = hostport;
    port = 80;
  } else {
    host = hostport.substr(0, colon);
    port = std::atoi(hostport.c_str() + colon + 1);
    if (port <= 0 || port >= 65536) {
      return false;
    }
  }
  return !host.empty() && !path.empty();
}

/**
 * 向本机 OpenClaw 发非流式 HTTP POST。
 * 使用原始套接字，避免引入 libcurl；超时默认 600s（Agent 可能较慢）。
 */
HttpClientResult http_post_json(const std::string& url, const std::string& json_body,
                                int timeout_sec) {
  HttpClientResult r;
  std::string host;
  int port = 0;
  std::string path;
  if (!parse_http_url(url, host, port, path)) {
    r.error = "invalid OPENCLAW_URL (expect http://host:port/path)";
    return r;
  }

  int fd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    r.error = std::string("socket: ") + std::strerror(errno);
    return r;
  }

  timeval tv{};
  tv.tv_sec = timeout_sec > 0 ? timeout_sec : kDefaultOpenClawTimeoutSec;
  tv.tv_usec = 0;
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(static_cast<uint16_t>(port));
  if (::inet_pton(AF_INET, host.c_str(), &addr.sin_addr) != 1) {
    ::close(fd);
    r.error = "inet_pton failed for host=" + host;
    return r;
  }

  if (::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
    r.error = std::string("connect ") + host + ":" + std::to_string(port) + ": " +
              std::strerror(errno);
    ::close(fd);
    return r;
  }

  std::ostringstream req;
  req << "POST " << path << " HTTP/1.1\r\n"
      << "Host: " << host << ":" << port << "\r\n"
      << "Content-Type: application/json\r\n"
      << "Accept: application/json\r\n"
      << "Connection: close\r\n"
      << "Content-Length: " << json_body.size() << "\r\n"
      << "\r\n"
      << json_body;
  const std::string req_s = req.str();

  size_t sent = 0;
  while (sent < req_s.size()) {
    ssize_t n = ::send(fd, req_s.data() + sent, req_s.size() - sent, 0);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      r.error = std::string("send: ") + std::strerror(errno);
      ::close(fd);
      return r;
    }
    if (n == 0) {
      r.error = "send: connection closed";
      ::close(fd);
      return r;
    }
    sent += static_cast<size_t>(n);
  }

  std::string raw;
  char buf[4096];
  while (true) {
    ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      if (errno == EAGAIN || errno == EWOULDBLOCK) {
        r.error = "recv timeout waiting for OpenClaw";
      } else {
        r.error = std::string("recv: ") + std::strerror(errno);
      }
      ::close(fd);
      return r;
    }
    if (n == 0) {
      break;
    }
    raw.append(buf, static_cast<size_t>(n));
    if (raw.size() > 8 * 1024 * 1024) {
      r.error = "OpenClaw response too large";
      ::close(fd);
      return r;
    }
  }
  ::close(fd);

  const size_t hdr_end = raw.find("\r\n\r\n");
  if (hdr_end == std::string::npos) {
    r.error = "OpenClaw response missing HTTP header end";
    return r;
  }
  const std::string status_line = raw.substr(0, raw.find("\r\n"));
  // HTTP/1.1 200 OK
  size_t sp1 = status_line.find(' ');
  if (sp1 != std::string::npos) {
    r.status = std::atoi(status_line.c_str() + sp1 + 1);
  }
  r.body = raw.substr(hdr_end + 4);
  r.ok = (r.status >= 200 && r.status < 300);
  if (!r.ok && r.error.empty()) {
    r.error = "OpenClaw HTTP status=" + std::to_string(r.status);
  }
  return r;
}

/**
 * 固定元动作序列（NPU_STUB=1 时使用）。
 * 起立(z) → 原地等待约 5s → 阻尼(r)。
 */
std::string stub_actions_json() {
  return R"([)"
         R"({"op":"mode","key":"z"},)"
         R"({"op":"vel","fwd":0.0,"side":0.0,"yaw":0.0,"duration_ms":5000},)"
         R"({"op":"mode","key":"r"})"
         R"(])";
}

/**
 * Stub 侧粗判：明显超出当前 mode/vel 能力时返回 true。
 * 正式环境由 openclaw 按 kMetaActionSystemPrompt 判定。
 */
bool stub_looks_beyond_capability(const std::string& text) {
  static const char* kHints[] = {
      "飞",   "游泳", "潜水", "开门", "关门", "拿起", "抓取", "搬运",
      "倒水", "说话", "唱歌", "对话", "爬楼", "上楼梯", "下楼梯",
      "导航到", "地图", "定位", "识别", "充电", "插电", "跟随人",
      "开门禁", "按电梯", "超越能力", "超出能力",
  };
  for (const char* h : kHints) {
    if (text.find(h) != std::string::npos) {
      return true;
    }
  }
  return false;
}

PlanResult plan_with_stub(const std::string& text) {
  PlanResult r;
  if (stub_looks_beyond_capability(text)) {
    r.ok = false;
    r.reason = "beyond_capability";
    r.actions_json = "[]";
    r.msg = "超出当前元操作库能力：仅支持模式切换(mode)与速度段(vel)，无法完成该指令所要求的操作";
    std::cout << "[npu] stub plan reject: beyond_capability" << std::endl;
    return r;
  }
  r.ok = true;
  r.actions_json = stub_actions_json();
  r.msg = "stub: stand(z) → wait 5s → damp(r)";
  return r;
}

/** 拼给模型的用户侧消息：仅本轮自然语言（字典与超出能力规则在 system prompt）。 */
std::string build_openclaw_user_message(const std::string& text) {
  std::ostringstream oss;
  oss << "用户指令：\n" << text
      << "\n\n若可用元操作字典完成：只输出 actions JSON 数组；"
         "若超出能力：只输出 {\"ok\":false,\"reason\":\"beyond_capability\",\"msg\":\"...\"}。";
  return oss.str();
}

/** 组装 OpenClaw Chat Completions 请求体（非流式）。 */
std::string build_openclaw_request_body(const std::string& conversation_id,
                                        const std::string& user_msg) {
  std::ostringstream oss;
  oss << "{"
      << "\"model\":\"" << kOpenClawModel << "\","
      << "\"stream\":false,";
  if (!conversation_id.empty()) {
    oss << "\"user\":\"conversation:" << json_escape(conversation_id) << "\",";
  }
  oss << "\"messages\":["
      << "{\"role\":\"system\",\"content\":\"" << json_escape(kMetaActionSystemPrompt) << "\"},"
      << "{\"role\":\"user\",\"content\":\"" << json_escape(user_msg) << "\"}"
      << "]"
      << "}";
  return oss.str();
}

/**
 * 从 OpenClaw Chat Completions JSON 中取出 choices[0].message.content。
 * 同时校验 finish_reason（允许 stop；length 视为截断错误）。
 */
bool extract_openclaw_reply(const std::string& response_json, std::string& content_out,
                            std::string& finish_reason_out, std::string& request_id_out,
                            std::string& err_out) {
  request_id_out = json_unescape(extract_json_string(response_json, "id"));

  const size_t choices_pos = response_json.find("\"choices\"");
  if (choices_pos == std::string::npos) {
    err_out = "OpenClaw 响应中没有 choices";
    return false;
  }

  finish_reason_out = extract_json_string_after(response_json, choices_pos, "finish_reason");
  const std::string raw_content =
      extract_json_string_after(response_json, choices_pos, "content");
  if (raw_content.empty()) {
    // 有时 finish_reason 在 content 之后；再全局兜底一次
    const std::string fallback = extract_json_string(response_json, "content");
    if (fallback.empty()) {
      err_out = "OpenClaw 响应中没有 message.content";
      return false;
    }
    content_out = trim_ws(json_unescape(fallback));
  } else {
    content_out = trim_ws(json_unescape(raw_content));
  }

  if (finish_reason_out == "length") {
    err_out = "OpenClaw 回答因 token 限制被截断";
    return false;
  }
  if (!finish_reason_out.empty() && finish_reason_out != "stop") {
    err_out = "OpenClaw 返回非预期 finish_reason: " + finish_reason_out;
    return false;
  }
  if (content_out.empty()) {
    err_out = "OpenClaw 返回了空回答";
    return false;
  }
  return true;
}

/**
 * 将模型输出解析为 PlanResult。
 * 期望：纯 JSON 数组（actions）或 beyond_capability 对象。
 */
PlanResult parse_plan_from_model_reply(const std::string& reply) {
  PlanResult r;
  const std::string text = strip_markdown_fence(reply);
  if (text.empty()) {
    r.ok = false;
    r.reason = "openclaw_error";
    r.actions_json = "[]";
    r.msg = "模型返回空内容";
    return r;
  }

  if (text[0] == '[') {
    // 粗校验：应以 ] 结束
    if (text.back() != ']') {
      r.ok = false;
      r.reason = "openclaw_error";
      r.actions_json = "[]";
      r.msg = "模型返回的 actions 不是完整 JSON 数组";
      return r;
    }
    r.ok = true;
    r.actions_json = text;
    r.msg = "openclaw";
    return r;
  }

  if (text[0] == '{') {
    const std::string reason = extract_json_string(text, "reason");
    const std::string msg = json_unescape(extract_json_string(text, "msg"));
    const bool looks_reject =
        text.find("\"ok\":false") != std::string::npos ||
        text.find("\"ok\": false") != std::string::npos ||
        reason == "beyond_capability";
    if (looks_reject) {
      r.ok = false;
      r.reason = reason.empty() ? "beyond_capability" : reason;
      r.actions_json = "[]";
      r.msg = msg.empty()
                  ? "超出当前元操作库能力：仅支持模式切换(mode)与速度段(vel)"
                  : msg;
      return r;
    }
  }

  r.ok = false;
  r.reason = "openclaw_error";
  r.actions_json = "[]";
  r.msg = "无法解析模型输出（既非 actions 数组也非 beyond_capability）: " +
          text.substr(0, 200);
  return r;
}

/**
 * 对接 OpenClaw：system = kMetaActionSystemPrompt，user = 用户原文。
 * 请求 http://127.0.0.1:18789/v1/chat/completions ，model=openclaw/default。
 * 设置 NPU_STUB=1 可回退到本地固定序列。
 */
PlanResult plan_with_openclaw(const std::string& text, const std::string& request_id) {
  const std::string user_msg = build_openclaw_user_message(text);
  std::cout << "[npu] plan prompt ready: system_chars="
            << (sizeof(kMetaActionSystemPrompt) - 1)
            << " user_chars=" << user_msg.size()
            << " text=\"" << text << "\""
            << " request_id=\"" << request_id << "\"" << std::endl;

  if (env_stub_mode()) {
    std::cout << "[npu] NPU_STUB=1 → local stub planner" << std::endl;
    return plan_with_stub(text);
  }

  const std::string url = env_or("OPENCLAW_URL", kDefaultOpenClawUrl);
  const int timeout_sec = env_openclaw_timeout_sec();
  const std::string conv_id = request_id.empty() ? "anon" : request_id;
  const std::string payload = build_openclaw_request_body(conv_id, user_msg);

  std::cout << "[npu] openclaw POST " << url << " model=" << kOpenClawModel
            << " user=conversation:" << conv_id
            << " timeout_sec=" << timeout_sec
            << " payload_bytes=" << payload.size() << std::endl;

  const auto t0 = std::chrono::steady_clock::now();
  const HttpClientResult http = http_post_json(url, payload, timeout_sec);
  const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                      std::chrono::steady_clock::now() - t0)
                      .count();

  if (!http.ok) {
    PlanResult r;
    r.ok = false;
    r.reason = "openclaw_error";
    r.actions_json = "[]";
    std::ostringstream msg;
    msg << "OpenClaw 调用失败: " << http.error;
    if (http.status > 0) {
      msg << " status=" << http.status;
    }
    if (!http.body.empty()) {
      msg << " body=" << http.body.substr(0, 500);
    }
    r.msg = msg.str();
    std::cout << "[npu] openclaw error after " << ms << "ms: " << r.msg << std::endl;
    return r;
  }

  std::string content;
  std::string finish_reason;
  std::string oc_id;
  std::string extract_err;
  if (!extract_openclaw_reply(http.body, content, finish_reason, oc_id, extract_err)) {
    PlanResult r;
    r.ok = false;
    r.reason = "openclaw_error";
    r.actions_json = "[]";
    r.msg = extract_err + " body=" + http.body.substr(0, 500);
    std::cout << "[npu] openclaw parse error after " << ms << "ms: " << extract_err
              << " id=" << oc_id << std::endl;
    return r;
  }

  std::cout << "[npu] openclaw ok after " << ms << "ms id=" << oc_id
            << " finish_reason=" << finish_reason
            << " reply_chars=" << content.size() << std::endl;
  std::cout << "[npu] openclaw reply: " << content.substr(0, 500)
            << (content.size() > 500 ? "..." : "") << std::endl;

  PlanResult plan = parse_plan_from_model_reply(content);
  if (plan.ok) {
    std::cout << "[npu] plan accept: actions from openclaw" << std::endl;
  } else {
    std::cout << "[npu] plan reject: reason=" << plan.reason << " msg=" << plan.msg
              << std::endl;
  }
  return plan;
}

std::string build_plan_response(const std::string& request_id, const std::string& text) {
  const std::string rid = request_id.empty() ? "anon" : request_id;
  const PlanResult plan = plan_with_openclaw(text, rid);
  std::ostringstream oss;
  oss << "{"
      << "\"v\":1,"
      << "\"request_id\":\"" << json_escape(rid) << "\","
      << "\"ok\":" << (plan.ok ? "true" : "false") << ",";
  if (!plan.reason.empty()) {
    oss << "\"reason\":\"" << json_escape(plan.reason) << "\",";
  }
  oss << "\"actions\":" << plan.actions_json << ","
      << "\"msg\":\"" << json_escape(plan.msg) << "\""
      << "}";
  return oss.str();
}

std::string http_response(int code, const char* status, const std::string& body,
                          const std::string& content_type = "application/json; charset=utf-8") {
  std::ostringstream oss;
  oss << "HTTP/1.1 " << code << " " << status << "\r\n"
      << "Content-Type: " << content_type << "\r\n"
      << "Content-Length: " << body.size() << "\r\n"
      << "Connection: close\r\n"
      << "Access-Control-Allow-Origin: *\r\n"
      << "\r\n"
      << body;
  return oss.str();
}

bool check_bearer(const std::string& headers, const std::string& expect_token) {
  // 允许 Authorization: Bearer xxx（大小写不敏感于 Bearer 前缀的简单查找）
  const std::string key = "Authorization:";
  size_t pos = headers.find(key);
  if (pos == std::string::npos) {
    // 兼容小写
    pos = headers.find("authorization:");
  }
  if (pos == std::string::npos) {
    return false;
  }
  size_t line_end = headers.find("\r\n", pos);
  std::string line = headers.substr(pos, line_end == std::string::npos ? std::string::npos : line_end - pos);
  const std::string prefix = "Bearer ";
  size_t b = line.find(prefix);
  if (b == std::string::npos) {
    b = line.find("bearer ");
  }
  if (b == std::string::npos) {
    return false;
  }
  std::string tok = line.substr(b + prefix.size());
  // trim
  while (!tok.empty() && (tok.back() == ' ' || tok.back() == '\r' || tok.back() == '\t')) {
    tok.pop_back();
  }
  return tok == expect_token;
}

/**
 * 处理已读完整的 HTTP 请求文本，返回响应字节。
 */
std::string handle_request(const std::string& raw, const std::string& expect_token) {
  const size_t hdr_end = raw.find("\r\n\r\n");
  if (hdr_end == std::string::npos) {
    return http_response(400, "Bad Request", "{\"ok\":false,\"msg\":\"bad request\"}");
  }
  const std::string head = raw.substr(0, hdr_end);
  const std::string body = raw.substr(hdr_end + 4);

  std::istringstream hs(head);
  std::string method, path, version;
  hs >> method >> path >> version;

  std::cout << "[npu] " << method << " " << path << " body_len=" << body.size() << std::endl;

  if (method == "GET" && (path == "/health" || path.find("/health?") == 0)) {
    return http_response(200, "OK", "{\"ok\":true,\"service\":\"npu_plan_server\"}");
  }

  if (method == "OPTIONS") {
    // 预检（浏览器调试用）；手机 App 一般不走 CORS
    return http_response(204, "No Content", "");
  }

  if (method == "POST" && (path == "/v1/plan" || path.find("/v1/plan?") == 0)) {
    if (!check_bearer(head, expect_token)) {
      std::cout << "[npu] unauthorized" << std::endl;
      return http_response(401, "Unauthorized",
                           "{\"ok\":false,\"msg\":\"missing or invalid Bearer token\"}");
    }
    const std::string text = extract_json_string(body, "text");
    const std::string rid = extract_json_string(body, "request_id");
    std::cout << "[npu] plan text=\"" << text << "\" request_id=\"" << rid << "\"" << std::endl;
    const std::string resp = build_plan_response(rid, text);
    return http_response(200, "OK", resp);
  }

  return http_response(404, "Not Found", "{\"ok\":false,\"msg\":\"not found\"}");
}

/** 从 fd 读到双 CRLF 且 body 收齐（按 Content-Length） */
bool read_http_message(int fd, std::string& out) {
  out.clear();
  char buf[4096];
  while (true) {
    ssize_t n = ::recv(fd, buf, sizeof(buf), 0);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      return false;
    }
    if (n == 0) {
      break;
    }
    out.append(buf, static_cast<size_t>(n));
    size_t hdr_end = out.find("\r\n\r\n");
    if (hdr_end == std::string::npos) {
      if (out.size() > 1024 * 1024) {
        return false;
      }
      continue;
    }
    // Content-Length
    size_t cl_pos = out.find("Content-Length:");
    if (cl_pos == std::string::npos) {
      cl_pos = out.find("content-length:");
    }
    size_t need = 0;
    if (cl_pos != std::string::npos && cl_pos < hdr_end) {
      need = static_cast<size_t>(std::atoi(out.c_str() + cl_pos + 15));
    }
    if (out.size() >= hdr_end + 4 + need) {
      out.resize(hdr_end + 4 + need);
      return true;
    }
  }
  return !out.empty();
}

bool send_all(int fd, const std::string& data) {
  size_t sent = 0;
  while (sent < data.size()) {
    ssize_t n = ::send(fd, data.data() + sent, data.size() - sent, 0);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      return false;
    }
    if (n == 0) {
      return false;
    }
    sent += static_cast<size_t>(n);
  }
  return true;
}

void handle_client_plain(int cfd, const std::string& token) {
  std::string req;
  if (!read_http_message(cfd, req)) {
    ::close(cfd);
    return;
  }
  const std::string resp = handle_request(req, token);
  send_all(cfd, resp);
  ::close(cfd);
}

#if defined(NPU_ENABLE_TLS)

struct BioFd {
  SSL* ssl;
};

bool ssl_read_http(SSL* ssl, std::string& out) {
  out.clear();
  char buf[4096];
  while (true) {
    int n = SSL_read(ssl, buf, sizeof(buf));
    if (n <= 0) {
      break;
    }
    out.append(buf, static_cast<size_t>(n));
    size_t hdr_end = out.find("\r\n\r\n");
    if (hdr_end == std::string::npos) {
      if (out.size() > 1024 * 1024) {
        return false;
      }
      continue;
    }
    size_t cl_pos = out.find("Content-Length:");
    if (cl_pos == std::string::npos) {
      cl_pos = out.find("content-length:");
    }
    size_t need = 0;
    if (cl_pos != std::string::npos && cl_pos < hdr_end) {
      need = static_cast<size_t>(std::atoi(out.c_str() + cl_pos + 15));
    }
    if (out.size() >= hdr_end + 4 + need) {
      out.resize(hdr_end + 4 + need);
      return true;
    }
  }
  return !out.empty();
}

bool ssl_send_all(SSL* ssl, const std::string& data) {
  size_t sent = 0;
  while (sent < data.size()) {
    int n = SSL_write(ssl, data.data() + sent, static_cast<int>(data.size() - sent));
    if (n <= 0) {
      return false;
    }
    sent += static_cast<size_t>(n);
  }
  return true;
}

void handle_client_tls(SSL_CTX* ctx, int cfd, const std::string& token) {
  SSL* ssl = SSL_new(ctx);
  if (!ssl) {
    ::close(cfd);
    return;
  }
  SSL_set_fd(ssl, cfd);
  if (SSL_accept(ssl) <= 0) {
    ERR_print_errors_fp(stderr);
    SSL_free(ssl);
    ::close(cfd);
    return;
  }
  std::string req;
  if (ssl_read_http(ssl, req)) {
    const std::string resp = handle_request(req, token);
    ssl_send_all(ssl, resp);
  }
  SSL_shutdown(ssl);
  SSL_free(ssl);
  ::close(cfd);
}

SSL_CTX* create_ssl_ctx(const std::string& cert, const std::string& key) {
  SSL_library_init();
  SSL_load_error_strings();
  OpenSSL_add_ssl_algorithms();
  SSL_CTX* ctx = SSL_CTX_new(TLS_server_method());
  if (!ctx) {
    return nullptr;
  }
  if (SSL_CTX_use_certificate_file(ctx, cert.c_str(), SSL_FILETYPE_PEM) <= 0 ||
      SSL_CTX_use_PrivateKey_file(ctx, key.c_str(), SSL_FILETYPE_PEM) <= 0) {
    ERR_print_errors_fp(stderr);
    SSL_CTX_free(ctx);
    return nullptr;
  }
  return ctx;
}

#endif  // NPU_ENABLE_TLS

void print_usage(const char* argv0) {
  std::cerr
      << "Usage: " << argv0 << " [--http] [--port N] [--token STR]"
#if defined(NPU_ENABLE_TLS)
      << " [--cert pem --key pem]"
#endif
      << "\n"
      << "  Env: NPU_PORT NPU_TOKEN OPENCLAW_URL OPENCLAW_TIMEOUT_SEC NPU_STUB"
#if defined(NPU_ENABLE_TLS)
      << " NPU_CERT NPU_KEY"
#endif
      << "\n"
      << "  Default: port " << kDefaultPort << ", token \"" << kDefaultToken << "\"\n"
      << "  OpenClaw: " << kDefaultOpenClawUrl << " model=" << kOpenClawModel << "\n";
}

}  // namespace

int main(int argc, char** argv) {
  bool force_http = false;
  int port = env_port();
  std::string token = env_or("NPU_TOKEN", kDefaultToken);
  std::string cert = env_or("NPU_CERT", "certs/server.crt");
  std::string key = env_or("NPU_KEY", "certs/server.key");

  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    if (a == "--http") {
      force_http = true;
    } else if (a == "--port" && i + 1 < argc) {
      port = std::atoi(argv[++i]);
    } else if (a == "--token" && i + 1 < argc) {
      token = argv[++i];
    } else if (a == "--cert" && i + 1 < argc) {
      cert = argv[++i];
    } else if (a == "--key" && i + 1 < argc) {
      key = argv[++i];
    } else if (a == "-h" || a == "--help") {
      print_usage(argv[0]);
      return 0;
    } else {
      std::cerr << "Unknown arg: " << a << "\n";
      print_usage(argv[0]);
      return 1;
    }
  }

  install_stop_signals();

  int lfd = ::socket(AF_INET, SOCK_STREAM, 0);
  if (lfd < 0) {
    perror("socket");
    return 1;
  }
  int yes = 1;
  setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_ANY);
  addr.sin_port = htons(static_cast<uint16_t>(port));
  if (bind(lfd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
    perror("bind");
    ::close(lfd);
    return 1;
  }
  if (listen(lfd, 16) < 0) {
    perror("listen");
    ::close(lfd);
    return 1;
  }
  g_listen_fd.store(lfd);

#if defined(NPU_ENABLE_TLS)
  SSL_CTX* ctx = nullptr;
  const bool use_tls = !force_http;
  if (use_tls) {
    ctx = create_ssl_ctx(cert, key);
    if (!ctx) {
      std::cerr << "[npu] TLS init failed; use --http or fix cert/key\n";
      g_listen_fd.store(-1);
      ::close(lfd);
      return 1;
    }
    std::cout << "[npu] HTTPS listening 0.0.0.0:" << port << " cert=" << cert << std::endl;
  } else {
    std::cout << "[npu] HTTP (plaintext) listening 0.0.0.0:" << port << std::endl;
  }
#else
  (void)force_http;
  (void)cert;
  (void)key;
  std::cout << "[npu] HTTP listening 0.0.0.0:" << port
            << " (rebuild with make tls for HTTPS)" << std::endl;
#endif

  std::cout << "[npu] token configured, POST /v1/plan  GET /health" << std::endl;
  if (env_stub_mode()) {
    std::cout << "[npu] planner=stub (NPU_STUB=1)" << std::endl;
  } else {
    std::cout << "[npu] planner=openclaw url="
              << env_or("OPENCLAW_URL", kDefaultOpenClawUrl)
              << " model=" << kOpenClawModel
              << " timeout_sec=" << env_openclaw_timeout_sec() << std::endl;
  }

  while (g_running) {
    sockaddr_in cli{};
    socklen_t cl = sizeof(cli);
    int cfd = ::accept(lfd, reinterpret_cast<sockaddr*>(&cli), &cl);
    if (cfd < 0) {
      if (!g_running || errno == EBADF || errno == EINVAL) {
        break;
      }
      if (errno == EINTR) {
        continue;
      }
      perror("accept");
      continue;
    }
    char ipbuf[64];
    inet_ntop(AF_INET, &cli.sin_addr, ipbuf, sizeof(ipbuf));
    std::cout << "[npu] accept " << ipbuf << ":" << ntohs(cli.sin_port) << std::endl;

#if defined(NPU_ENABLE_TLS)
    if (ctx) {
      std::thread(handle_client_tls, ctx, cfd, token).detach();
    } else {
      std::thread(handle_client_plain, cfd, token).detach();
    }
#else
    std::thread(handle_client_plain, cfd, token).detach();
#endif
  }

  // 若信号里已 close，此处不再关；否则正常收尾
  {
    const int fd = g_listen_fd.exchange(-1);
    if (fd >= 0) {
      ::close(fd);
    }
  }
#if defined(NPU_ENABLE_TLS)
  if (ctx) {
    SSL_CTX_free(ctx);
  }
#endif
  std::cout << "[npu] shutdown" << std::endl;
  return 0;
}
