/**
 * Ascend 910 端云协同 — 薄 HTTP(S) 规划服务（连通性测试桩）
 *
 * 职责：
 *   1) 监听端口，接收手机 POST /v1/plan（自然语言指令）
 *   2) 规划侧常驻 kMetaActionSystemPrompt（元操作字典）；手机不传字典
 *   3) 当前 openclaw/ibrobot 未部署：仍返回固定 stub 序列（连通性）
 *   4) 日后在 plan_with_openclaw() 中把 system+user 交给 openclaw 即可
 *
 * 协议（JSON UTF-8）：
 *   POST /v1/plan
 *     Header: Authorization: Bearer <token>   （可用环境变量 NPU_TOKEN，默认 robotpi）
 *             Content-Type: application/json
 *     Body:   {"v":1,"request_id":"...","text":"..."}
 *     Resp:   {"v":1,"request_id":"...","ok":true,"actions":[...],"msg":"stub"}
 *
 *   GET /health  →  {"ok":true,"service":"npu_plan_server"}
 *
 * 编译 / 运行见同目录 Makefile 与 docs/910_server_support.md
 */

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
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

/** 简易 JSON 字符串转义（仅处理引号与反斜杠） */
std::string json_escape(const std::string& s) {
  std::string out;
  out.reserve(s.size() + 8);
  for (char c : s) {
    if (c == '\\' || c == '"') {
      out.push_back('\\');
    }
    out.push_back(c);
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

/**
 * 常驻系统提示：元操作库（与 task/910_server.md / docs/910_server_support.md 一致）。
 * 对接 openclaw / LLM 时作为 system（或等价）prompt；手机请求体只带用户自然语言，不附带本字典。
 */
static const char kMetaActionSystemPrompt[] = R"META(
你是机器狗任务规划器。根据【元操作字典】将用户自然语言分解为元动作，或判定超出能力。

【元操作字典】仅允许两种 op，不得发明其它 op / 字段：
1) mode — {"op":"mode","key":"<k>"}
   合法 key：r 阻尼；x 空闲；z 站立；v 行走；b 后空翻；j 跳跃；k 挥手
2) vel — {"op":"vel","fwd":<f>,"side":<f>,"yaw":<f>,"duration_ms":<n>}
   坐标系：fwd>0 前进、<0 后退；side>0 左移、<0 右移；yaw>0 左转、<0 右转
   duration_ms 必须为 >0 的整数；建议 |fwd|≤0.7、|side|≤0.5、|yaw|≤0.7
   距离类指令用「名义速度×时长」近似，勿发明 distance 字段

【规划约束】
- 非零 vel 前通常先 {"op":"mode","key":"v"}；结束可视需要 {"op":"mode","key":"x"}
- 能用字典完成时：只输出一个 JSON 数组（不要 markdown、不要解释），例如：
  [{"op":"mode","key":"v"},{"op":"vel","fwd":0.4,"side":0.0,"yaw":0.0,"duration_ms":5000},{"op":"mode","key":"x"}]

【超出能力】
若任务无法仅用上述 mode/vel 可靠完成（例如：开门、抓取、飞行、游泳、精确地图导航、语音对话、识别特定物体后操作、爬楼梯闭环等），
则不要输出 actions 数组，只输出下面这个 JSON 对象（不要 markdown）：
  {"ok":false,"reason":"beyond_capability","msg":"<简短中文说明：缺什么能力、为何做不到>"}
)META";

/** 规划结果：成功带 actions；超出能力时 ok=false 且 actions 为空数组。 */
struct PlanResult {
  bool ok = false;
  std::string reason;       // 成功可空；失败常用 beyond_capability
  std::string actions_json; // 成功为 [...] ；失败为 []
  std::string msg;
};

/**
 * 固定元动作序列（连通性 stub）。
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
 * 正式环境由 openclaw 按 kMetaActionSystemPrompt 判定；此处仅便于联调「超出能力」路径。
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

/** 拼给模型的用户侧消息：仅本轮自然语言（字典与超出能力规则在 system prompt）。 */
std::string build_openclaw_user_message(const std::string& text) {
  std::ostringstream oss;
  oss << "用户指令：\n" << text
      << "\n\n若可用元操作字典完成：只输出 actions JSON 数组；"
         "若超出能力：只输出 {\"ok\":false,\"reason\":\"beyond_capability\",\"msg\":\"...\"}。";
  return oss.str();
}

/**
 * 对接 openclaw / ibrobot：system = kMetaActionSystemPrompt，user = 用户原文。
 * 当前未部署：能力内返回 stub 序列；命中 stub 超能力关键词则返回 beyond_capability。
 */
PlanResult plan_with_openclaw(const std::string& text) {
  const std::string user_msg = build_openclaw_user_message(text);
  std::cout << "[npu] plan prompt ready: system_chars="
            << (sizeof(kMetaActionSystemPrompt) - 1)
            << " user_chars=" << user_msg.size()
            << " text=\"" << text << "\"" << std::endl;
  // TODO: 调用 openclaw+ibrobot：
  //   system = kMetaActionSystemPrompt
  //   user   = user_msg
  //   若模型返回 beyond_capability 对象 → PlanResult{ok=false,...}
  //   若模型返回 actions 数组 → PlanResult{ok=true, actions_json=...}
  (void)user_msg;

  PlanResult r;
  if (stub_looks_beyond_capability(text)) {
    r.ok = false;
    r.reason = "beyond_capability";
    r.actions_json = "[]";
    r.msg = "超出当前元操作库能力：仅支持模式切换(mode)与速度段(vel)，无法完成该指令所要求的操作";
    std::cout << "[npu] plan reject: beyond_capability" << std::endl;
    return r;
  }
  r.ok = true;
  r.reason = "";
  r.actions_json = stub_actions_json();
  r.msg = "stub: stand(z) → wait 5s → damp(r)";
  return r;
}

std::string build_plan_response(const std::string& request_id, const std::string& text) {
  const std::string rid = request_id.empty() ? "anon" : request_id;
  const PlanResult plan = plan_with_openclaw(text);
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
      << "  Env: NPU_PORT NPU_TOKEN"
#if defined(NPU_ENABLE_TLS)
      << " NPU_CERT NPU_KEY"
#endif
      << "\n"
      << "  Default: port " << kDefaultPort << ", token \"" << kDefaultToken << "\"\n";
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
  std::cout << "[npu] stub mode: fixed meta-action sequence (openclaw TBD)" << std::endl;

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
