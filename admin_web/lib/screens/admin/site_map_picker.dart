import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/location_service.dart';
import '../../theme.dart';

/// Emplacement choisi sur la carte, avec l'adresse trouvée par la recherche s'il y en a une.
class PickedPlace {
  final LatLng point;
  final String? address;
  const PickedPlace(this.point, this.address);
}

/// Carte OpenStreetMap : on touche la carte pour placer le site, le cercle montre le rayon autorisé.
/// Recherche d'adresse par Nominatim (OpenStreetMap), sans clé.
class SiteMapPicker extends StatefulWidget {
  final LatLng? initial;
  final int radiusM;
  const SiteMapPicker({super.key, this.initial, required this.radiusM});

  @override
  State<SiteMapPicker> createState() => _SiteMapPickerState();
}

class _SiteMapPickerState extends State<SiteMapPicker> {
  static const _tunis = LatLng(36.8065, 10.1815);
  static const _userAgent = 'pointeuse-missions/1.0';

  final _map = MapController();
  final _search = TextEditingController();
  LatLng? _point;
  String? _address;
  List<({String label, LatLng point})> _results = [];
  bool _searching = false, _locating = false;
  String? _info;

  @override
  void initState() {
    super.initState();
    _point = widget.initial;
    if (_point == null) _here();
  }

  Future<void> _here() async {
    setState(() => _locating = true);
    try {
      final p = await LocationService.current();
      final at = LatLng(p.latitude, p.longitude);
      if (!mounted) return;
      setState(() {
        _point = at;
        _address = null;
        _info = 'Votre position (± ${p.accuracy.round()} m)';
      });
      _map.move(at, 17);
    } catch (e) {
      if (mounted) setState(() => _info = e.toString());
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _find() async {
    final q = _search.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _results = [];
      _info = null;
    });
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/search', {'q': q, 'format': 'jsonv2', 'limit': '6', 'accept-language': 'fr'});
      final r = await http.get(uri, headers: {'User-Agent': _userAgent}).timeout(const Duration(seconds: 10));
      final list = (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
      setState(() {
        _results = [
          for (final m in list) (label: m['display_name'] as String, point: LatLng(double.parse(m['lat']), double.parse(m['lon']))),
        ];
        if (_results.isEmpty) _info = 'Aucune adresse trouvée.';
      });
    } catch (_) {
      setState(() => _info = 'Recherche impossible. Vérifiez internet.');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _choose(({String label, LatLng point}) r) {
    setState(() {
      _point = r.point;
      _address = r.label;
      _results = [];
      _info = null;
    });
    _map.move(r.point, 17);
  }

  @override
  Widget build(BuildContext context) {
    final point = _point;
    return Scaffold(
      appBar: AppBar(title: const Text('Emplacement du site')),
      body: Stack(children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: point ?? _tunis,
            initialZoom: point != null ? 17 : 12,
            onTap: (_, at) => setState(() {
              _point = at;
              _address = null;
              _info = null;
            }),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.pointeuse.pointeuse',
            ),
            if (point != null) ...[
              CircleLayer(circles: [
                CircleMarker(
                  point: point,
                  radius: widget.radiusM.toDouble(),
                  useRadiusInMeter: true,
                  color: AppColors.accent.withValues(alpha: 0.18),
                  borderColor: AppColors.accent,
                  borderStrokeWidth: 2,
                ),
              ]),
              MarkerLayer(markers: [
                Marker(
                  point: point,
                  width: 44,
                  height: 44,
                  alignment: Alignment.topCenter,
                  child: const Icon(Icons.location_on, color: AppColors.bad, size: 44),
                ),
              ]),
            ],
            RichAttributionWidget(alignment: AttributionAlignment.bottomLeft, attributions: [
              TextSourceAttribution('© contributeurs OpenStreetMap', onTap: () => launchUrl(Uri.parse('https://openstreetmap.org/copyright'))),
            ]),
          ],
        ),
        Positioned(
          left: 12, right: 12, top: 12,
          child: Column(children: [
            Material(
              elevation: 3,
              borderRadius: BorderRadius.circular(12),
              child: TextField(
                controller: _search,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _find(),
                decoration: InputDecoration(
                  hintText: 'Rechercher une adresse',
                  filled: true,
                  fillColor: Theme.of(context).colorScheme.surface,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  suffixIcon: _searching
                      ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                      : IconButton(icon: const Icon(Icons.search), onPressed: _find),
                ),
              ),
            ),
            if (_results.isNotEmpty)
              Material(
                elevation: 3,
                borderRadius: BorderRadius.circular(12),
                child: ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: [
                    for (final r in _results)
                      ListTile(dense: true, leading: const Icon(Icons.place_outlined), title: Text(r.label, maxLines: 2, overflow: TextOverflow.ellipsis), onTap: () => _choose(r)),
                  ],
                ),
              ),
          ]),
        ),
      ]),
      floatingActionButton: FloatingActionButton.small(
        onPressed: _locating ? null : _here,
        tooltip: 'Ma position',
        child: _locating ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.my_location),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
              _info ?? (point == null ? 'Touchez la carte pour placer le site.' : _address ?? '${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: point == null ? null : () => Navigator.pop(context, PickedPlace(point, _address)),
              child: const Text('Valider cet emplacement'),
            ),
          ]),
        ),
      ),
    );
  }
}
