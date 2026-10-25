package com.wweiyi.expert_chat

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Bitmap
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Display
import android.view.WindowManager
import android.util.DisplayMetrics
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/** Only active after Android's user-owned accessibility consent. No network API. */
class DeviceAgentService : AccessibilityService() {
    companion object { var current: DeviceAgentService? = null; private set }
    private var epoch = 0L
    private var armed = false
    private var revision = 0L
    private var owner: String? = null
    private var acting = false
    private var observedWindow: Int? = null
    private var observedPackage: String? = null
    private val observedTargets = HashMap<String, String>()
    private var lastScreenshotInfo: Map<String, Any?>? = null
    private var lastStopReason: String? = null
    fun status() = mapOf("enabled" to true, "armed" to armed, "owner" to owner,
        "notificationPresent" to ((getSystemService(NOTIFICATION_SERVICE) as NotificationManager).activeNotifications.any { it.id == 7523 }), "lastStopReason" to lastStopReason)
    private val handler = Handler(Looper.getMainLooper())
    override fun onServiceConnected() { current = this; armed = false }
    override fun onAccessibilityEvent(event: AccessibilityEvent?) { revision++ }
    override fun onInterrupt() { stopActions("system_interrupt") }
    override fun onDestroy() { stopActions("service_destroyed"); current = null; super.onDestroy() }
    fun stopActions(reason: String = "user") { lastStopReason = reason; armed = false; epoch++; owner = null; lastScreenshotInfo = null; (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).cancel(7523) }
    private fun showStopControl() {
        check(NotificationManagerCompat.from(this).areNotificationsEnabled()) { "Allow notifications first so Stop remains available outside Expert Chat" }
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel("device_agent", "设备控制停止入口", NotificationManager.IMPORTANCE_LOW))
            check(manager.getNotificationChannel("device_agent").importance != NotificationManager.IMPORTANCE_NONE) { "Enable device control notification channel" }
        }
        val stop = PendingIntent.getBroadcast(this, 7523, Intent(this, DeviceAgentStopReceiver::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        manager.notify(7523, NotificationCompat.Builder(this, "device_agent")
            .setSmallIcon(R.drawable.ic_stat_notify).setContentTitle("Expert Chat 设备控制已开启")
            .setContentText("点击立即停止所有新动作").setContentIntent(stop).setOngoing(true)
            .addAction(0, "立即停止", stop).build())
    }

    private fun observe(): Map<String, Any?> {
        val nodes = ArrayList<Map<String, Any?>>()
        val root = rootInActiveWindow
        observedWindow = root?.windowId
        observedPackage = root?.packageName?.toString()
        observedTargets.clear()
        fun walk(node: AccessibilityNodeInfo?, depth: Int, path: String) {
            if (node == null || !node.isVisibleToUser || nodes.size >= 500 || depth > 30) return
            val bounds = Rect(); node.getBoundsInScreen(bounds)
            observedTargets[path] = fingerprint(node)
            nodes.add(mapOf("target" to path, "text" to if (node.isPassword) "[password]" else node.text?.toString(),
                "description" to if (node.isPassword) "[password]" else node.contentDescription?.toString(), "viewId" to node.viewIdResourceName, "className" to node.className?.toString(),
                "clickable" to node.isClickable, "editable" to node.isEditable, "scrollable" to node.isScrollable,
                "bounds" to listOf(bounds.left, bounds.top, bounds.right, bounds.bottom)))
            for (i in 0 until node.childCount) {
                if (nodes.size >= 500) break
                walk(node.getChild(i), depth + 1, "$path/$i")
            }
        }
        walk(root, 0, "0")
        val display = (getSystemService(WINDOW_SERVICE) as WindowManager).defaultDisplay
        val metrics = DisplayMetrics(); display.getRealMetrics(metrics)
        return mapOf("revision" to revision, "windowId" to root?.windowId, "package" to root?.packageName?.toString(), "nodes" to nodes,
            "screen" to mapOf("width" to metrics.widthPixels, "height" to metrics.heightPixels, "displayId" to display.displayId, "rotation" to display.rotation), "lastScreenshot" to lastScreenshotInfo,
            "armed" to armed, "screenshotAvailable" to (Build.VERSION.SDK_INT >= 30))
    }
    private fun fingerprint(node: AccessibilityNodeInfo): String {
        val bounds = Rect(); node.getBoundsInScreen(bounds)
        return "${node.viewIdResourceName}|${node.className}|$bounds|${node.isEditable}|${node.isClickable}|${node.isPassword}|${if (node.isPassword) "[password]" else node.text}|${if (node.isPassword) "[password]" else node.contentDescription}"
    }
    private fun checkedRoot(): AccessibilityNodeInfo {
        val root = rootInActiveWindow ?: error("Active window changed; observe again (no active root)")
        check(root.windowId == observedWindow && root.packageName?.toString() == observedPackage) { "Active window changed; observe again (observed=$observedWindow/$observedPackage, current=${root.windowId}/${root.packageName})" }
        return root
    }
    private fun target(path: String, root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        if (!path.matches(Regex("0(/[0-9]+)*"))) return null
        var node: AccessibilityNodeInfo? = root
        for (part in path.split('/').drop(1)) node = node?.getChild(part.toInt())
        return node
    }
    fun handle(method: String, args: Map<*, *>?, result: MethodChannel.Result) {
        try {
            when (method) {
                "observe" -> {
                    val session = args?.get("sessionId") as? String ?: "ui"
                    check(session == "ui" || armed) { "Device control is stopped" }
                    check(owner == null || owner == session) { "Device is leased by another session; stop and arm again to transfer" }
                    if (armed) owner = session
                    result.success(observe())
                }
                "releaseOwner" -> {
                    val session = args?.get("sessionId") as? String
                    val released = session != null && owner == session
                    if (released) {
                        if (acting) stopActions("owner_cancelled_while_action_in_flight")
                        else { owner = null; epoch++; lastScreenshotInfo = null }
                    }
                    result.success(mapOf("released" to released))
                }
                "arm" -> { check(!acting) { "Wait for current action to settle" }; showStopControl(); armed = true; epoch++; owner = null; lastScreenshotInfo = null; result.success(observe()) }
                "screenshotInfo" -> {
                    val session = args?.get("sessionId") as? String ?: "ui"
                    check(armed && owner == session) { "Screenshot belongs to another or stopped session" }
                    result.success(lastScreenshotInfo ?: error("No screenshot in this session"))
                }
                "stop" -> { stopActions(); result.success(observe()) }
                "revoke" -> { stopActions(); disableSelf(); result.success(null) }
                "screenshot" -> {
                    check(armed) { "Arm device control first" }
                    val session = args?.get("sessionId") as? String ?: "ui"
                    check(owner == null || owner == session) { "Device is leased by another session" }
                    check(!acting) { "Another device action is in flight" }
                    checkedRoot()
                    if (session != "ui") check((args?.get("revision") as? Number)?.toLong() == revision) { "Observation is stale; observe again" }
                    owner = session
                    if (Build.VERSION.SDK_INT < 30) { result.error("unsupported", "Accessibility screenshots require Android 11+", null); return }
                    val dispatchedEpoch = epoch
                    val dispatchedRevision = revision
                    val dispatchedWindow = observedWindow
                    lastScreenshotInfo = null
                    acting = true
                    takeScreenshot(Display.DEFAULT_DISPLAY, mainExecutor, object : TakeScreenshotCallback {
                        override fun onSuccess(screenshot: ScreenshotResult) {
                            acting = false
                            val buffer = screenshot.hardwareBuffer
                            try {
                                if (!armed || epoch != dispatchedEpoch || revision != dispatchedRevision || rootInActiveWindow?.windowId != dispatchedWindow) { result.error("stopped_or_changed", "Screenshot discarded after stop or window change; observe again", null); return }
                                val bitmap = Bitmap.wrapHardwareBuffer(buffer, screenshot.colorSpace)
                                if (bitmap == null) { result.error("screenshot_failed", "Android returned no bitmap", null); return }
                                val scale = minOf(1.0, 2048.0 / maxOf(bitmap.width, bitmap.height))
                                val bounded = if (scale < 1.0) Bitmap.createScaledBitmap(bitmap, maxOf(1, (bitmap.width * scale).toInt()), maxOf(1, (bitmap.height * scale).toInt()), true) else bitmap
                                val display = (getSystemService(WINDOW_SERVICE) as WindowManager).defaultDisplay
                                val metadata = mapOf("sourceWidth" to bitmap.width, "sourceHeight" to bitmap.height,
                                    "imageWidth" to bounded.width, "imageHeight" to bounded.height,
                                    "physicalPerImageX" to bitmap.width.toDouble() / bounded.width,
                                    "physicalPerImageY" to bitmap.height.toDouble() / bounded.height,
                                    "displayId" to display.displayId, "rotation" to display.rotation,
                                    "revision" to dispatchedRevision, "windowId" to dispatchedWindow)
                                val output = ByteArrayOutputStream()
                                val compressed = bounded.compress(Bitmap.CompressFormat.PNG, 100, output)
                                if (bounded !== bitmap) bounded.recycle()
                                bitmap.recycle()
                                if (!compressed || output.size() < 8) result.error("screenshot_failed", "Android could not encode a PNG", null)
                                else if (output.size() > 8 * 1024 * 1024) result.error("screenshot_too_large", "Screenshot exceeds 8 MiB transfer bound", null)
                                else { lastScreenshotInfo = metadata; result.success(output.toByteArray()) }
                            } catch (error: OutOfMemoryError) {
                                result.error("screenshot_memory_limit", "Screenshot exceeded available memory", null)
                            } catch (error: Exception) {
                                result.error("screenshot_failed", "Android screenshot encoding failed: ${error.javaClass.simpleName}", null)
                            } finally { buffer.close() }
                        }
                        override fun onFailure(errorCode: Int) { acting = false; result.error("screenshot_failed", "Android screenshot error $errorCode (protected windows may block capture)", null) }
                    })
                }
                else -> {
                    check(armed) { "Device control is stopped; arm explicitly" }
                    val session = args?.get("sessionId") as? String ?: "ui"
                    check(owner == null || owner == session) { "Device is leased by another session" }
                    check(!acting) { "Another device action is in flight" }
                    owner = session
                    check((args?.get("revision") as? Number)?.toLong() == revision) { "Observation is stale; observe again" }
                    val actionRoot = checkedRoot()
                    check(args?.get("package") == null || method == "openApp" || args["package"] == rootInActiveWindow?.packageName?.toString()) { "Active app changed; observe again" }
                    val dispatchedEpoch = epoch
                    val action = when (method) {
                        "tap" -> AccessibilityNodeInfo.ACTION_CLICK
                        "text" -> AccessibilityNodeInfo.ACTION_SET_TEXT
                        "scroll" -> if (args?.get("backward") == true) AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD else AccessibilityNodeInfo.ACTION_SCROLL_FORWARD
                        else -> 0
                    }
                    var ok = false
                    if (action != 0) {
                        val node = target(args?.get("target") as? String ?: "", actionRoot) ?: error("Target no longer exists")
                        check(observedTargets[args?.get("target")] == fingerprint(node)) { "Target changed; observe again" }
                        check(node.isVisibleToUser && node.isEnabled) { "Target is not visible or enabled" }
                        check(!node.isPassword) { "Password fields are excluded" }
                        val bundle = Bundle()
                        if (method == "text") {
                            val text = args?.get("text") as? String ?: ""
                            check(text.length <= 10000) { "Text exceeds 10000 characters; no partial input was dispatched" }
                            bundle.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
                        }
                        ok = node.performAction(action, bundle)
                    } else if (method == "back") ok = performGlobalAction(GLOBAL_ACTION_BACK)
                    else if (method == "home") ok = performGlobalAction(GLOBAL_ACTION_HOME)
                    else if (method == "openApp") {
                        val pkg = args?.get("package") as? String ?: error("Package required")
                        val intent = packageManager.getLaunchIntentForPackage(pkg) ?: error("App is unavailable")
                        intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK); startActivity(intent); ok = true
                    } else if (method == "tapPoint") {
                        val x = (args?.get("x") as? Number)?.toFloat() ?: error("x required")
                        val y = (args?.get("y") as? Number)?.toFloat() ?: error("y required")
                        val metrics = DisplayMetrics()
                        (getSystemService(WINDOW_SERVICE) as WindowManager).defaultDisplay.getRealMetrics(metrics)
                        check(x >= 0 && y >= 0 && x < metrics.widthPixels && y < metrics.heightPixels) { "Point outside screen" }
                        val path = Path(); path.moveTo(x, y)
                        val gesture = GestureDescription.Builder().addStroke(GestureDescription.StrokeDescription(path, 0, 80)).build()
                        acting = true
                        val accepted = dispatchGesture(gesture, object : GestureResultCallback() {
                            override fun onCompleted(gestureDescription: GestureDescription?) { finishAction(result, true, dispatchedEpoch) }
                            override fun onCancelled(gestureDescription: GestureDescription?) { acting = false; result.error("gesture_cancelled", "Gesture cancelled", null) }
                        }, null)
                        if (!accepted) { acting = false; result.error("gesture_rejected", "Android rejected gesture", null) }
                        return
                    } else { result.notImplemented(); return }
                    finishAction(result, ok, dispatchedEpoch)
                }
            }
        } catch (error: Exception) { result.error("device_action_failed", error.message, null) }
    }
    private fun finishAction(result: MethodChannel.Result, accepted: Boolean, dispatchedEpoch: Long) {
        acting = true
        // Result carries a fresh state, not an invented claim that the UI goal succeeded.
        handler.postDelayed({
            acting = false
            if (dispatchedEpoch != epoch || !armed) result.error("stopped", "Stopped after dispatch; observe to verify outcome", null)
            else result.success(mapOf("accepted" to accepted, "observation" to observe()))
        }, 300)
    }
}

class DeviceAgentStopReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) { DeviceAgentService.current?.stopActions("notification") }
}
