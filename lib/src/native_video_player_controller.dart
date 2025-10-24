import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:native_video_player/src/platform_interface/native_video_player_api.dart';
import 'package:native_video_player/src/playback_info.dart';
import 'package:native_video_player/src/playback_status.dart';
import 'package:native_video_player/src/video_info.dart';
import 'package:native_video_player/src/video_source.dart';

class NativeVideoPlayerController with ChangeNotifier {
  late final NativeVideoPlayerApi _api;
  VideoSource? _videoSource;
  VideoInfo? _videoInfo;

  PlaybackStatus get _playbackStatus => onPlaybackStatusChanged.value;

  int get _playbackPosition => onPlaybackPositionChanged.value;

  double get _playbackPositionFraction => videoInfo != null //
      ? _playbackPosition / videoInfo!.duration
      : 0;

  double _playbackSpeed = 1;

  double _volume = 0;

  String? get _error => onError.value;

  /// Emitted when the video loaded successfully and it's ready to play.
  /// At this point, [videoInfo] and [playbackInfo] are available.
  final onPlaybackReady = ChangeNotifier();

  /// You can get the playback status also with [playbackInfo]
  final onPlaybackStatusChanged = ValueNotifier<PlaybackStatus>(
    PlaybackStatus.stopped,
  );

  /// You can get the playback position also with [playbackInfo]
  final onPlaybackPositionChanged = ValueNotifier<int>(0);

  /// You can get the playback speed also with [playbackInfo]
  final onPlaybackSpeedChanged = ValueNotifier<double>(1);

  /// You can get the playback volume also with [playbackInfo]
  final onVolumeChanged = ValueNotifier<double>(0);

  /// Emitted when the video has finished playing.
  final onPlaybackEnded = ChangeNotifier();

  /// Emitted when a playback error occurs
  /// or when it's not possible to load the video source
  final onError = ValueNotifier<String?>(null);

  /// The video source that is currently loaded.
  VideoSource? get videoSource => _videoSource;

  /// The video info about the current video source.
  VideoInfo? get videoInfo => _videoInfo;

  /// The playback info about the video being played.
  PlaybackInfo? get playbackInfo => PlaybackInfo(
        status: _playbackStatus,
        position: _playbackPosition,
        positionFraction: _playbackPositionFraction,
        speed: _playbackSpeed,
        volume: _volume,
        error: _error,
      );

  /// NOTE: For internal use only.
  /// See [NativeVideoPlayerView.onViewReady] instead.
  @protected
  NativeVideoPlayerController(int viewId) {
    _api = NativeVideoPlayerApi(
      viewId: viewId,
      onPlaybackReady: _onPlaybackReady,
      onPlaybackEnded: _onPlaybackEnded,
      onPlaybackPositionChanged: _onPlaybackPositionChanged,
      onError: _onError,
    );
  }

  Future<void> _onPlaybackReady() async {
    _videoInfo = await _api.getVideoInfo();
    // Make sure the volume is reset to the correct value
    await setVolume(_volume);
    onPlaybackReady.notifyListeners();
  }

  void _onPlaybackEnded() {
    onPlaybackStatusChanged.value = PlaybackStatus.stopped;
    onPlaybackEnded.notifyListeners();
  }

  void _onError(String? message) {
    onError.value = message;
  }

  // NOTE: For internal use only.
  @override
  @protected
  void dispose() {
    _api.dispose();
    super.dispose();
  }

  /// Loads a new video source.
  ///
  /// NOTE: This method might throw an exception if the video source is invalid.
  Future<void> loadVideoSource(VideoSource videoSource) async {
    await stop();
    await _api.loadVideoSource(videoSource);
    _videoSource = videoSource;
  }

  /// Starts/resumes the playback of the video.
  ///
  /// NOTE: This method might throw an exception if the video cannot be played.
  Future<void> play() async {
    await _api.play();
    onPlaybackStatusChanged.value = PlaybackStatus.playing;
    await setPlaybackSpeed(_playbackSpeed);
  }

  /// Pauses the playback of the video.
  /// Use [play] to resume the playback from the paused position.
  ///
  /// NOTE: This method might throw an exception if the video cannot be paused.
  Future<void> pause() async {
    await _api.pause();
    onPlaybackStatusChanged.value = PlaybackStatus.paused;
  }

  /// Stops the playback of the video.
  /// The playback position is reset to 0.
  /// Use [play] to start the playback from the beginning.
  ///
  /// NOTE: This method might throw an exception if the video cannot be stopped.
  Future<void> stop() async {
    await _api.stop();
    onPlaybackStatusChanged.value = PlaybackStatus.stopped;
  }

  /// Returns true if the video is playing, or false if it's stopped or paused.
  Future<bool> isPlaying() async {
    try {
      return await _api.isPlaying() ?? false;
    } catch (exception) {
      return false;
    }
  }

  /// Moves the playback position to the given position in milliseconds.
  ///
  /// NOTE: This method might throw an exception if the video cannot be seeked.
  Future<void> seekTo(int milliseconds) async {
    var position = milliseconds;
    if (milliseconds < 0) position = 0;
    final duration = videoInfo?.duration ?? 0;
    if (milliseconds > duration) position = duration;
    await _api.seekTo(position);
    // if the video is not playing, update onPlaybackPositionChanged
    if (_playbackStatus != PlaybackStatus.playing) {
      onPlaybackPositionChanged.value = position;
    }
  }

  /// Seeks the video forward by the given number of milliseconds.
  Future<void> seekForward(int milliseconds) async {
    final duration = videoInfo?.duration ?? 0;
    final newPlaybackPosition = _playbackPosition + milliseconds > duration //
        ? duration
        : _playbackPosition + milliseconds;
    await seekTo(newPlaybackPosition);
  }

  /// Seeks the video backward by the given number of milliseconds.
  Future<void> seekBackward(int milliseconds) async {
    final newPlaybackPosition = _playbackPosition - milliseconds < 0 //
        ? 0
        : _playbackPosition - milliseconds;
    await seekTo(newPlaybackPosition);
  }

  /// Sets the playback speed.
  /// The default value is 1.
  Future<void> setPlaybackSpeed(double speed) async {
    if (onPlaybackStatusChanged.value == PlaybackStatus.playing) {
      await _api.setPlaybackSpeed(speed);
    }
    _playbackSpeed = speed;
    onPlaybackSpeedChanged.value = speed;
  }

  /// Sets the volume of the player.
  ///
  /// NOTE: This method might throw an exception if the volume cannot be set.
  Future<void> setVolume(double volume) async {
    await _api.setVolume(volume);
    _volume = volume;
    onVolumeChanged.value = volume;
  }

  // ignore: avoid_positional_boolean_parameters
  Future<void> setLoop(bool loop) {
    return _api.setLoop(loop);
  }

  // ignore: use_setters_to_change_properties
  void _onPlaybackPositionChanged(int position) {
    onPlaybackPositionChanged.value = position;
  }
}
