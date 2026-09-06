package com.i99dev.ilink.adb

import android.content.Context
import android.util.Log
import com.i99dev.ilink.BuildConfig
import java.io.EOFException
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.net.ConnectException
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketException
import java.net.SocketTimeoutException
import java.security.PrivateKey
import java.util.concurrent.atomic.AtomicInteger

/**
 * ADB TCP client with RSA auth. Ported from car-app/adb/AdbConnection.kt.
 *
 * Single-use in dash: we connect, run ONE shell command (spawn the daemon),
 * then close. All subsequent commands go through the daemon via LocalSocket.
 */
class AdbConnection private constructor(
    private val socket: Socket,
    private val input: InputStream,
    private val output: OutputStream,
    private val priv: PrivateKey,
) {
    companion object {
        private const val TAG = "AdbConnection"

        /** Per-WRTE payload for [pushFile]. Under the negotiated 1 MB maxdata. */
        private const val PUSH_CHUNK = 256 * 1024
        private const val CONNECT_TIMEOUT = 5000
        private const val IO_FAST = 8000
        private const val IO_SLOW = 90_000 // user may need to tap ALLOW
        private const val MAX_AUTH_ATTEMPTS = 60

        fun connect(
            ctx: Context,
            host: String = "127.0.0.1",
            port: Int = BuildConfig.ADBD_PORT,
        ): AdbConnection {
            val (priv, pub) = AdbCrypto.loadOrCreateKeyPair(ctx)
            val socket = Socket()
            socket.connect(InetSocketAddress(host, port), CONNECT_TIMEOUT)
            socket.soTimeout = IO_FAST
            val input = socket.getInputStream()
            val output = socket.getOutputStream()

            AdbProtocol.writeMessage(output, AdbProtocol.makeConnect())

            var sentPubKey = false
            var firstSign = true
            for (attempt in 0 until MAX_AUTH_ATTEMPTS) {
                val msg = AdbProtocol.readMessage(input)
                when (msg.command) {
                    AdbProtocol.CMD_AUTH -> {
                        if (msg.arg0 != AdbProtocol.AUTH_TOKEN) continue
                        if (firstSign) {
                            AdbProtocol.writeMessage(
                                output,
                                AdbProtocol.makeAuthSignature(AdbCrypto.sign(priv, msg.data))
                            )
                            firstSign = false
                        } else if (!sentPubKey) {
                            socket.soTimeout = IO_SLOW
                            AdbProtocol.writeMessage(
                                output,
                                AdbProtocol.makeAuthPublicKey(AdbCrypto.adbPublicKeyBytes(pub))
                            )
                            sentPubKey = true
                            Log.i(TAG, "sent AUTH_RSAPUBLICKEY — user must tap ALLOW")
                        } else {
                            AdbProtocol.writeMessage(
                                output,
                                AdbProtocol.makeAuthSignature(AdbCrypto.sign(priv, msg.data))
                            )
                        }
                    }
                    AdbProtocol.CMD_CNXN -> {
                        AdbCrypto.markTrusted(ctx)
                        socket.soTimeout = IO_FAST
                        return AdbConnection(socket, input, output, priv)
                    }
                    else -> Log.w(TAG, "unexpected cmd 0x${msg.command.toString(16)}")
                }
            }
            socket.close()
            val hint = if (sentPubKey) "Tap ALLOW on the car screen" else "Is adbd running?"
            throw ConnectException("ADB auth failed ($hint)")
        }
    }

    private val localIdCounter = AtomicInteger(1)

    /** Execute a shell command and return stdout+stderr (combined). */
    fun shell(cmd: String, timeoutMs: Long = 20_000): String {
        val localId = localIdCounter.getAndIncrement()
        val sb = StringBuilder()
        var remoteId = 0
        AdbProtocol.writeMessage(output, AdbProtocol.makeOpen(localId, "shell:$cmd"))
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            try {
                val msg = AdbProtocol.readMessage(input)
                when (msg.command) {
                    AdbProtocol.CMD_OKAY -> if (remoteId == 0) remoteId = msg.arg0
                    AdbProtocol.CMD_WRTE -> if (msg.arg1 == localId) {
                        sb.append(String(msg.data))
                        AdbProtocol.writeMessage(
                            output,
                            AdbProtocol.makeOkay(localId, msg.arg0)
                        )
                    }
                    AdbProtocol.CMD_CLSE -> if (msg.arg1 == localId) break
                }
            } catch (_: SocketTimeoutException) {
                // Slow command, but the connection itself may be fine — break
                // and leave the socket cached for reuse (don't force a reconnect
                // on a merely-slow shell).
                break
            } catch (_: EOFException) {
                // Peer closed the stream → this REUSED connection is dead.
                // Close it so the next shell()'s makeOpen write fails fast and
                // the caller (AdbShellBridge.shellViaAdb) reconnects — instead
                // of silently returning empty against a half-dead socket
                // forever (the loopback-ADB sibling of the daemon zombie bug).
                close()
                break
            } catch (_: SocketException) {
                close()
                break
            }
        }
        try {
            if (remoteId != 0)
                AdbProtocol.writeMessage(output, AdbProtocol.makeClose(localId, remoteId))
        } catch (_: Exception) {}
        return sb.toString().trim()
    }

    /**
     * Stream [file] to [remotePath] on the device via `exec:cat > path`,
     * sending the raw bytes as WRTE packets (flow-controlled by the peer's
     * OKAY acks). This is ~orders of magnitude faster than base64-over-shell
     * for large APKs: the data rides the stream's payload (up to the
     * negotiated 1 MB maxdata) instead of the 128 KB shell-arg limit, with no
     * base64 inflation. Returns true on a clean transfer; on ANY protocol
     * error it closes the connection (so the bridge reconnects) and returns
     * false, letting the caller fall back to base64. The caller still SHA-
     * verifies the result, so a partial/garbled push fails safely.
     *
     * [remotePath] must be shell-quote-safe (our `/data/local/tmp/i99p_*`
     * names are).
     */
    fun pushFile(file: File, remotePath: String, timeoutMs: Long = 180_000): Boolean {
        val localId = localIdCounter.getAndIncrement()
        var remoteId = 0
        val deadline = System.currentTimeMillis() + timeoutMs
        try {
            AdbProtocol.writeMessage(output, AdbProtocol.makeOpen(localId, "exec:cat > $remotePath"))
            // Wait for the stream to be accepted (OKAY carries the remoteId).
            while (remoteId == 0 && System.currentTimeMillis() < deadline) {
                val msg = AdbProtocol.readMessage(input)
                when (msg.command) {
                    AdbProtocol.CMD_OKAY -> if (msg.arg1 == localId) remoteId = msg.arg0
                    AdbProtocol.CMD_CLSE -> if (msg.arg1 == localId) { close(); return false }
                }
            }
            if (remoteId == 0) { close(); return false }

            // Stream the file, waiting for an OKAY ack after each WRTE.
            val buf = ByteArray(PUSH_CHUNK)
            file.inputStream().buffered().use { ins ->
                while (true) {
                    val n = ins.read(buf)
                    if (n < 0) break
                    val payload = if (n == buf.size) buf else buf.copyOf(n)
                    AdbProtocol.writeMessage(output, AdbProtocol.makeWrite(localId, remoteId, payload))
                    var acked = false
                    while (!acked && System.currentTimeMillis() < deadline) {
                        val msg = AdbProtocol.readMessage(input)
                        when (msg.command) {
                            AdbProtocol.CMD_OKAY -> if (msg.arg1 == localId) acked = true
                            // `cat > file` produces no stdout, but ack any WRTE defensively.
                            AdbProtocol.CMD_WRTE -> if (msg.arg1 == localId) {
                                AdbProtocol.writeMessage(output, AdbProtocol.makeOkay(localId, msg.arg0))
                            }
                            AdbProtocol.CMD_CLSE -> if (msg.arg1 == localId) { close(); return false }
                        }
                    }
                    if (!acked) { close(); return false }
                }
            }

            // Close our side → EOF on cat's stdin → it flushes + exits. Drain
            // until the peer closes (or a read times out — SHA verify is the
            // real arbiter either way).
            AdbProtocol.writeMessage(output, AdbProtocol.makeClose(localId, remoteId))
            try {
                while (System.currentTimeMillis() < deadline) {
                    val msg = AdbProtocol.readMessage(input)
                    if (msg.command == AdbProtocol.CMD_CLSE && msg.arg1 == localId) break
                }
            } catch (_: SocketTimeoutException) {
                // peer slow to close; bytes are already flushed — let SHA verify.
            }
            return true
        } catch (e: Throwable) {
            Log.w(TAG, "pushFile($remotePath) failed: ${e.message}")
            close()
            return false
        }
    }

    fun close() { try { socket.close() } catch (_: Exception) {} }
}
