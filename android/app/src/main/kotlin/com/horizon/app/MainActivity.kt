package com.horizon.app

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class ReceiptFileProvider : FileProvider()

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sydex/receipt")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "whatsAppApps" -> result.success(WHATSAPP_APPS.filter(::isInstalled))
                    "sendToWhatsApp" -> sendToWhatsApp(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun isInstalled(name: String): Boolean = try {
        packageManager.getPackageInfo(name, 0)
        true
    } catch (_: Exception) {
        false
    }

    /** Opens one customer's chat with the receipt attached, ready to send. */
    private fun sendToWhatsApp(call: MethodCall, result: MethodChannel.Result) {
        val app = call.argument<String>("app")
        val phone = call.argument<String>("phone")
        val image = call.argument<ByteArray>("image")
        val name = call.argument<String>("name")
        if (app !in WHATSAPP_APPS || image == null || name == null ||
            phone == null || !phone.matches(Regex("[0-9]{7,15}"))
        ) {
            result.success(false)
            return
        }
        try {
            val folder = File(cacheDir, "receipts").apply { mkdirs() }
            // Receipts hold customer balances, so earlier ones are not kept.
            folder.listFiles()?.forEach { it.delete() }
            val file = File(folder, File(name).name)
            file.writeBytes(image)
            val uri = FileProvider.getUriForFile(this, "$packageName.receipts", file)
            startActivity(
                Intent(Intent.ACTION_SEND).apply {
                    type = "image/png"
                    setPackage(app)
                    putExtra(Intent.EXTRA_STREAM, uri)
                    // Not documented by WhatsApp: goes straight to this chat.
                    // If it is ever ignored, WhatsApp shows its contact list.
                    putExtra("jid", "$phone@s.whatsapp.net")
                    clipData = ClipData.newRawUri("", uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                },
            )
            result.success(true)
        } catch (_: ActivityNotFoundException) {
            result.success(false)
        } catch (error: Exception) {
            result.error("receipt", error.message, null)
        }
    }

    private companion object {
        val WHATSAPP_APPS = listOf("com.whatsapp", "com.whatsapp.w4b")
    }
}
