package com.example.client

import android.content.Intent
import android.net.VpnService
import android.os.ParcelFileDescriptor

class MyVpnService : VpnService() {
    private var vpnInterface: ParcelFileDescriptor? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == "START") {
            val config = intent.getStringExtra("CONFIG")
            startVpn(config)
        } else if (action == "STOP") {
            stopVpn()
        }
        return START_NOT_STICKY
    }

    private fun startVpn(config: String?) {
        // اگر تونل از قبل باز است، آن را ببند
        stopVpn()

        try {
            // ۱. پیکربندی مشخصات شبکه مجازی VPN
            val builder = Builder()
            builder.setSession("RedCloud VPN")
                   .addAddress("172.19.0.1", 30) // آی‌پی لوکال تونل بومی
                   .addRoute("0.0.0.0", 0)       // هدایت کل ترافیک گوشی (IPV4) به داخل تونل اپلیکیشن
                   .addDnsServer("1.1.1.1")       // دی‌ان‌اس ابری کلودفلر
                   .setMtu(1500)

            // ۲. ایجاد کارت شبکه مجازی (TUN Interface) و دریافت File Descriptor بومی سیستم‌عامل
            vpnInterface = builder.establish()

            if (vpnInterface != null) {
                val fd = vpnInterface!!.fd // شماره هندلر شبکه
                // در آینده: این فیلد fd را به کتابخانه بومی سنگ‌باکس (sing-box.aar) می‌دهیم تا شروع به پردازش ترافیک کند
            }
        } catch (e: Exception) {
            stopVpn()
        }
    }

    private fun stopVpn() {
        try {
            vpnInterface?.close()
        } catch (e: Exception) {
            // ignore
        }
        vpnInterface = null
        stopSelf()
    }

    override fun onDestroy() {
        stopVpn()
        super.onDestroy()
    }
}