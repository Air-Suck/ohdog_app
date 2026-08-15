/**
 * 机器狗局域网控狗 — Android (Kotlin) 版
 *
 * 与 phone/ip.ets（鸿蒙 ArkTS）协议一致：
 *   1) 点「发现设备」→ UDP 广播 discover（9871）
 *   2) 狗机单播回复 announce（ip / port / token）
 *   3) 点「连接」→ TCP 连狗机 → hello 鉴权
 *   4) 方向键 / 模式键下发 vel、mode
 *
 * 报文均为 UTF-8 JSON 行（以 '\n' 结尾）。
 *
 * 坐标系：fwd 前进为正；side 左移为正；yaw 左转为正。
 *
 * Manifest 需声明：
 *   android.permission.INTERNET
 *   android.permission.ACCESS_NETWORK_STATE
 *   android.permission.CHANGE_WIFI_MULTICAST_STATE（可选，利于广播）
 */
package com.robotpi.dogctrl

import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.MotionEvent
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import org.json.JSONObject
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

// ---------------------------------------------------------------------------
// 常量（与 ip.ets 对齐）
// ---------------------------------------------------------------------------

private const val TAG = "DogIpCtrl"
private const val UDP_PORT = 9871
private const val DISCOVER_ROUNDS = 3
private const val DISCOVER_GAP_MS = 400L
private const val DISCOVER_WINDOW_MS = 2500L
private const val VEL_SEND_MS = 100L
private const val MAX_FWD = 0.7
private const val MAX_SIDE = 0.5
private const val MAX_YAW = 0.7
private const val TCP_CONNECT_TIMEOUT_MS = 5000

/** 已发现的狗机设备条目（key = "ip:port"） */
data class DogDevice(
    val key: String,
    val name: String,
    val ip: String,
    val port: Int,
    val token: String
)

/**
 * 主界面：局域网 UDP 发现 + TCP 鉴权控狗。
 * 布局见 res/layout/activity_ip_dog_ctrl.xml
 */
class IpDogCtrlActivity : AppCompatActivity() {

    // UI
    private lateinit var statusText: TextView
    private lateinit var logText: TextView
    private lateinit var btnDiscover: Button
    private lateinit var btnDisconnect: Button
    private lateinit var dogListContainer: LinearLayout

    // 状态
    private val dogs = ConcurrentHashMap<String, DogDevice>()
    @Volatile private var isDiscovering = false
    @Volatile private var isConnected = false
    @Volatile private var isAuthed = false
    @Volatile private var connectedLabel = ""

    // 网络
    private var udpSocket: DatagramSocket? = null
    private var tcpSocket: Socket? = null
    private var tcpWriter: BufferedWriter? = null
    @Volatile private var holdFwd = 0.0
    @Volatile private var holdSide = 0.0
    @Volatile private var holdYaw = 0.0

    private val mainHandler = Handler(Looper.getMainLooper())
    private val ioExecutor = Executors.newCachedThreadPool()
    private val velRunning = AtomicBoolean(false)
    private var discoverWindowRunnable: Runnable? = null
    private var udpListenThread: Thread? = null
    private val stopUdpListen = AtomicBoolean(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_ip_dog_ctrl)
        bindViews()
        setupMotionButtons()
        setupModeButtons()
        updateStatusUi()
        log("同网后点「发现设备」")
    }

    override fun onDestroy() {
        cleanupAll()
        ioExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun bindViews() {
        statusText = findViewById(R.id.statusText)
        logText = findViewById(R.id.logText)
        btnDiscover = findViewById(R.id.btnDiscover)
        btnDisconnect = findViewById(R.id.btnDisconnect)
        dogListContainer = findViewById(R.id.dogListContainer)

        btnDiscover.setOnClickListener { startDiscover() }
        btnDisconnect.setOnClickListener {
            if (isConnected) {
                disconnectTcp()
            }
        }
    }

    /** 底部日志 + Logcat */
    private fun log(msg: String) {
        Log.i(TAG, msg)
        mainHandler.post { logText.text = msg }
    }

    private fun updateStatusUi() {
        mainHandler.post {
            statusText.text = when {
                isAuthed -> "已连接: $connectedLabel"
                isConnected -> "连接中: $connectedLabel"
                else -> "未连接"
            }
            statusText.setTextColor(
                if (isAuthed) 0xFF1B8A4A.toInt() else 0xFF666666.toInt()
            )
            btnDiscover.isEnabled = !isDiscovering
            btnDiscover.text = if (isDiscovering) "发现中..." else "发现设备"
            btnDisconnect.isEnabled = isConnected
            btnDisconnect.text = if (isConnected) "断开" else "断开"
            refreshDogListUi()
        }
    }

    private fun refreshDogListUi() {
        dogListContainer.removeAllViews()
        val list = dogs.values.sortedBy { it.key }
        for (dog in list) {
            val row = layoutInflater.inflate(R.layout.item_dog_device, dogListContainer, false)
            row.findViewById<TextView>(R.id.dogName).text = dog.name
            row.findViewById<TextView>(R.id.dogAddr).text = "${dog.ip}:${dog.port}"
            row.findViewById<Button>(R.id.btnConnect).apply {
                isEnabled = !isDiscovering
                setOnClickListener { connectDog(dog) }
            }
            dogListContainer.addView(row)
        }
        findViewById<TextView>(R.id.dogListTitle).text = "发现列表 (${list.size})"
    }

    // -------------------------------------------------------------------------
    // UDP 发现
    // -------------------------------------------------------------------------

    private fun ensureUdp() {
        if (udpSocket != null && !udpSocket!!.isClosed) return
        stopUdpListen.set(false)
        val sock = DatagramSocket(null).apply {
            reuseAddress = true
            broadcast = true
            bind(InetSocketAddress(0)) // 系统分配本地端口，收狗机单播
        }
        udpSocket = sock
        udpListenThread = thread(name = "udp-listen", isDaemon = true) {
            val buf = ByteArray(4096)
            while (!stopUdpListen.get() && !sock.isClosed) {
                try {
                    val packet = DatagramPacket(buf, buf.size)
                    sock.receive(packet)
                    val text = String(packet.data, 0, packet.length, StandardCharsets.UTF_8)
                    for (raw in text.split('\n')) {
                        var line = raw.trimEnd('\r', ' ')
                        handleAnnounceLine(line)
                    }
                } catch (_: Exception) {
                    if (stopUdpListen.get() || sock.isClosed) break
                }
            }
        }
    }

    private fun broadcastDiscoverOnce() {
        val sock = udpSocket ?: return
        val payload = "{\"type\":\"discover\",\"v\":1,\"app\":\"RoboPiPhone\"}\n"
            .toByteArray(StandardCharsets.UTF_8)
        val dest = InetAddress.getByName("255.255.255.255")
        sock.send(DatagramPacket(payload, payload.size, dest, UDP_PORT))
    }

    /** 完整发现流程：多轮广播 + 等待窗口收集 announce */
    private fun startDiscover() {
        if (isDiscovering) return
        isDiscovering = true
        dogs.clear()
        updateStatusUi()
        log("正在局域网广播发现...")

        ioExecutor.execute {
            try {
                ensureUdp()
                repeat(DISCOVER_ROUNDS) { i ->
                    broadcastDiscoverOnce()
                    if (i + 1 < DISCOVER_ROUNDS) {
                        Thread.sleep(DISCOVER_GAP_MS)
                    }
                }
            } catch (e: Exception) {
                log("发现失败: ${e.message}")
                isDiscovering = false
                updateStatusUi()
                return@execute
            }

            mainHandler.post {
                discoverWindowRunnable?.let { mainHandler.removeCallbacks(it) }
                val end = Runnable {
                    isDiscovering = false
                    discoverWindowRunnable = null
                    if (dogs.isEmpty()) {
                        log("未发现设备：确认同网、狗端已启动 OhPhone")
                    } else {
                        log("发现结束，共 ${dogs.size} 台")
                    }
                    updateStatusUi()
                }
                discoverWindowRunnable = end
                mainHandler.postDelayed(end, DISCOVER_WINDOW_MS)
            }
        }
    }

    private fun handleAnnounceLine(line: String) {
        if (line.isEmpty()) return
        try {
            val obj = JSONObject(line)
            if (obj.optString("type") != "announce") return
            val ip = obj.optString("ip")
            val name = obj.optString("name").ifEmpty { "RoboPi" }
            val token = obj.optString("token")
            val port = obj.optInt("port", -1)
            if (ip.isEmpty() || port <= 0) return
            val key = "$ip:$port"
            dogs[key] = DogDevice(key, name, ip, port, token)
            log("发现: $name $ip:$port")
            updateStatusUi()
        } catch (_: Exception) {
            // 非 JSON / 脏行忽略
        }
    }

    // -------------------------------------------------------------------------
    // TCP 连接 / 鉴权 / 收发
    // -------------------------------------------------------------------------

    private fun connectDog(dog: DogDevice) {
        if (isConnected) {
            disconnectTcp()
        }
        log("连接 ${dog.name} ${dog.ip}:${dog.port} ...")
        ioExecutor.execute {
            try {
                val sock = Socket()
                sock.tcpNoDelay = true
                sock.keepAlive = true
                sock.connect(InetSocketAddress(dog.ip, dog.port), TCP_CONNECT_TIMEOUT_MS)
                val writer = BufferedWriter(
                    OutputStreamWriter(sock.getOutputStream(), StandardCharsets.UTF_8)
                )
                tcpSocket = sock
                tcpWriter = writer
                isConnected = true
                isAuthed = false
                connectedLabel = "${dog.name} ${dog.ip}:${dog.port}"
                updateStatusUi()

                sendTcpLine("""{"type":"hello","token":"${dog.token}"}""")
                log("已连接，等待鉴权...")

                // 读线程：按行解析狗端回复
                thread(name = "tcp-read", isDaemon = true) {
                    try {
                        val reader = BufferedReader(
                            InputStreamReader(sock.getInputStream(), StandardCharsets.UTF_8)
                        )
                        while (true) {
                            val line = reader.readLine() ?: break
                            handleTcpLine(line.trimEnd('\r', ' '))
                        }
                        onTcpClosed("对端关闭")
                    } catch (e: Exception) {
                        if (isConnected) {
                            onTcpClosed("TCP 错误: ${e.message}")
                        }
                    }
                }
            } catch (e: Exception) {
                log("连接失败: ${e.message}")
                closeTcpQuietly()
                isConnected = false
                isAuthed = false
                connectedLabel = ""
                updateStatusUi()
            }
        }
    }

    private fun handleTcpLine(line: String) {
        if (line.isEmpty()) return
        try {
            val obj = JSONObject(line)
            when (obj.optString("type")) {
                "hello_ack" -> {
                    if (obj.optBoolean("ok", false)) {
                        isAuthed = true
                        log("鉴权成功，可以控狗")
                        startVelLoop()
                    } else {
                        isAuthed = false
                        log("鉴权失败：token 不匹配")
                    }
                    updateStatusUi()
                }
                "pong" -> Unit
                "err" -> log("狗端错误: ${obj.optString("msg")}")
            }
        } catch (_: Exception) {
            // ignore malformed
        }
    }

    private fun sendTcpLine(line: String) {
        val writer = tcpWriter ?: return
        synchronized(writer) {
            writer.write(line)
            writer.write("\n")
            writer.flush()
        }
    }

    private fun onTcpClosed(reason: String) {
        stopVelLoop()
        closeTcpQuietly()
        isConnected = false
        isAuthed = false
        connectedLabel = ""
        holdFwd = 0.0
        holdSide = 0.0
        holdYaw = 0.0
        log("已断开: $reason")
        updateStatusUi()
    }

    private fun disconnectTcp() {
        stopVelLoop()
        closeTcpQuietly()
        isConnected = false
        isAuthed = false
        connectedLabel = ""
        holdFwd = 0.0
        holdSide = 0.0
        holdYaw = 0.0
        log("已断开连接")
        updateStatusUi()
    }

    private fun closeTcpQuietly() {
        try {
            tcpWriter?.close()
        } catch (_: Exception) {
        }
        try {
            tcpSocket?.close()
        } catch (_: Exception) {
        }
        tcpWriter = null
        tcpSocket = null
    }

    // -------------------------------------------------------------------------
    // 速度环 / 模式
    // -------------------------------------------------------------------------

    private fun startVelLoop() {
        if (!velRunning.compareAndSet(false, true)) return
        ioExecutor.execute {
            while (velRunning.get()) {
                try {
                    if (isAuthed && tcpSocket != null) {
                        if (holdFwd != 0.0 || holdSide != 0.0 || holdYaw != 0.0) {
                            val payload =
                                """{"type":"vel","fwd":$holdFwd,"side":$holdSide,"yaw":$holdYaw}"""
                            sendTcpLine(payload)
                        }
                    }
                    Thread.sleep(VEL_SEND_MS)
                } catch (e: Exception) {
                    if (velRunning.get()) {
                        log("发送速度失败: ${e.message}")
                    }
                    break
                }
            }
            velRunning.set(false)
        }
    }

    private fun stopVelLoop() {
        velRunning.set(false)
    }

    private fun setHold(fwd: Double, side: Double, yaw: Double) {
        holdFwd = fwd
        holdSide = side
        holdYaw = yaw
    }

    private fun sendModeKey(key: String) {
        if (!isAuthed) {
            log("尚未鉴权")
            return
        }
        ioExecutor.execute {
            try {
                sendTcpLine("""{"type":"mode","key":"$key"}""")
                log("模式: $key")
            } catch (e: Exception) {
                log("发送模式失败: ${e.message}")
            }
        }
    }

    private fun cleanupAll() {
        discoverWindowRunnable?.let { mainHandler.removeCallbacks(it) }
        discoverWindowRunnable = null
        stopVelLoop()
        disconnectTcp()
        stopUdpListen.set(true)
        try {
            udpSocket?.close()
        } catch (_: Exception) {
        }
        udpSocket = null
        udpListenThread = null
    }

    // -------------------------------------------------------------------------
    // 按键绑定（按住发速度；松手清零）
    // -------------------------------------------------------------------------

    private fun bindHold(viewId: Int, fwd: Double, side: Double, yaw: Double) {
        findViewById<View>(viewId).setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> setHold(fwd, side, yaw)
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> setHold(0.0, 0.0, 0.0)
            }
            true
        }
    }

    private fun setupMotionButtons() {
        bindHold(R.id.btnFwd, MAX_FWD, 0.0, 0.0)
        bindHold(R.id.btnBack, -MAX_FWD, 0.0, 0.0)
        bindHold(R.id.btnLeft, 0.0, MAX_SIDE, 0.0)
        bindHold(R.id.btnRight, 0.0, -MAX_SIDE, 0.0)
        bindHold(R.id.btnYawL, 0.0, 0.0, MAX_YAW)
        bindHold(R.id.btnYawR, 0.0, 0.0, -MAX_YAW)

        findViewById<Button>(R.id.btnStop).setOnClickListener {
            setHold(0.0, 0.0, 0.0)
            if (isAuthed) {
                ioExecutor.execute {
                    try {
                        sendTcpLine("""{"type":"vel","fwd":0,"side":0,"yaw":0}""")
                    } catch (_: Exception) {
                    }
                }
            }
        }
    }

    private fun setupModeButtons() {
        mapOf(
            R.id.btnModeR to "r",
            R.id.btnModeX to "x",
            R.id.btnModeZ to "z",
            R.id.btnModeV to "v",
            R.id.btnModeB to "b",
            R.id.btnModeJ to "j",
            R.id.btnModeK to "k"
        ).forEach { (id, key) ->
            findViewById<Button>(id).setOnClickListener { sendModeKey(key) }
        }
    }
}
