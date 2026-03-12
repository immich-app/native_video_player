import Flutter
import UIKit

public class SwiftNativeVideoPlayerPlugin: NSObject, FlutterPlugin {
    public static var cookieStorage: HTTPCookieStorage?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let factory = NativeVideoPlayerViewFactory(messenger: registrar.messenger())
        registrar.register(factory, withId: NativeVideoPlayerViewFactory.id)
    }
}
