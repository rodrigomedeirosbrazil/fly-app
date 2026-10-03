import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerHostChannel(engineBridge.pluginRegistry)
  }

  // The iOS half of the channel Android serves from MainActivity.kt. Only
  // buildNumber: a release carries nothing an iPhone can install, so the
  // notice there is text, and there is no URL to open.
  //
  // No test reaches this code; every Dart test mocks the channel.
  private func registerHostChannel(_ registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "AerovoltHost") else { return }
    let channel = FlutterMethodChannel(
      name: "br.com.medeirostec.aerovolt/host",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "buildNumber":
        // CFBundleVersion is the `+N` of pubspec.yaml. Nil when it does not
        // parse, which the Dart side treats as "no notice".
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        result(raw.flatMap { Int($0) })
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
