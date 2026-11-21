package com.perol.pixez

import android.app.Activity
import android.app.Dialog
import android.content.Intent
import android.net.Uri
import android.net.http.SslError
import android.webkit.SslErrorHandler
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

object EoNativeBridge {
    fun register(activity: Activity, flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "pixez/ios_share"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openEoReader" -> {
                    val port = call.argument<Int>("port") ?: 0
                    val intent = Intent(
                        Intent.ACTION_VIEW,
                        Uri.parse("eoreader://pull?port=$port")
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    activity.startActivity(intent)
                    result.success(true)
                }

                "openCealerLogin" -> {
                    val port = call.argument<Int>("port") ?: 0
                    val url = call.argument<String>("url") ?: ""
                    val proxyConfig = ProxyConfig.Builder()
                        .addProxyRule("127.0.0.1:$port")
                        .build()

                    ProxyController.getInstance().setProxyOverride(
                        proxyConfig,
                        { r -> activity.runOnUiThread(r) }
                    ) {
                        var replied = false
                        fun finish(callbackUrl: String?) {
                            if (replied) return
                            replied = true
                            ProxyController.getInstance().clearProxyOverride({ r -> activity.runOnUiThread(r) }) {}
                            result.success(callbackUrl)
                        }

                        val dialog = Dialog(activity, android.R.style.Theme_Black_NoTitleBar_Fullscreen)
                        val webView = WebView(activity).apply {
                            settings.javaScriptEnabled = true
                            settings.domStorageEnabled = true
                            webViewClient = object : WebViewClient() {
                                override fun onReceivedSslError(
                                    view: WebView?,
                                    handler: SslErrorHandler?,
                                    error: SslError?
                                ) {
                                    handler?.proceed()
                                }

                                override fun shouldOverrideUrlLoading(
                                    view: WebView?,
                                    request: WebResourceRequest?
                                ): Boolean {
                                    val target = request?.url?.toString() ?: return false
                                    if (target.startsWith("pixiv://")) {
                                        dialog.dismiss()
                                        finish(target)
                                        return true
                                    }
                                    return false
                                }
                            }
                            loadUrl(url)
                        }
                        dialog.setContentView(webView)
                        dialog.setOnCancelListener { finish(null) }
                        dialog.show()
                    }
                }

                else -> result.notImplemented()
            }
        }
    }
}
