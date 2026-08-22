import UIKit
import Flutter
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    
    let controller: FlutterViewController = window?.rootViewController as! FlutterViewController
    let audioChannel = FlutterMethodChannel(name: "app.channel.audio", binaryMessenger: controller.binaryMessenger)

    audioChannel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "requestMicrophoneNative":
        let session = AVAudioSession.sharedInstance()
        do {
          try session.setCategory(.playAndRecord, options: [.defaultToSpeaker])
          try session.setActive(true)
        } catch {
          result(FlutterError(code: "AUDIO_SESSION_ERROR", message: "Could not activate AVAudioSession: \(error)", details: nil))
          return
        }

        AVAudioSession.sharedInstance().requestRecordPermission { granted in
          DispatchQueue.main.async {
            result(granted ? 2 : 1) // 2 = granted, 1 = denied
          }
        }

      case "readMicrophoneNativeStatus":
        let session = AVAudioSession.sharedInstance()
        let rp = session.recordPermission
        let recordPermissionInt: Int
        switch rp {
          case .undetermined: recordPermissionInt = 0
          case .denied: recordPermissionInt = 1
          case .granted: recordPermissionInt = 2
          @unknown default: recordPermissionInt = -1
        }

        let statusMap: [String: Any] = [
          "recordPermission": recordPermissionInt,
          "isInputAvailable": session.isInputAvailable,
          "category": session.category.rawValue,
          "mode": session.mode.rawValue,
          "sampleRate": session.sampleRate
        ]
        result(statusMap)

      case "configureAudioSessionForPlayback":
        let session = AVAudioSession.sharedInstance()
        do {
          // Configure for playback - use playAndRecord but optimize for playback
          try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
          try session.setActive(true)
          result(true)
        } catch {
          result(FlutterError(code: "AUDIO_SESSION_ERROR", message: "Could not configure audio session for playback: \(error)", details: nil))
        }

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
