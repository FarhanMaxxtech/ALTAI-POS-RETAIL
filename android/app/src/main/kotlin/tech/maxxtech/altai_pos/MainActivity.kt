package tech.maxxtech.altai_pos

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor() // USB talk never runs on the UI thread
    private val main = Handler(Looper.getMainLooper())
    private var reader: SilionReader? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val r = SilionReader(applicationContext).also { reader = it }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "altai/rfid").setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(r.status())
                "requestPermission" -> r.requestPermission { ok -> main.post { result.success(ok) } }
                "inventory" -> {
                    val ms = (call.argument<Int>("ms") ?: 1000).coerceIn(100, 10000)
                    worker.execute {
                        try {
                            val tags = r.inventory(ms)
                            main.post { result.success(tags) }
                        } catch (e: SilionReader.ReaderError) {
                            main.post { result.error("reader", e.message, null) }
                        }
                    }
                }
                "close" -> worker.execute { r.close(); main.post { result.success(null) } }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        worker.execute { reader?.close() }
        worker.shutdown()
        super.onDestroy()
    }
}
