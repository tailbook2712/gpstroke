package com.example.walk_tracker_app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Android の実行時権限（ランタイムパーミッション）を Dart 側から要求するためのチャネルを提供する。
 *
 * - activityRecognition: 歩数センサー（TYPE_STEP_COUNTER）の利用に必要（Android 10 以降）
 * - notification: 記録中のロック画面通知の表示に必要（Android 13 以降）
 *
 * それぞれ対象 OS バージョン未満では権限が存在しないため、常に許可済みとして返す。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "gpstroke/permissions"
    private val permissionRequestCode = 7301

    private var pendingResult: MethodChannel.Result? = null
    private var pendingStatus: MutableMap<String, Boolean> = mutableMapOf()
    private var pendingNames: List<String> = emptyList()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "request" -> {
                        val names = call.argument<List<String>>("permissions") ?: emptyList()
                        requestRuntimePermissions(names, result)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /** Dart 側の名前を Android の権限名に変換する。OS がその権限を持たない場合は null */
    private fun toAndroidPermission(name: String): String? = when (name) {
        "activityRecognition" ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) Manifest.permission.ACTIVITY_RECOGNITION else null
        "notification" ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) Manifest.permission.POST_NOTIFICATIONS else null
        else -> null
    }

    private fun requestRuntimePermissions(names: List<String>, result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("busy", "権限リクエストが既に進行中です", null)
            return
        }

        val status = mutableMapOf<String, Boolean>()
        val toRequest = mutableListOf<String>()
        for (name in names) {
            val permission = toAndroidPermission(name)
            if (permission == null ||
                checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
            ) {
                status[name] = true
            } else {
                toRequest += name
            }
        }

        if (toRequest.isEmpty()) {
            result.success(status)
            return
        }

        pendingResult = result
        pendingStatus = status
        pendingNames = toRequest
        requestPermissions(
            toRequest.map { toAndroidPermission(it)!! }.toTypedArray(),
            permissionRequestCode
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != permissionRequestCode) return
        val result = pendingResult ?: return

        // ダイアログがキャンセルされた場合 grantResults は空になる → 拒否扱い
        pendingNames.forEachIndexed { i, name ->
            pendingStatus[name] = grantResults.getOrNull(i) == PackageManager.PERMISSION_GRANTED
        }
        val status = pendingStatus
        pendingResult = null
        pendingStatus = mutableMapOf()
        pendingNames = emptyList()
        result.success(status)
    }
}
