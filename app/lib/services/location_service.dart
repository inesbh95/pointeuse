import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../config.dart';
import '../models.dart';

class LocationError implements Exception {
  final String message;
  LocationError(this.message);
  @override
  String toString() => message;
}

/// Relève plusieurs positions GPS fraîches. Le serveur s'en sert pour détecter une position figée,
/// et chaque relevé indique si le téléphone le signale comme simulé (isMocked).
class LocationService {
  static Future<void> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw LocationError('La localisation est désactivée. Activez-la dans les réglages du téléphone.');
    }
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    if (p == LocationPermission.denied) throw LocationError('Autorisez la localisation pour pointer.');
    if (p == LocationPermission.deniedForever) {
      throw LocationError('Localisation refusée définitivement. Autorisez-la dans les réglages de l\'application.');
    }
  }

  static Future<List<Fix>> collect({int wanted = Config.gpsFixes, Duration window = Config.gpsWindow}) async {
    await ensurePermission();
    final fixes = <Fix>[];
    final done = Completer<void>();
    final sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 0),
    ).listen((p) {
      fixes.add(Fix(
        lat: p.latitude,
        lng: p.longitude,
        acc: p.accuracy,
        ts: p.timestamp.millisecondsSinceEpoch,
        mocked: p.isMocked,
      ));
      if (fixes.length >= wanted && !done.isCompleted) done.complete();
    }, onError: (Object e) {
      if (!done.isCompleted) done.complete();
    });

    await done.future.timeout(window, onTimeout: () {});
    await sub.cancel();

    if (fixes.isEmpty) {
      // Dernier recours : une position unique
      try {
        final p = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, timeLimit: Duration(seconds: 8)),
        );
        fixes.add(Fix(lat: p.latitude, lng: p.longitude, acc: p.accuracy, ts: p.timestamp.millisecondsSinceEpoch, mocked: p.isMocked));
      } catch (_) {
        throw LocationError('Position introuvable. Sortez à l\'extérieur ou près d\'une fenêtre et réessayez.');
      }
    }
    return fixes;
  }

  /// Une position précise, pour enregistrer un site client depuis le terrain.
  static Future<Position> current() async {
    await ensurePermission();
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, timeLimit: Duration(seconds: 15)),
    );
  }
}
