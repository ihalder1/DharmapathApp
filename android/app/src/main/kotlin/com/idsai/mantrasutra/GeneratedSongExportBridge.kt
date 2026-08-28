package com.idsai.mantrasutra

import android.app.Activity
import android.content.Intent
import java.io.File
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class GeneratedSongExportBridge(private val activity: Activity) :
    MethodChannel.MethodCallHandler {
    companion object {
        private const val CREATE_AUDIO_DOCUMENT_REQUEST = 7401
    }

    private var pendingResult: MethodChannel.Result? = null
    private var pendingSourcePath: String? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "saveAudio") {
            result.notImplemented()
            return
        }
        if (pendingResult != null) {
            result.error("save_in_progress", "Another save is already in progress.", null)
            return
        }

        val sourcePath = call.argument<String>("sourcePath")
        val fileName = call.argument<String>("fileName")
        val mimeType = call.argument<String>("mimeType") ?: "audio/mpeg"
        if (sourcePath.isNullOrBlank() || fileName.isNullOrBlank()) {
            result.error("invalid_arguments", "Source path and file name are required.", null)
            return
        }
        val source = File(sourcePath)
        if (!source.isFile || !source.canRead()) {
            result.error("source_unreadable", "The source audio cannot be read.", null)
            return
        }

        pendingResult = result
        pendingSourcePath = sourcePath
        try {
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = mimeType
                putExtra(Intent.EXTRA_TITLE, fileName)
            }
            activity.startActivityForResult(intent, CREATE_AUDIO_DOCUMENT_REQUEST)
        } catch (error: Exception) {
            clearPending()
            result.error("destination_unavailable", "No save destination is available.", null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != CREATE_AUDIO_DOCUMENT_REQUEST) return false
        val result = pendingResult ?: return true
        val sourcePath = pendingSourcePath
        clearPending()

        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(mapOf("status" to "cancelled"))
            return true
        }

        try {
            File(sourcePath!!).inputStream().use { input ->
                val output = activity.contentResolver.openOutputStream(data.data!!, "w")
                    ?: throw IllegalStateException("Destination cannot be opened")
                output.use { input.copyTo(it) }
            }
            result.success(mapOf("status" to "saved"))
        } catch (error: Exception) {
            result.error("write_failed", "The selected destination could not be written.", null)
        }
        return true
    }

    fun dispose() {
        pendingResult?.error("activity_closed", "The save operation was interrupted.", null)
        clearPending()
    }

    private fun clearPending() {
        pendingResult = null
        pendingSourcePath = null
    }
}
