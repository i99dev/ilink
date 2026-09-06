package com.i99dev.ilink.adb

import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.CRC32

/**
 * ADB wire protocol — message format and constants. Ported from
 * car-app/adb/AdbProtocol.kt (itself ported from Saqr's AdbProtocol.java).
 * This file is content-identical to car-app's; only the package changed.
 */
object AdbProtocol {
    const val CMD_CNXN = 0x4E584E43  // "CNXN"
    const val CMD_AUTH = 0x48545541  // "AUTH"
    const val CMD_OPEN = 0x4E45504F  // "OPEN"
    const val CMD_OKAY = 0x59414B4F  // "OKAY"
    const val CMD_WRTE = 0x45545257  // "WRTE"
    const val CMD_CLSE = 0x45534C43  // "CLSE"

    const val AUTH_TOKEN = 1
    const val AUTH_SIGNATURE = 2
    const val AUTH_RSAPUBLICKEY = 3

    const val A_VERSION = 0x01000000
    const val MAX_PAYLOAD = 1048576
    private const val CONNECT_STRING =
        "host::features=shell_v2,cmd,stat_v2,ls_v2,fixed_push_mkdir,apex,abb"

    const val HEADER_SIZE = 24

    data class AdbMessage(
        val command: Int,
        val arg0: Int,
        val arg1: Int,
        val data: ByteArray,
    )

    fun makeConnect(): AdbMessage =
        AdbMessage(CMD_CNXN, A_VERSION, MAX_PAYLOAD, CONNECT_STRING.toByteArray())

    fun makeAuthSignature(signature: ByteArray): AdbMessage =
        AdbMessage(CMD_AUTH, AUTH_SIGNATURE, 0, signature)

    fun makeAuthPublicKey(pubKey: ByteArray): AdbMessage =
        AdbMessage(CMD_AUTH, AUTH_RSAPUBLICKEY, 0, pubKey)

    fun makeOpen(localId: Int, destination: String): AdbMessage =
        AdbMessage(CMD_OPEN, localId, 0, (destination + "\u0000").toByteArray())

    fun makeOkay(localId: Int, remoteId: Int): AdbMessage =
        AdbMessage(CMD_OKAY, localId, remoteId, ByteArray(0))

    fun makeClose(localId: Int, remoteId: Int): AdbMessage =
        AdbMessage(CMD_CLSE, localId, remoteId, ByteArray(0))

    fun makeWrite(localId: Int, remoteId: Int, payload: ByteArray): AdbMessage =
        AdbMessage(CMD_WRTE, localId, remoteId, payload)

    fun writeMessage(out: OutputStream, msg: AdbMessage) {
        val crc = CRC32()
        crc.update(msg.data)
        val header = ByteBuffer.allocate(HEADER_SIZE).order(ByteOrder.LITTLE_ENDIAN)
        header.putInt(msg.command)
        header.putInt(msg.arg0)
        header.putInt(msg.arg1)
        header.putInt(msg.data.size)
        header.putInt(crc.value.toInt())
        header.putInt(msg.command.inv())
        out.write(header.array())
        if (msg.data.isNotEmpty()) out.write(msg.data)
        out.flush()
    }

    fun readMessage(input: InputStream): AdbMessage {
        val header = readFully(input, HEADER_SIZE)
        val buf = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
        val command = buf.int
        val arg0 = buf.int
        val arg1 = buf.int
        val dataLen = buf.int
        buf.int // crc32 (ignored)
        buf.int // magic (ignored)
        val data = if (dataLen > 0) readFully(input, dataLen) else ByteArray(0)
        return AdbMessage(command, arg0, arg1, data)
    }

    private fun readFully(input: InputStream, length: Int): ByteArray {
        val buf = ByteArray(length)
        var offset = 0
        while (offset < length) {
            val read = input.read(buf, offset, length - offset)
            if (read < 0) throw java.io.EOFException("expected $length, got $offset")
            offset += read
        }
        return buf
    }
}
