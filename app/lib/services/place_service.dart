import 'dart:convert';
import 'dart:ui' show Locale;

import 'package:geocoding/geocoding.dart';
import 'package:http/http.dart' as http;

/// Adresse lisible d'une position, trouvée par le téléphone.
/// Le géocodeur du système (Google sur Android, Apple sur iOS) d'abord, OpenStreetMap en secours.
class PlaceService {
  static final _geocoder = Geocoding(locale: const Locale('fr'));
  static final _cache = <String, Future<String?>>{};
  static final _plusCode = RegExp(r'^[23456789CFGHJMPQRVWX]{2,8}\+[23456789CFGHJMPQRVWX]{0,3}$', caseSensitive: false);

  static Future<String?> addressOf(double lat, double lng) {
    final key = '${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}';
    return _cache.putIfAbsent(key, () => _lookup(lat, lng).then((a) {
          if (a == null) _cache.remove(key); // nouvel essai à la prochaine demande
          return a;
        }));
  }

  static Future<String?> _lookup(double lat, double lng) async {
    try {
      final marks = await _geocoder.placemarkFromCoordinates(lat, lng).timeout(const Duration(seconds: 8));
      if (marks.isNotEmpty) {
        final m = marks.first;
        // Le champ « rue » contient parfois un Plus Code et la ville (« RQJ4+GW6, Sakiet Ezzit, Tunisie ») :
        // on découpe, on retire les Plus Codes et les doublons.
        final parts = <String>[];
        for (final field in [m.street, m.subLocality, m.locality, m.administrativeArea, m.country]) {
          for (final s in (field ?? '').split(',').map((s) => s.trim())) {
            if (s.isEmpty || _plusCode.hasMatch(s) || parts.any((p) => p.toLowerCase() == s.toLowerCase())) continue;
            parts.add(s);
          }
        }
        if (parts.isNotEmpty) return parts.join(', ');
      }
    } catch (_) {}
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {'format': 'jsonv2', 'lat': '$lat', 'lon': '$lng', 'zoom': '18', 'accept-language': 'fr'});
      final r = await http.get(uri, headers: {'User-Agent': 'pointage-simple/1.0'}).timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) return (jsonDecode(r.body) as Map)['display_name'] as String?;
    } catch (_) {}
    return null;
  }
}
