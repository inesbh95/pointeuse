import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../config.dart';

/// Informations de sécurité lues sur le téléphone (code natif : MainActivity.kt / AppDelegate.swift).
class DeviceSecurity {
  static const _channel = MethodChannel('pointeuse/security');

  /// Un VPN est-il actif sur le téléphone ? (détection locale, indépendante de l'adresse IP)
  static Future<bool?> isVpnActive() async {
    try {
      return await _channel.invokeMethod<bool>('isVpnActive');
    } catch (_) {
      return null;
    }
  }

  /// Options pour les développeurs activées (Android) : préalable à la fausse localisation.
  static Future<bool?> isDeveloperMode() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isDeveloperMode');
    } catch (_) {
      return null;
    }
  }

  /// Jeton Google Play Integrity lié au défi du serveur. Null sur iOS ou si indisponible.
  static Future<String?> integrityToken(String nonce) async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('integrityToken', {
        'nonce': nonce,
        'cloudProjectNumber': Config.cloudProjectNumber,
      });
    } catch (_) {
      return null;
    }
  }

  /// Preuve Apple App Attest liée au défi du serveur (iPhone uniquement).
  /// {keyId, attestation} au premier pointage, puis {keyId, assertion}. Null si indisponible.
  static Future<Map<String, String>?> appAttest(String nonce) async {
    if (!Platform.isIOS) return null;
    try {
      return await _channel.invokeMapMethod<String, String>('appAttest', {'nonce': nonce});
    } catch (_) {
      return null;
    }
  }

  /// Réponse du serveur à la preuve App Attest : 'ok' (attestation acceptée) ou 'reattest' (clé inconnue).
  static Future<void> appAttestResult(Map<String, String>? proof, String? serverAnswer) async {
    if (!Platform.isIOS || proof == null) return;
    try {
      if (serverAnswer == 'reattest') {
        await _channel.invokeMethod('appAttestReset');
      } else if (serverAnswer == 'ok' && proof.containsKey('attestation')) {
        await _channel.invokeMethod('appAttestConfirm');
      }
    } catch (_) {}
  }

  /// Description de l'appareil envoyée avec chaque pointage.
  static Future<Map<String, dynamic>> describe() async {
    final results = await Future.wait([
      isVpnActive(),
      isDeveloperMode(),
      FlutterTimezone.getLocalTimezone().then<String?>((v) => v.identifier).catchError((_) => null),
      PackageInfo.fromPlatform().then<String?>((p) => '${p.version}+${p.buildNumber}').catchError((_) => null),
      _model(),
    ]);
    final model = results[4] as ({String model, String os})?;
    return {
      'platform': Platform.isIOS ? 'ios' : 'android',
      'vpnActive': results[0],
      'devMode': results[1],
      'tz': results[2],
      'appVersion': results[3],
      'model': model?.model,
      'osVersion': model?.os,
    };
  }

  static Future<({String model, String os})?> _model() async {
    try {
      final info = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await info.androidInfo;
        return (model: '${a.manufacturer} ${a.model}', os: 'Android ${a.version.release}');
      }
      final i = await info.iosInfo;
      return (model: i.utsname.machine, os: 'iOS ${i.systemVersion}');
    } catch (_) {
      return null;
    }
  }
}
