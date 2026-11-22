import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/place_service.dart';
import '../theme.dart';

/// Lieu d'un pointage : adresse (celle du serveur, sinon trouvée par le téléphone).
/// Un appui ouvre la carte avec le bonhomme à l'endroit exact.
class PlaceLine extends StatelessWidget {
  final double lat, lng;
  final double? accuracyM;
  final String? address;
  final String title;
  final bool onSoft; // posé sur une SoftCard : couleurs fixes, lisibles même en mode sombre
  const PlaceLine({super.key, required this.lat, required this.lng, this.accuracyM, this.address, this.title = 'Lieu du pointage', this.onSoft = false});

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
        future: address != null ? Future.value(address) : PlaceService.addressOf(lat, lng),
        builder: (context, snap) {
          final text = snap.data ?? (snap.connectionState == ConnectionState.done ? '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}' : 'Recherche de l\'adresse…');
          return InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => PlaceMapScreen(lat: lat, lng: lng, accuracyM: accuracyM, address: snap.data, title: title)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.person_pin_circle, color: AppColors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(text),
                    Text(
                      'Voir sur la carte${accuracyM != null ? ' · précision ± ${accuracyM!.round()} m' : ''}',
                      style: TextStyle(fontSize: 12, color: onSoft ? AppColors.brand : Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600),
                    ),
                  ]),
                ),
              ]),
            ),
          );
        },
      );
}

/// Carte OpenStreetMap avec un bonhomme à l'endroit du pointage et le cercle de précision du GPS.
class PlaceMapScreen extends StatelessWidget {
  final double lat, lng;
  final double? accuracyM;
  final String? address;
  final String title;
  const PlaceMapScreen({super.key, required this.lat, required this.lng, this.accuracyM, this.address, this.title = 'Lieu du pointage'});

  @override
  Widget build(BuildContext context) {
    final at = LatLng(lat, lng);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: FlutterMap(
        options: MapOptions(initialCenter: at, initialZoom: 18),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.pointeuse.simple',
          ),
          if (accuracyM != null)
            CircleLayer(circles: [
              CircleMarker(
                point: at,
                radius: accuracyM!,
                useRadiusInMeter: true,
                color: AppColors.accent.withValues(alpha: 0.15),
                borderColor: AppColors.accent,
                borderStrokeWidth: 1.5,
              ),
            ]),
          MarkerLayer(markers: [
            Marker(
              point: at,
              width: 56,
              height: 56,
              alignment: Alignment.topCenter,
              child: const Icon(Icons.emoji_people, color: AppColors.brand, size: 56, shadows: [Shadow(color: Colors.white, blurRadius: 6)]),
            ),
          ]),
          RichAttributionWidget(alignment: AttributionAlignment.bottomLeft, attributions: [
            TextSourceAttribution('© contributeurs OpenStreetMap', onTap: () => launchUrl(Uri.parse('https://openstreetmap.org/copyright'))),
          ]),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FutureBuilder<String?>(
              future: address != null ? Future.value(address) : PlaceService.addressOf(lat, lng),
              builder: (_, s) => Text(s.data ?? '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}', style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            Text(
              '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}${accuracyM != null ? ' · précision ± ${accuracyM!.round()} m' : ''}',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.open_in_new),
              label: const Text('Ouvrir dans Google Maps'),
              onPressed: () => launchUrl(Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng'), mode: LaunchMode.externalApplication),
            ),
          ]),
        ),
      ),
    );
  }
}
