package com.wweiyi.expert_chat

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.core.content.FileProvider
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val installChannel = "expert_chat/install"
    private var generationChannel: MethodChannel? = null
    private val sharedIntake by lazy { SharedIntake(applicationContext) }
    private val uploadDirectory by lazy { UploadDirectory(this) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A recreated activity must not re-import the share it started with.
        if (savedInstanceState == null) sharedIntake.handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (sharedIntake.handle(intent)) setIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        uploadDirectory.attach(
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "expert_chat/upload_directory"),
        )
        sharedIntake.attach(
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "expert_chat/share"),
        )
        generationChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, "expert_chat/generation",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "start" -> {
                            ContextCompat.startForegroundService(
                                this, Intent(this, GenerationService::class.java),
                            )
                            result.success(null)
                        }
                        "stop" -> {
                            stopService(Intent(this, GenerationService::class.java))
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("generation_service_unavailable", error.message, null)
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, installChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("bad_args", "path is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            installApk(path)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("install_failed", e.message, null)
                        }
                    }
                    "canRequestPackageInstalls" -> {
                        result.success(canRequestPackageInstalls())
                    }
                    "openUnknownAppSources" -> {
                        try {
                            openUnknownAppSourcesSettings()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("settings_failed", e.message, null)
                        }
                    }
                    "primaryAbi" -> {
                        result.success(primaryAbi())
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        uploadDirectory.detach()
        generationChannel?.setMethodCallHandler(null)
        generationChannel = null
        sharedIntake.detach()
        stopService(Intent(this, GenerationService::class.java))
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (!uploadDirectory.onActivityResult(requestCode, resultCode, data)) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    private fun primaryAbi(): String {
        val abis = Build.SUPPORTED_ABIS
        return if (abis != null && abis.isNotEmpty()) abis[0] else "unknown"
    }

    private fun canRequestPackageInstalls(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }
    }

    private fun openUnknownAppSourcesSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val intent = Intent(
                android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            )
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
        }
    }

    private fun installApk(path: String) {
        val file = File(path)
        if (!file.exists()) {
            throw IllegalArgumentException("APK not found: $path")
        }
        val uri = FileProvider.getUriForFile(
            this,
            "$packageName.fileprovider",
            file,
        )
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(intent)
    }
}
