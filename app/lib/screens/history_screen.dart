import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../services/api.dart';
import '../theme.dart';
import 'place_map_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late Future<List<Punch>> _future = Api.instance.myPunches();

  Future<void> _reload() async {
    setState(() => _future = Api.instance.myPunches());
    await _future;
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        onRefresh: _reload,
        child: FutureBuilder<List<Punch>>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) return ListView(children: const [Padding(padding: EdgeInsets.all(24), child: Text('Impossible de charger vos pointages. Tirez vers le bas pour réessayer.'))]);
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final items = snap.data!;
            if (items.isEmpty) return ListView(children: const [Padding(padding: EdgeInsets.all(24), child: Text('Aucun pointage pour le moment.'))]);

            // Regroupement par jour
            final byDay = <String, List<Punch>>{};
            for (final p in items) {
              byDay.putIfAbsent(DateFormat('EEEE d MMMM', 'fr_FR').format(p.serverTs), () => []).add(p);
            }
            return ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                for (final e in byDay.entries) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(e.key, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  ...e.value.map((p) => PunchTile(punch: p)),
                ],
              ],
            );
          },
        ),
      );
}

class PunchTile extends StatelessWidget {
  final Punch punch;
  final bool showName;
  final Widget? trailing;
  final VoidCallback? onTap;
  const PunchTile({super.key, required this.punch, this.showName = false, this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = punch;
    return ExpansionTile(
      leading: CircleAvatar(
        backgroundColor: p.isIn ? AppColors.okSoft : AppColors.badSoft,
        child: Icon(p.isIn ? Icons.login : Icons.logout, color: p.isIn ? AppColors.ok : AppColors.bad, size: 20),
      ),
      title: Text('${showName ? '${p.employeeName ?? '—'} · ' : ''}${p.isIn ? 'Arrivée' : 'Départ'} ${DateFormat(showName ? 'dd/MM HH:mm' : 'HH:mm').format(p.serverTs)}'),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          StatusChip(p.status),
          if (p.manual) const StatusChip(PunchStatus.suspect, label: "Saisi par l'admin"),
          if (p.reviewDecision != null) StatusChip(p.reviewDecision == 'approved' ? PunchStatus.ok : PunchStatus.blocked, label: p.reviewDecision == 'approved' ? 'Validé' : 'Rejeté'),
        ]),
      ),
      trailing: trailing,
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (p.manual) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text("Saisi par l'administrateur. Motif : ${p.manualReason ?? '—'}", style: const TextStyle(fontStyle: FontStyle.italic))),
        if (p.siteLabel != null)
          Text('Site : ${p.siteLabel}', style: const TextStyle(fontWeight: FontWeight.w600))
        else if (p.siteDistanceM != null)
          Text('Hors site (${p.siteDistanceM} m du site le plus proche)', style: const TextStyle(fontWeight: FontWeight.w600)),
        if (p.lat != null) PlaceLine(lat: p.lat!, lng: p.lng!, accuracyM: p.accuracyM, address: p.address, title: showName ? (p.employeeName ?? 'Lieu du pointage') : 'Lieu du pointage'),
        if (p.flags.isNotEmpty) FlagList(p.flags),
        if (p.reviewNote != null && p.reviewNote!.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Note : ${p.reviewNote}', style: const TextStyle(fontStyle: FontStyle.italic))),
        if (onTap != null) Align(alignment: Alignment.centerRight, child: TextButton(onPressed: onTap, child: const Text('Détails'))),
      ],
    );
  }
}
