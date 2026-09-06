package com.i99dev.ilink.voice.ondevice

import android.content.Context
import java.io.File

/**
 * Resolves on-device Moonshine (sherpa-onnx) model directories — the Arabic
 * second-tier fallback. Shares [VoskModelStore]'s "one dir per version" layout
 * (`filesDir/vosk-models/<version>`) and provisioning machinery; only the
 * presence check differs, because a Moonshine bundle is ONNX files, not a
 * Kaldi tree.
 *
 * A compatible locally imported fallback archive unpacks flat to:
 *   encoder_model.ort  decoder_model_merged.ort  tokens.txt  silero_vad.onnx
 *
 * The Dart sherpa_onnx engine loads `encoder_model.ort` + `decoder_model_merged.ort`
 * + `tokens.txt` by absolute path; [modelPathOrNull] hands it the dir.
 */
object MoonshineModelStore {
    /** A Moonshine model for [version] is present iff its dir carries the
     *  ONNX encoder/decoder + tokens. Cheap stat-only check. */
    fun isPresent(context: Context, version: String): Boolean {
        if (version.isBlank()) return false
        val dir = VoskModelStore.modelDir(context, version)
        return dir.isDirectory &&
            File(dir, "encoder_model.ort").isFile &&
            File(dir, "decoder_model_merged.ort").isFile &&
            File(dir, "tokens.txt").isFile
    }

    /** Absolute path of [version]'s Moonshine model dir if present, else null. */
    fun modelPathOrNull(context: Context, version: String): String? =
        if (isPresent(context, version)) {
            VoskModelStore.modelDir(context, version).absolutePath
        } else {
            null
        }
}
