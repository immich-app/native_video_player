package me.albemala.native_video_player.platform_interface

data class VideoInfo(
    val height: Long,
    val width: Long,
    val duration: Long
) {
    fun toMap(): Map<String, Long> = mapOf(
        "height" to height,
        "width" to width,
        "duration" to duration
    )
}
