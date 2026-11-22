import 'dart:convert';

import 'package:http/http.dart' as http;

/// Adresse lisible d'une position (OpenStreetMap / Nominatim, appelé depuis le navigateur).
class PlaceService {
  static final _cache = <String, Future<String?>>{};

  static Future<String?> addressOf(double lat, double lng) {
    final key = '${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}';
    return _cache.putIfAbsent(key, () => _lookup(lat, lng).then((a) {
          if (a == null) _cache.remove(key); // nouvel essai à la prochaine demande
          return a;
        }));
  }

  static Future<String?> _lookup(double lat, double lng) async {
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {'format': 'jsonv2', 'lat': '$lat', 'lon': '$lng', 'zoom': '18', 'accept-language': 'fr'});
      final r = await http.get(uri).timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) return (jsonDecode(r.body) as Map)['display_name'] as String?;
    } catch (_) {}
    return null;
  }
}
