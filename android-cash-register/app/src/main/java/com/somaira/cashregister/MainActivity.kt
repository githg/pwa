package com.somaira.cashregister

import android.annotation.SuppressLint
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Bundle
import android.view.WindowManager
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.appcompat.app.AppCompatActivity
import java.io.ByteArrayOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class MainActivity : AppCompatActivity() {

    private lateinit var webView: WebView
    private val ioPool = Executors.newSingleThreadExecutor()

    companion object {
        private const val PWA_URL = "https://githg.github.io/pwa/?mode=cashier"
        // Standard ESC/POS Drawer Kick (Pin 2, 50ms ON / 500ms OFF) — pops drawer with ZERO paper feed
        private val ESC_DRAWER_KICK = byteArrayOf(0x1B, 0x70, 0x00, 0x19, 0xFA.toByte())
        private val ESC_INIT = byteArrayOf(0x1B, 0x40)
        private val ESC_ALIGN_CENTER = byteArrayOf(0x1B, 0x61, 0x01)
        private val ESC_ALIGN_LEFT = byteArrayOf(0x1B, 0x61, 0x00)
        private val ESC_BOLD_ON = byteArrayOf(0x1B, 0x45, 0x01)
        private val ESC_BOLD_OFF = byteArrayOf(0x1B, 0x45, 0x00)
        private val ESC_PARTIAL_CUT = byteArrayOf(0x1D, 0x56, 0x41, 0x03)
    }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Keep Cash Counter tablet awake all shift (just like Loyverse)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        webView = WebView(this)
        setContentView(webView)

        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            databaseEnabled = true
            mediaPlaybackRequiresUserGesture = false
            cacheMode = WebSettings.LOAD_DEFAULT
            mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
        }

        webView.webViewClient = WebViewClient()
        webView.webChromeClient = WebChromeClient()
        webView.addJavascriptInterface(CashBridge(), "AndroidCashBridge")
        webView.loadUrl(PWA_URL)
    }

    override fun onBackPressed() {
        if (this::webView.isInitialized && webView.canGoBack()) {
            webView.goBack()
        } else {
            super.onBackPressed()
        }
    }

    override fun onDestroy() {
        ioPool.shutdownNow()
        super.onDestroy()
    }

    private fun sendRawTcp(ip: String, port: Int, bytes: ByteArray): String {
        val future = ioPool.submit(Callable {
            Socket().use { socket ->
                socket.connect(InetSocketAddress(ip.trim(), port), 2000)
                socket.soTimeout = 2000
                socket.getOutputStream().apply {
                    write(bytes)
                    flush()
                }
            }
            "OK"
        })
        return try {
            future.get(3500, TimeUnit.MILLISECONDS)
        } catch (e: Exception) {
            e.cause?.message ?: e.message ?: "Printer unreachable"
        }
    }

    inner class CashBridge {

        @JavascriptInterface
        fun openDrawer(ip: String, port: Int): String {
            if (ip.isBlank()) return "Missing printer IP"
            return sendRawTcp(ip, if (port > 0) port else 9100, ESC_DRAWER_KICK)
        }

        @JavascriptInterface
        fun printCashToken(
            ip: String,
            port: Int,
            ref: String,
            counter: String,
            amount: String,
            tendered: String,
            change: String,
            time: String
        ): String {
            if (ip.isBlank()) return "Missing printer IP"
            val out = ByteArrayOutputStream()
            out.write(ESC_INIT)
            out.write(ESC_DRAWER_KICK)
            out.write(ESC_ALIGN_CENTER)
            out.write(ESC_BOLD_ON)
            out.write("CASH RECEIVED\n".toByteArray(Charsets.UTF_8))
            out.write(ESC_BOLD_OFF)
            out.write("------------------------\n".toByteArray(Charsets.UTF_8))
            out.write(ESC_ALIGN_LEFT)
            out.write("Ref:     $ref\n".toByteArray(Charsets.UTF_8))
            out.write("Counter: $counter\n".toByteArray(Charsets.UTF_8))
            out.write("Time:    $time\n".toByteArray(Charsets.UTF_8))
            out.write("------------------------\n".toByteArray(Charsets.UTF_8))
            out.write(ESC_BOLD_ON)
            out.write("Bill:    Rs $amount\n".toByteArray(Charsets.UTF_8))
            out.write("Recv:    Rs $tendered\n".toByteArray(Charsets.UTF_8))
            out.write("Change:  Rs $change\n".toByteArray(Charsets.UTF_8))
            out.write(ESC_BOLD_OFF)
            out.write("\n\n\n".toByteArray(Charsets.UTF_8))
            out.write(ESC_PARTIAL_CUT)
            return sendRawTcp(ip, if (port > 0) port else 9100, out.toByteArray())
        }

        @JavascriptInterface
        fun playChime() {
            try {
                val tone = ToneGenerator(AudioManager.STREAM_NOTIFICATION, 90)
                tone.startTone(ToneGenerator.TONE_PROP_BEEP2, 180)
            } catch (_: Exception) {
            }
        }
    }
}
