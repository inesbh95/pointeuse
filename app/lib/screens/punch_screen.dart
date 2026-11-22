import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../services/api.dart';
import '../services/device_security.dart';
import '../services/location_service.dart';
import '../services/place_service.dart';
import '../services/reminder_service.dart';
import '../theme.dart';
import 'face_capture_screen.dart';
import 'place_map_screen.dart';

class PunchScreen extends StatefulWidget {
  final Profile profile;
  const PunchScreen({super.key, required this.profile});
  @override
  State<PunchScreen> createState() => _PunchScreenState();
}

class _PunchScreenState extends State<PunchScreen> {
  final _api = Api.instance;
  Punch? _last;
  bool _loadingLast = true;
  String? _step; // étape en cours affichée pendant l'envoi
  PunchResult? _result;
  String? _resultType;
  Fix? _resultFix; // relevé GPS le plus précis envoyé, pour afficher le lieu exact
  String? _error;
  late Timer _clock;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) => setState(() => _now = DateTime.now()));
    _loadLast();
  }

  @override
  void dispose() {
    _clock.cancel();
    super.dispose();
  }

  Future<void> _loadLast() async {
    try {
      final p = await _api.lastValidPunchToday();
      if (mounted) setState(() => _last = p);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _loadingLast = false);
    }
  }

  Future<void> _punch(String type) async {
    setState(() {
      _error = null;
      _result = null;
      _step = 'Localisation et vérification du réseau…';
    });

    // 1. Contrôles lancés en parallèle pendant la vérification du visage
    final challengeF = _api.challenge();
    final fixesF = LocationService.collect();
    final deviceF = DeviceSecurity.describe();
    // Évite les erreurs « non gérées » si l'utilisateur abandonne
    challengeF.ignore();
    fixesF.ignore();

    // 2. Visage + épreuves de présence
    final capture = await Navigator.push<CaptureResult>(
      context,
      MaterialPageRoute(builder: (_) => const FaceCaptureScreen(title: 'Vérification du visage')),
    );
    if (!mounted) return;
    if (capture == null || capture.captures.isEmpty) {
      setState(() => _step = null);
      return;
    }

    try {
      setState(() => _step = 'Relevé de la position GPS…');
      final fixes = await fixesF;
      setState(() => _step = 'Vérification de l\'appareil…');
      final challenge = await challengeF;
      final results = await Future.wait([
        deviceF,
        DeviceSecurity.integrityToken(challenge.nonce), // Android : Google Play Integrity
        DeviceSecurity.appAttest(challenge.nonce), // iPhone : Apple App Attest
      ]);
      final device = results[0] as Map<String, dynamic>;
      final integrityToken = results[1] as String?;
      final iosProof = results[2] as Map<String, String>?;

      setState(() => _step = 'Envoi de la photo…');
      // Adresse trouvée par le téléphone (le serveur l'utilise si sa propre recherche échoue).
      final best = fixes.isEmpty ? null : fixes.reduce((a, b) => a.acc <= b.acc ? a : b);
      final addressF = best == null
          ? Future<String?>.value(null)
          : PlaceService.addressOf(best.lat, best.lng)
              .timeout(const Duration(seconds: 4), onTimeout: () => null)
              .catchError((_) => null);
      final photoPath = await _api.uploadPhoto(capture.captures.first.jpeg);
      final deviceAddress = await addressF;

      setState(() => _step = 'Contrôles du serveur…');
      final res = await _api.punch({
        'challengeId': challenge.id,
        'type': type,
        'deviceTs': DateTime.now().millisecondsSinceEpoch,
        'fixes': fixes.map((f) => f.toJson()).toList(),
        'device': device,
        'integrityToken': integrityToken,
        if (iosProof != null) 'ios': iosProof,
        'embedding': capture.captures.first.embedding,
        'liveness': capture.liveness,
        'photoPath': photoPath,
        if (deviceAddress != null) 'deviceAddress': deviceAddress,
      });
      unawaited(DeviceSecurity.appAttestResult(iosProof, res.appAttest));
      setState(() {
        _result = res;
        _resultType = type;
        _resultFix = fixes.isEmpty ? null : fixes.reduce((a, b) => a.acc <= b.acc ? a : b);
      });
      await _loadLast();
      // Rappel déjà inutile pour ce pointage : on reprogramme sans lui.
      if (res.status != PunchStatus.blocked) unawaited(ReminderService.sync(widget.profile.companyId));
    } on LocationError catch (e) {
      setState(() => _error = e.message);
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Le pointage a échoué. Vérifiez internet et réessayez.');
    } finally {
      if (mounted) setState(() => _step = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final suggestIn = _last == null || !_last!.isIn;
    final busy = _step != null;
    return RefreshIndicator(
      onRefresh: _loadLast,
      child: ListView(padding: const EdgeInsets.all(20), children: [
        Text(DateFormat('HH:mm:ss').format(_now),
            style: t.displayMedium?.copyWith(fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()])),
        Text(DateFormat('EEEE d MMMM y', 'fr_FR').format(_now), style: t.titleMedium),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.today),
            title: Text(_loadingLast
                ? 'Chargement…'
                : _last == null
                    ? 'Pas encore pointé aujourd\'hui'
                    : '${_last!.isIn ? 'Arrivée' : 'Départ'} à ${DateFormat('HH:mm').format(_last!.serverTs)}'),
            subtitle: _last?.siteLabel != null ? Text(_last!.siteLabel!) : null,
          ),
        ),
        if (_last?.lat != null && _result == null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: PlaceLine(lat: _last!.lat!, lng: _last!.lng!, accuracyM: _last!.accuracyM, address: _last!.address),
          ),
        const SizedBox(height: 20),
        if (busy)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(children: [
                const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
                const SizedBox(width: 16),
                Expanded(child: Text(_step!, style: t.titleMedium)),
              ]),
            ),
          )
        else ...[
          _BigButton(
            label: 'Pointer mon arrivée',
            icon: Icons.login,
            color: AppColors.ok,
            highlighted: suggestIn,
            onPressed: () => _punch('in'),
          ),
          const SizedBox(height: 12),
          _BigButton(
            label: 'Pointer mon départ',
            icon: Icons.logout,
            color: AppColors.bad,
            highlighted: !suggestIn,
            onPressed: () => _punch('out'),
          ),
        ],
        const SizedBox(height: 20),
        if (_error != null)
          SoftCard(
            color: AppColors.badSoft,
            child: Padding(padding: const EdgeInsets.all(16), child: Text(_error!, style: const TextStyle(color: AppColors.bad))),
          ),
        if (_result != null) _ResultCard(result: _result!, type: _resultType!, fix: _resultFix),
        const SizedBox(height: 12),
        Text(
          'Avant de pointer : activez le GPS, coupez tout VPN, et placez-vous dans un endroit bien éclairé.',
          style: t.bodySmall,
        ),
      ]),
    );
  }
}

class _BigButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool highlighted;
  final VoidCallback onPressed;
  const _BigButton({required this.label, required this.icon, required this.color, required this.highlighted, required this.onPressed});

  @override
  Widget build(BuildContext context) => highlighted
      ? FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: color, minimumSize: const Size.fromHeight(72), textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          onPressed: onPressed,
          icon: Icon(icon),
          label: Text(label),
        )
      : OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: color, minimumSize: const Size.fromHeight(56)),
          onPressed: onPressed,
          icon: Icon(icon),
          label: Text(label),
        );
}

class _ResultCard extends StatelessWidget {
  final PunchResult result;
  final String type;
  final Fix? fix;
  const _ResultCard({required this.result, required this.type, this.fix});

  @override
  Widget build(BuildContext context) {
    final s = statusStyle(result.status);
    final what = type == 'in' ? 'Arrivée' : 'Départ';
    final title = switch (result.status) {
      PunchStatus.ok => '$what enregistré${type == 'in' ? 'e' : ''} à ${DateFormat('HH:mm').format(result.serverTime)}',
      PunchStatus.suspect => '$what enregistré${type == 'in' ? 'e' : ''}, à vérifier par l\'administrateur',
      PunchStatus.blocked => 'Pointage refusé',
    };
    return SoftCard(
      color: s.bg,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(s.icon, color: s.fg),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: TextStyle(color: s.fg, fontWeight: FontWeight.w700, fontSize: 16))),
          ]),
          if (result.siteLabel != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Site : ${result.siteLabel}')),
          if (fix != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: PlaceLine(lat: fix!.lat, lng: fix!.lng, accuracyM: fix!.acc, address: result.address, title: 'Mon pointage', onSoft: true),
            ),
          if (result.flags.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: FlagList(result.flags)),
          if (result.status == PunchStatus.blocked)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Corrigez le problème puis réessayez. La tentative est visible par l\'administrateur.', style: TextStyle(fontSize: 13)),
            ),
        ]),
      ),
    );
  }
}
