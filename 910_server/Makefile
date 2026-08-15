# Ascend 910 薄规划服务
#   make          → 纯 HTTP（无 OpenSSL 依赖，便于连通性测试）
#   make tls      → HTTPS（需 openssl-devel）
#   make run      → 默认 HTTP 启动
#   make run-tls  → HTTPS 启动（需先 make certs && make tls）

CXX      ?= g++
CXXFLAGS ?= -O2 -std=c++17 -Wall -Wextra -pthread
LDFLAGS  ?= -pthread

TARGET := npu_plan_server

.PHONY: all tls clean run run-tls certs install-service

all: $(TARGET)

$(TARGET): main.cpp
	$(CXX) $(CXXFLAGS) -o $@ main.cpp $(LDFLAGS)
	@echo "built $@ (HTTP). For HTTPS: make tls"

tls: main.cpp
	$(CXX) $(CXXFLAGS) -DNPU_ENABLE_TLS -o $(TARGET) main.cpp $(LDFLAGS) -lssl -lcrypto
	@echo "built $(TARGET) (HTTPS+HTTP via --http)"

run: $(TARGET)
	./$(TARGET) --http --port $${NPU_PORT:-8443} --token $${NPU_TOKEN:-robotpi}

run-tls: tls
	./$(TARGET) --port $${NPU_PORT:-8443} --token $${NPU_TOKEN:-robotpi} \
		--cert $${NPU_CERT:-certs/server.crt} --key $${NPU_KEY:-certs/server.key}

# 自签证书（演示用；手机信任自签较麻烦，公网建议正规证书或反向代理）
certs:
	mkdir -p certs
	openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
		-keyout certs/server.key -out certs/server.crt \
		-subj "/CN=npu-plan-server/O=RoboPi/C=CN"
	@echo "wrote certs/server.crt certs/server.key"

clean:
	rm -f $(TARGET)

# 将 systemd 单元拷到用户目录示例（需按实际路径改 WorkingDirectory）
install-service:
	@echo "Edit scripts/npu_plan_server.service then:"
	@echo "  sudo cp scripts/npu_plan_server.service /etc/systemd/system/"
	@echo "  sudo systemctl daemon-reload && sudo systemctl enable --now npu_plan_server"
