import CryptoKit
import DeviceCheck
import Flutter
import UIKit
import UserNotifications

/// Canal « pointeuse/security » (voir lib/services/device_security.dart).
///  - isVpnActive      : VPN actif (interfaces réseau utun, ipsec, ppp, tap, tun)
///  - appAttest        : preuve App Attest liée au défi du serveur (attestation la 1re fois, puis assertion)
///  - appAttestConfirm : le serveur a accepté l'attestation → les prochains pointages envoient des assertions
///  - appAttestReset   : le serveur ne connaît plus la clé → nouvelle clé au prochain pointage
/// La position simulée est signalée par geolocator (Position.isMocked, iOS 15+).
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Rappels de pointage affichés même quand l'app est ouverte (flutter_local_notifications).
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PointeuseSecurity") else { return }
    let channel = FlutterMethodChannel(name: "pointeuse/security", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any]
      switch call.method {
      case "isVpnActive": result(AppDelegate.isVpnActive())
      case "isDeveloperMode": result(false)
      case "integrityToken": result(nil) // Android uniquement (Play Integrity)
      case "appAttest": AppAttest.proof(nonce: args?["nonce"] as? String, result: result)
      case "appAttestConfirm": AppAttest.confirm(); result(nil)
      case "appAttestReset": AppAttest.reset(); result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  static func isVpnActive() -> Bool {
    guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
          let scoped = settings["__SCOPED__"] as? [String: Any] else { return false }
    let markers = ["tap", "tun", "ppp", "ipsec", "utun"]
    return scoped.keys.contains { key in markers.contains { key.lowercased().hasPrefix($0) } }
  }
}

/// Apple App Attest : la clé privée reste dans la puce sécurisée du téléphone.
enum AppAttest {
  private static let keyIdKey = "pointeuse.appAttest.keyId"
  private static let attestedKey = "pointeuse.appAttest.attested"
  private static var defaults: UserDefaults { .standard }

  static func confirm() { defaults.set(true, forKey: attestedKey) }

  static func reset() {
    defaults.removeObject(forKey: keyIdKey)
    defaults.set(false, forKey: attestedKey)
  }

  /// Renvoie ["keyId", "attestation"] ou ["keyId", "assertion"] (base64), ou nil si indisponible.
  static func proof(nonce: String?, result: @escaping FlutterResult) {
    let service = DCAppAttestService.shared
    guard let nonce = nonce, service.isSupported else { result(nil); return }
    let clientDataHash = Data(SHA256.hash(data: Data(nonce.utf8)))
    let reply: ([String: String]?) -> Void = { value in DispatchQueue.main.async { result(value) } }

    func attest(_ keyId: String) {
      service.attestKey(keyId, clientDataHash: clientDataHash) { attestation, _ in
        if let attestation = attestation {
          reply(["keyId": keyId, "attestation": attestation.base64EncodedString()])
        } else {
          reset() // une clé ne s'atteste qu'une fois : on repartira d'une clé neuve
          reply(nil)
        }
      }
    }

    if let keyId = defaults.string(forKey: keyIdKey) {
      if defaults.bool(forKey: attestedKey) {
        service.generateAssertion(keyId, clientDataHash: clientDataHash) { assertion, _ in
          if let assertion = assertion {
            reply(["keyId": keyId, "assertion": assertion.base64EncodedString()])
          } else {
            reset() // clé perdue (restauration, réinstallation) : nouvelle attestation au prochain pointage
            reply(nil)
          }
        }
      } else {
        attest(keyId)
      }
      return
    }

    service.generateKey { keyId, _ in
      guard let keyId = keyId else { reply(nil); return }
      defaults.set(keyId, forKey: keyIdKey)
      defaults.set(false, forKey: attestedKey)
      attest(keyId)
    }
  }
}
