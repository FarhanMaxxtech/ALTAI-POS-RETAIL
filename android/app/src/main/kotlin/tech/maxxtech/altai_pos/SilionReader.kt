package tech.maxxtech.altai_pos

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build

/**
 * Silion desktop UHF reader (USB 2E88:4605) in passive ("normal") mode.
 *
 * The reader has two USB parts: 0 = commands (a vendor HID), 1 = keyboard (used only in its
 * keyboard mode). We talk to part 0.
 *
 * Each 64-byte HID report carries [length][data, up to 61 bytes][16-bit sum of data, big end].
 * Inside is the reader's command frame: FF, data length, command, data, CRC-16 (ThingMagic style).
 * Commands used: 2A clear tag list, 22 read tags for N ms, 29 get the tags read (page by page).
 */
class SilionReader(private val context: Context) {
    companion object {
        const val VENDOR_ID = 0x2E88
        const val PRODUCT_ID = 0x4605
        private const val ACTION_PERMISSION = "tech.maxxtech.altai_pos.USB_PERMISSION"
        private const val REPORT = 64
        private const val MAX_CHUNK = 61
    }

    class ReaderError(message: String) : Exception(message)

    private val usb = context.getSystemService(Context.USB_SERVICE) as UsbManager
    private var connection: UsbDeviceConnection? = null
    private var iface: UsbInterface? = null
    private var epIn: UsbEndpoint? = null
    private var epOut: UsbEndpoint? = null
    private val pending = ArrayList<Byte>() // bytes received but not yet framed

    fun findDevice(): UsbDevice? =
        usb.deviceList.values.firstOrNull { it.vendorId == VENDOR_ID && it.productId == PRODUCT_ID }

    /** "none" = not plugged in, "no-permission" = plugged in but not allowed yet, "ready". */
    fun status(): String {
        val d = findDevice() ?: return "none"
        return if (usb.hasPermission(d)) "ready" else "no-permission"
    }

    /** Shows Android's "Allow Altai POS to access the reader?" box. [done] gets true if allowed. */
    fun requestPermission(done: (Boolean) -> Unit) {
        val d = findDevice() ?: return done(false)
        if (usb.hasPermission(d)) return done(true)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                if (i.action != ACTION_PERMISSION) return
                context.unregisterReceiver(this)
                done(i.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false))
            }
        }
        val filter = IntentFilter(ACTION_PERMISSION)
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }
        val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
        val intent = Intent(ACTION_PERMISSION).setPackage(context.packageName)
        usb.requestPermission(d, PendingIntent.getBroadcast(context, 0, intent, flags))
    }

    @Synchronized
    fun close() {
        connection?.let { c -> iface?.let { c.releaseInterface(it) }; c.close() }
        connection = null; iface = null; epIn = null; epOut = null
        pending.clear()
    }

    private fun open() {
        if (connection != null && findDevice() != null) return
        close()
        val d = findDevice() ?: throw ReaderError("No RFID reader plugged in.")
        if (!usb.hasPermission(d)) throw ReaderError("The app is not allowed to use the reader yet.")
        // The command part: a HID interface that is not the keyboard (keyboard = protocol 1).
        val i = (0 until d.interfaceCount).map { d.getInterface(it) }
            .firstOrNull { it.interfaceClass == UsbConstants.USB_CLASS_HID && it.interfaceProtocol != 1 }
            ?: throw ReaderError("This reader has no command channel.")
        val c = usb.openDevice(d) ?: throw ReaderError("Could not open the reader.")
        if (!c.claimInterface(i, true)) { c.close(); throw ReaderError("The reader is busy.") }
        for (k in 0 until i.endpointCount) {
            val e = i.getEndpoint(k)
            if (e.direction == UsbConstants.USB_DIR_IN) epIn = e else epOut = e
        }
        if (epIn == null) { c.releaseInterface(i); c.close(); throw ReaderError("The reader sends no data.") }
        connection = c; iface = i
    }

    /* ---------- framing ---------- */

    private fun crc(bytes: ByteArray, from: Int, to: Int): Int {
        var c = 0xFFFF
        for (k in from until to) {
            val b = bytes[k].toInt() and 0xFF
            for (bit in 7 downTo 0) {
                val top = (c shr 15) and 1
                c = ((c shl 1) or ((b shr bit) and 1)) and 0xFFFF
                if (top == 1) c = c xor 0x1021
            }
        }
        return c
    }

    private fun frame(cmd: Int, data: ByteArray = ByteArray(0)): ByteArray {
        val f = ByteArray(data.size + 5)
        f[0] = 0xFF.toByte(); f[1] = data.size.toByte(); f[2] = cmd.toByte()
        data.copyInto(f, 3)
        val c = crc(f, 1, 3 + data.size)
        f[3 + data.size] = (c shr 8).toByte(); f[4 + data.size] = c.toByte()
        return f
    }

    private fun send(f: ByteArray) {
        val c = connection!!
        var at = 0
        while (at < f.size) {
            val n = minOf(MAX_CHUNK, f.size - at)
            val r = ByteArray(REPORT)
            r[0] = n.toByte()
            var sum = 0
            for (k in 0 until n) { r[1 + k] = f[at + k]; sum += f[at + k].toInt() and 0xFF }
            r[1 + n] = (sum shr 8).toByte(); r[2 + n] = sum.toByte()
            val ok = if (epOut != null) {
                c.bulkTransfer(epOut, r, r.size, 1000) == r.size
            } else { // no OUT endpoint: HID SET_REPORT (output) on the control pipe
                c.controlTransfer(0x21, 0x09, 0x0200, iface!!.id, r, r.size, 1000) == r.size
            }
            if (!ok) { close(); throw ReaderError("Could not send to the reader.") }
            at += n
        }
    }

    /** One whole reply frame (FF len cmd status(2) data crc(2)), or an error after [timeoutMs]. */
    private fun receive(timeoutMs: Long): ByteArray {
        val c = connection!!
        val end = System.currentTimeMillis() + timeoutMs
        val buf = ByteArray(REPORT)
        while (true) {
            while (pending.isNotEmpty() && pending[0] != 0xFF.toByte()) pending.removeAt(0)
            if (pending.size >= 7) {
                val total = (pending[1].toInt() and 0xFF) + 7
                if (pending.size >= total) {
                    val f = ByteArray(total) { pending[it] }
                    repeat(total) { pending.removeAt(0) }
                    if (crc(f, 1, total - 2) == (((f[total - 2].toInt() and 0xFF) shl 8) or (f[total - 1].toInt() and 0xFF))) return f
                    continue // damaged frame: skip it
                }
            }
            val left = end - System.currentTimeMillis()
            if (left <= 0) throw ReaderError("The reader did not answer.")
            val n = c.bulkTransfer(epIn, buf, buf.size, minOf(left, 200L).toInt())
            if (n > 0) {
                val len = buf[0].toInt() and 0xFF
                if (len in 1..MAX_CHUNK && len + 1 <= n) for (k in 1..len) pending.add(buf[k])
            }
        }
    }

    private fun command(cmd: Int, data: ByteArray = ByteArray(0), timeoutMs: Long = 1500): ByteArray {
        send(frame(cmd, data))
        while (true) {
            val f = receive(timeoutMs)
            if ((f[2].toInt() and 0xFF) == cmd) return f // skip any stray reply
        }
    }

    private fun status(f: ByteArray) = ((f[3].toInt() and 0xFF) shl 8) or (f[4].toInt() and 0xFF)

    /* ---------- reading ---------- */

    /** Reads for [ms] milliseconds and returns every EPC seen (upper-case hex, no duplicates). */
    @Synchronized
    fun inventory(ms: Int): List<String> {
        try {
            open()
            command(0x2A) // clear the reader's tag list
            val read = command(
                0x22,
                byteArrayOf(0, 0, 0, (ms shr 8).toByte(), ms.toByte()),
                timeoutMs = ms + 1500L,
            )
            val st = status(read)
            if (st == 0x0400) return emptyList() // no tags in the field
            if (st != 0) throw ReaderError("Reader error 0x%04X".format(st))

            val tags = LinkedHashSet<String>()
            repeat(50) { // the list comes in pages; stop at an empty page or an error
                val page = command(0x29, byteArrayOf(0, 0, 0))
                if (status(page) != 0) return tags.toList()
                val got = parsePage(page)
                if (got.isEmpty()) return tags.toList()
                tags.addAll(got)
            }
            return tags.toList()
        } catch (e: ReaderError) {
            throw e
        } catch (e: Exception) {
            close()
            throw ReaderError("Reader problem: ${e.message}")
        }
    }

    /** 29 reply: FF len 29 status(2) | flags(2) option(1) count(1) | per tag: bits(2) PC(2) EPC CRC(2). */
    private fun parsePage(f: ByteArray): List<String> {
        val end = f.size - 2
        var i = 5
        if (end - i < 4) return emptyList()
        val count = f[i + 3].toInt() and 0xFF
        i += 4
        val out = ArrayList<String>()
        repeat(count) {
            if (i + 2 > end) return out
            val bytes = (((f[i].toInt() and 0xFF) shl 8) or (f[i + 1].toInt() and 0xFF)) / 8
            i += 2
            if (bytes < 4 || i + bytes > end) return out
            val sb = StringBuilder()
            for (k in i + 2 until i + bytes - 2) sb.append("%02X".format(f[k].toInt() and 0xFF))
            if (sb.isNotEmpty()) out.add(sb.toString())
            i += bytes
        }
        return out
    }
}
