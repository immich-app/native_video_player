package me.albemala.native_video_player

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.SurfaceView
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.ui.AspectRatioFrameLayout
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.platform.PlatformView
import me.albemala.native_video_player.platform_interface.*

@OptIn(UnstableApi::class)
class NativeVideoPlayerViewController(
    messenger: BinaryMessenger,
    viewId: Int,
    context: Context,
    private val api: NativeVideoPlayerApi = NativeVideoPlayerApi(messenger, viewId),
) : PlatformView,
    NativeVideoPlayerApiDelegate,
    Player.Listener {

    private val player: ExoPlayer
    private val view: SurfaceView
    private val container: FrameLayout
    private val aspectRatioLayout: AspectRatioFrameLayout

    private val positionUpdateHandler = Handler(Looper.getMainLooper())
    private var positionUpdateRunnable: Runnable? = null
    private var lastPosition = -1L

    init {
        api.delegate = this
        player = ExoPlayer.Builder(context).build()
        player.addListener(this)

        view = SurfaceView(context)
        view.setBackgroundColor(0)
        view.layoutParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        )
        player.setVideoSurfaceView(view)

        aspectRatioLayout = AspectRatioFrameLayout(context)
        aspectRatioLayout.visibility = View.INVISIBLE
        aspectRatioLayout.layoutParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT,
            Gravity.CENTER
        )
        aspectRatioLayout.addView(view)

        container = FrameLayout(context)
        container.layoutParams = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        )
        container.addView(aspectRatioLayout)
    }

    override fun getView(): View {
        return container
    }

    override fun dispose() {
        player.removeListener(this)
        stopPositionUpdates()
        api.dispose()
        player.release()
    }

    override fun loadVideoSource(videoSource: VideoSource) {
        val mediaItem = MediaItem.fromUri(videoSource.path)
        when (videoSource.type) {
            VideoSourceType.Asset, VideoSourceType.File -> player.setMediaItem(mediaItem)
            VideoSourceType.Network -> {
                val dataSource = DefaultHttpDataSource.Factory().setDefaultRequestProperties(videoSource.headers)
                val mediaSource = ProgressiveMediaSource.Factory(dataSource).createMediaSource(mediaItem)
                player.setMediaSource(mediaSource)
            }
        }
        player.prepare()
    }

    override fun getVideoInfo(): VideoInfo {
        val videoSize = player.videoSize
        return VideoInfo(videoSize.height.toLong(), videoSize.width.toLong(), player.duration)
    }

    override fun getPlaybackPosition(): Long {
        return player.currentPosition
    }

    override fun play() {
        player.play()
    }

    override fun pause() {
        player.pause()
    }

    override fun stop() {
        player.stop()
    }

    override fun isPlaying(): Boolean {
        return player.isPlaying
    }

    override fun seekTo(position: Int) {
        player.seekTo(position.toLong())
    }

    override fun setPlaybackSpeed(speed: Double) {
        player.setPlaybackSpeed(speed.toFloat())
    }

    override fun setVolume(volume: Double) {
        player.volume = volume.toFloat()
    }

    override fun setLoop(loop: Boolean) {
        player.repeatMode = if (loop) Player.REPEAT_MODE_ALL else Player.REPEAT_MODE_OFF
    }

    override fun onPlaybackStateChanged(@Player.State state: Int) {
        if (state == Player.STATE_READY) {
            api.onPlaybackReady()
            startPositionUpdates()
        }

        if (state == Player.STATE_ENDED) {
            return api.onPlaybackEnded()
        }
    }

    override fun onVideoSizeChanged(videoSize: VideoSize) {
        if (videoSize.height <= 0) return
        aspectRatioLayout.setAspectRatio(
            (videoSize.width * videoSize.pixelWidthHeightRatio) / videoSize.height
        )
        if (aspectRatioLayout.visibility != View.VISIBLE) {
            aspectRatioLayout.post { aspectRatioLayout.visibility = View.VISIBLE }
        }
    }

    override fun onPlayerError(error: PlaybackException) {
        if (error.cause == null) {
            api.onError(Error("Unknown playback error occurred"))
        } else {
            api.onError(error.cause as Throwable)
        }
    }

    private fun startPositionUpdates() {
        stopPositionUpdates()
        positionUpdateRunnable = object : Runnable {
            override fun run() {
                val position = player.currentPosition
                if (lastPosition != position) {
                    lastPosition = position
                    api.onPlaybackPositionChanged(position)
                }
                positionUpdateHandler.postDelayed(this, 8L)
            }
        }
        positionUpdateHandler.post(positionUpdateRunnable!!)
    }

    private fun stopPositionUpdates() {
        positionUpdateRunnable?.let {
            positionUpdateHandler.removeCallbacks(it)
            positionUpdateRunnable = null
        }
    }
}
