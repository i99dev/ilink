package com.i99dev.ilink.voice.ondevice

import java.net.HttpURLConnection
import java.net.URL

/** Curated transport origins, not publisher authenticity: upstream digests are not pinned. */
internal object ModelDownloadPolicy {
    private val files = setOf(
        "vosk-model-small-en-us-0.15.zip", "vosk-model-small-ar-0.3.zip",
        "vosk-model-small-ru-0.22.zip", "vosk-model-small-fr-0.22.zip",
        "vosk-model-small-es-0.42.zip", "vosk-model-small-de-0.15.zip",
        "vosk-model-small-cn-0.22.zip", "vosk-model-small-tr-0.3.zip",
        "vosk-model-small-fa-0.42.zip", "vosk-model-small-hi-0.22.zip",
        "vosk-model-small-it-0.4.zip", "vosk-model-small-pt-0.3.zip",
    )

    fun validatedUrl(value: String): URL {
        if (files.none { value == "https://alphacephei.com/vosk/models/$it" }) {
            throw ModelPolicyException("Unapproved speech model URL")
        }
        return URL(value)
    }

    fun configure(connection: HttpURLConnection) {
        connection.instanceFollowRedirects = false
        connection.setRequestProperty("Accept-Encoding", "identity")
    }

    fun requireStatus(code: Int) {
        if (code != 200 && code != 206 && code != 416) {
            throw ModelPolicyException("Speech model HTTP status $code is not allowed")
        }
    }

    fun requireRange(header: String?, offset: Long): Long {
        val match = Regex("bytes (\\d+)-(\\d+)/(\\d+)").matchEntire(header ?: "")
            ?: throw ModelPolicyException("Invalid model resume range")
        val values = match.groupValues.drop(1).map { it.toLongOrNull() ?: throw ModelPolicyException("Invalid model resume range") }
        val (start, end, total) = values
        if (start != offset || end < start || total <= end) throw ModelPolicyException("Unexpected model resume range")
        return total
    }
}
