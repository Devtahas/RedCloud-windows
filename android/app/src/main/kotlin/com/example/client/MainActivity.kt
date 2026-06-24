package com.example.client

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.redcloud/vpn" // کانال هماهنگ با فلاتر برای تبادل متدها
    private var pendingConfig: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "startVpn") {
                val config = call.argument<String>("config")
                pendingConfig = config
                
                // بررسی بومی اینکه آیا مجوز دسترسی قبلاً داده شده است یا خیر
                val intent = VpnService.prepare(this)
                if (intent != null) {
                    // نمایش پنجره استاندارد اخذ مجوز VPN سیستم‌عامل به کاربر
                    startActivityForResult(intent, 1)
                } else {
                    // در صورت تایید بودن از قبل، سرویس مستقیم استارت می‌خورد
                    startVpnService()
                }
                result.success("در حال آماده‌سازی و استعلام دسترسی...")
            } else if (call.method == "stopVpn") {
                stopVpnService()
                result.success("درخواست دیسکانکت به بستر بومی ارسال شد.")
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 1 && resultCode == Activity.RESULT_OK) {
            // به محض اینکه کاربر دکمه OK را در کادر مجوز بزند، سرویس فعال می‌شود
            startVpnService()
        }
    }

    private fun startVpnService() {
        val intent = Intent(this, MyVpnService::class.java).apply {
            action = "START"
            putExtra("CONFIG", pendingConfig)
        }
        startService(intent)
    }

    private fun stopVpnService() {
        val intent = Intent(this, MyVpnService::class.java).apply {
            action = "STOP"
        }
        startService(intent)
    }
}