package com.pointeuse.pointeuse

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.provider.Settings
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.IntegrityTokenRequest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Canal « pointeuse/security » utilisé par lib/services/device_security.dart :
 *  - isVpnActive     : un réseau VPN est-il actif sur le téléphone ?
 *  - isDeveloperMode : options pour les développeurs activées ?
 *  - integrityToken  : jeton Google Play Integrity lié au défi du serveur
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pointeuse/security").setMethodCallHandler { call, result ->
            when (call.method) {
                "isVpnActive" -> result.success(isVpnActive())
                "isDeveloperMode" -> result.success(isDeveloperMode())
                "integrityToken" -> {
                    val nonce = call.argument<String>("nonce")
                    val project = (call.argument<Any>("cloudProjectNumber") as? Number)?.toLong() ?: 0L
                    if (nonce == null) { result.success(null); return@setMethodCallHandler }
                    val builder = IntegrityTokenRequest.builder().setNonce(nonce)
                    if (project > 0) builder.setCloudProjectNumber(project)
                    IntegrityManagerFactory.create(applicationContext)
                        .requestIntegrityToken(builder.build())
                        .addOnSuccessListener { result.success(it.token()) }
                        .addOnFailureListener { result.success(null) } // le serveur traitera l'absence de jeton
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isVpnActive(): Boolean {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        @Suppress("DEPRECATION")
        return cm.allNetworks.any { net ->
            cm.getNetworkCapabilities(net)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true
        }
    }

    private fun isDeveloperMode(): Boolean =
        Settings.Global.getInt(contentResolver, Settings.Global.DEVELOPMENT_SETTINGS_ENABLED, 0) != 0
}
