protocol NativeVideoPlayerApiDelegate: AnyObject {
    func loadVideoSource(videoSource: VideoSource)
    func getVideoInfo() -> VideoInfo
    func getPlaybackPosition() -> Int
    func play()
    func pause()
    func stop(completion: @escaping () -> Void)
    func isPlaying() -> Bool
    func seekTo(position: Int, completion: @escaping () -> Void)
    func setPlaybackSpeed(speed: Double)
    func setVolume(volume: Double)
    func setLoop(loop: Bool)
}

let invalidArgumentsFlutterError = FlutterError(
    code: "invalid_argument", message: "Invalid arguments", details: nil)

class NativeVideoPlayerApi: NSObject, FlutterStreamHandler {
    weak var delegate: NativeVideoPlayerApiDelegate?

    let channel: FlutterMethodChannel
    private var eventSink: FlutterEventSink?

    init(
        messenger: FlutterBinaryMessenger,
        viewId: Int64
    ) {
        let name = "me.albemala.native_video_player.api.\(viewId)"
        channel = FlutterMethodChannel(
            name: name,
            binaryMessenger: messenger
        )
        let eventName = "\(name).event"
        let eventChannel = FlutterEventChannel(name: eventName, binaryMessenger: messenger)

        super.init()
        channel.setMethodCallHandler(handleMethodCall)
        eventChannel.setStreamHandler(self)
    }

    deinit {
        channel.setMethodCallHandler(nil)
    }
    
    func onListen(withArguments arguments: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = eventSink
        return nil
    }
    
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    func onPlaybackReady() {
        channel.invokeMethod("onPlaybackReady", arguments: nil)
    }

    func onPlaybackEnded() {
        channel.invokeMethod("onPlaybackEnded", arguments: nil)
    }

    func onError(_ error: Error) {
        channel.invokeMethod("onError", arguments: error.localizedDescription)
    }
    
    func emitStatus(status : PlaybackStatus) {
        self.eventSink?(status.rawValue)
    }

    private func handleMethodCall(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "loadVideoSource":
            guard let videoSourceAsMap = call.arguments as? [String: Any] else {
                result(invalidArgumentsFlutterError)
                return
            }
            guard let videoSource = VideoSource(from: videoSourceAsMap) else {
                result(invalidArgumentsFlutterError)
                return
            }
            delegate?.loadVideoSource(videoSource: videoSource)
            result(nil)
        case "getVideoInfo":
            let videoInfo = delegate?.getVideoInfo().toMap()
            result(videoInfo)
        case "getPlaybackPosition":
            let playbackPosition = delegate?.getPlaybackPosition()
            result(playbackPosition)
        case "play":
            delegate?.play()
            result(nil)
        case "pause":
            delegate?.pause()
            result(nil)
        case "stop":
            delegate?.stop {
                result(nil)
            }
        case "isPlaying":
            let playing = delegate?.isPlaying()
            result(playing)
        case "seekTo":
            guard let position = call.arguments as? Int else {
                result(invalidArgumentsFlutterError)
                return
            }
            delegate?.seekTo(position: position) {
                result(nil)
            }
        case "setPlaybackSpeed":
            guard let playbackSpeed = call.arguments as? Double else {
                result(invalidArgumentsFlutterError)
                return
            }
            delegate?.setPlaybackSpeed(speed: playbackSpeed)
            result(nil)
        case "setVolume":
            guard let volume = call.arguments as? Double else {
                result(invalidArgumentsFlutterError)
                return
            }
            delegate?.setVolume(volume: volume)
            result(nil)
        case "setLoop":
            guard let loop = call.arguments as? Bool else {
                result(invalidArgumentsFlutterError)
                return
            }
            delegate?.setLoop(loop: loop)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
