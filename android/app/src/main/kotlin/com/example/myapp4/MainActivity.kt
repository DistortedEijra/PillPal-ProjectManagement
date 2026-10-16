package com.example.myapp4

import android.app.NotificationManager
import android.content.Context
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.provider.Settings
import android.net.Uri
import android.content.Intent

class MainActivity: FlutterActivity() {
  private val CHANNEL = "com.example.myapp4/notifications"

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
      if (call.method == "canUseFullScreenIntent") {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        result.success(if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) nm.canUseFullScreenIntent() else true)
      } else if (call.method == "requestFullScreenIntent") {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
          val intent = Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT).apply {
            data = Uri.fromParts("package", packageName, null)
          }
          startActivity(intent)
          result.success(true)
        } else {
          result.success(false)
        }
      } else {
        result.notImplemented()
      }
    }
  }
}
