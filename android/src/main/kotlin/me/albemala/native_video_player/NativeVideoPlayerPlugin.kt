package me.albemala.native_video_player

import androidx.annotation.NonNull
import androidx.media3.datasource.DataSource

import io.flutter.embedding.engine.plugins.FlutterPlugin

class NativeVideoPlayerPlugin : FlutterPlugin {
    companion object {
        var dataSourceFactory: ((Map<String, String>) -> DataSource.Factory)? = null
    }

    override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        val factory = NativeVideoPlayerViewFactory(binding.binaryMessenger)
        binding.platformViewRegistry.registerViewFactory(NativeVideoPlayerViewFactory.id, factory)
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    }
}
