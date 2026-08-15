# Android 局域网控狗（Kotlin）

与 `phone/ip.ets`（鸿蒙 ArkTS）功能对齐：UDP 发现 + TCP hello 鉴权 + vel/mode 控狗。

## 目录

```
phone/android/
  app/src/main/java/com/robotpi/dogctrl/IpDogCtrlActivity.kt   # 主逻辑
  app/src/main/res/layout/activity_ip_dog_ctrl.xml             # 主界面
  app/src/main/res/layout/item_dog_device.xml                  # 设备列表项
  app/src/main/AndroidManifest.xml
  app/build.gradle.kts
```

## 协议（与狗端 OhPhone / test_ip 一致）

| 步骤 | 动作 |
|------|------|
| 发现 | UDP 广播 `{"type":"discover",...}` → 端口 **9871** |
| 宣告 | 收 `{"type":"announce","ip","port","token","name"}` |
| 连接 | TCP 连 announce 的 ip:port，发 `hello` |
| 控狗 | `vel`（100ms 周期按住发送）、`mode`（r/x/z/v/b/j/k） |

## 用 Android Studio 打开

1. Android Studio → **Open** → 选择本目录 `phone/android`
2. 等待 Gradle Sync
3. 连接手机与狗机同一 Wi‑Fi，运行 `app`
4. 狗端先启动：`./test_ip` 或集成 OhPhone 的 `rl_deploy`

## 权限说明

- `INTERNET`：TCP/UDP
- `ACCESS_NETWORK_STATE` / `ACCESS_WIFI_STATE`：网络状态
- `CHANGE_WIFI_MULTICAST_STATE`：利于局域网广播
- `usesCleartextTraffic=true`：允许明文 TCP（局域网非 TLS）

## 与鸿蒙版差异

| | ArkTS (`ip.ets`) | Kotlin（本目录） |
|--|------------------|------------------|
| UI | ArkUI `@Component` | XML + AppCompatActivity |
| Socket | `@kit.NetworkKit` | `java.net.DatagramSocket` / `Socket` |
| 定时 | `setInterval` | 后台线程 + `Thread.sleep` |
| JSON | 手写字段提取 | `org.json.JSONObject` |
