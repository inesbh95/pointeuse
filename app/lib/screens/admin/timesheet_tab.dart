import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models.dart';
import '../../services/api.dart';
import '../../theme.dart';
import 'corrections.dart';

/// Feuilles de temps : par employé, ses jours sur la période (arrivée, départ, heures, retard, statut).
/// Calcul fait par le serveur à partir des pointages et des horaires de l'entreprise (Réglages).
class TimesheetTab extends StatefulWidget {
  final Profile profile;
  const TimesheetTab({super.key, required this.profile});
  @override
  State<TimesheetTab> createState() => _TimesheetTabState();
}

enum _Period { thisWeek, lastWeek, thisMonth, lastMonth, custom }

class _TimesheetTabState extends State<TimesheetTab> {
  List<Company>? _companies;
  late String? _companyId = widget.profile.companyId;
  _Period _period = _Period.thisWeek;
  late DateTimeRange _range = _rangeOf(_Period.thisWeek);
  Future<List<TimesheetRow>>? _future;

  @override
  void initState() {
    super.initState();
    if (widget.profile.isSuperAdmin) {
      Api.instance.companies().then((c) => mounted ? setState(() => _companies = c) : null);
    }
    _load();
  }

  static DateTime _d(DateTime x) => DateTime(x.year, x.month, x.day);

  static DateTimeRange _rangeOf(_Period p) {
    final now = _d(DateTime.now());
    final monday = now.subtract(Duration(days: now.weekday - 1));
    return switch (p) {
      _Period.thisWeek => DateTimeRange(start: monday, end: now),
      _Period.lastWeek => DateTimeRange(start: monday.subtract(const Duration(days: 7)), end: monday.subtract(const Duration(days: 1))),
      _Period.thisMonth => DateTimeRange(start: DateTime(now.year, now.month, 1), end: now),
      _Period.lastMonth => DateTimeRange(start: DateTime(now.year, now.month - 1, 1), end: DateTime(now.year, now.month, 0)),
      _Period.custom => DateTimeRange(start: monday, end: now),
    };
  }

  void _load() => setState(() => _future = Api.instance.timesheet(_range.start, _range.end, companyId: _companyId));

  Future<void> _openAbsences() async {
    final name = _companies?.where((c) => c.id == _companyId).firstOrNull?.name ?? widget.profile.companyName;
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => AbsencesScreen(companyId: _companyId!, companyName: name, range: _range)),
    );
    if (changed == true) _load();
  }

  Future<void> _onDay(TimesheetRow r) async {
    if (r.companyId == null) return;
    if (await showDayActions(context, r)) {
      _load();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Feuille de temps mise à jour.')));
    }
  }

  Future<void> _choose(_Period p) async {
    if (p == _Period.custom) {
      final r = await showDateRangePicker(
        context: context,
        firstDate: DateTime(DateTime.now().year - 3),
        lastDate: DateTime.now(),
        initialDateRange: _range,
        helpText: 'Période',
        builder: (ctx, child) => Center(
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420, maxHeight: 640), child: child),
        ),
      );
      if (r == null) return;
      _range = DateTimeRange(start: _d(r.start), end: _d(r.end));
    } else {
      _range = _rangeOf(p);
    }
    _period = p;
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('d MMM', 'fr_FR');
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_companies != null) ...[
            DropdownButtonFormField<String?>(
              initialValue: _companyId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Entreprise', prefixIcon: Icon(Icons.apartment_outlined), isDense: true),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('Toutes les entreprises')),
                for (final c in _companies!) DropdownMenuItem<String?>(value: c.id, child: Text(c.name)),
              ],
              onChanged: (v) {
                _companyId = v;
                _load();
              },
            ),
            const SizedBox(height: 10),
          ],
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final (p, label) in const [
              (_Period.thisWeek, 'Cette semaine'),
              (_Period.lastWeek, 'Semaine dernière'),
              (_Period.thisMonth, 'Ce mois'),
              (_Period.lastMonth, 'Mois dernier'),
              (_Period.custom, 'Autre période…'),
            ])
              ChoiceChip(label: Text(label), selected: _period == p, onSelected: (_) => _choose(p)),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: Text('Du ${fmt.format(_range.start)} au ${fmt.format(_range.end)} ${_range.end.year}', style: Theme.of(context).textTheme.bodySmall)),
            TextButton.icon(
              onPressed: _companyId == null ? null : _openAbsences,
              icon: const Icon(Icons.event_available, size: 18),
              label: Text(_companyId == null ? 'Absences : choisissez une entreprise' : 'Absences et jours fériés'),
            ),
          ]),
          Text('Touchez un jour pour ajouter un pointage oublié ou une absence justifiée.', style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
      Expanded(
        child: FutureBuilder<List<TimesheetRow>>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) return Padding(padding: const EdgeInsets.all(24), child: Text('${snap.error}'));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final rows = snap.data!;
            if (rows.isEmpty) {
              return const Padding(padding: EdgeInsets.all(24), child: Text('Aucune donnée sur cette période.'));
            }
            // Regroupement par employé (le serveur renvoie trié par jour puis par nom).
            final byUser = <String, List<TimesheetRow>>{};
            for (final r in rows) {
              byUser.putIfAbsent(r.userId, () => []).add(r);
            }
            final users = byUser.values.toList()..sort((a, b) => a.first.fullName.toLowerCase().compareTo(b.first.fullName.toLowerCase()));
            return ListView(padding: const EdgeInsets.fromLTRB(8, 4, 8, 24), children: [
              _Totals(rows: rows, employees: users.length),
              for (final days in users) _EmployeeCard(days: days, showCompany: widget.profile.isSuperAdmin && _companyId == null, onDay: _onDay),
            ]);
          },
        ),
      ),
    ]);
  }
}

/// Chiffres clés de la période, toutes personnes confondues.
class _Totals extends StatelessWidget {
  final List<TimesheetRow> rows;
  final int employees;
  const _Totals({required this.rows, required this.employees});

  @override
  Widget build(BuildContext context) {
    final worked = rows.fold<int>(0, (s, r) => s + r.workedMin);
    final lates = rows.where((r) => r.lateMin > 0).length;
    final absents = rows.where((r) => r.status == 'absent').length;
    final justified = rows.where((r) => r.status == 'justifie').length;
    final missing = rows.where((r) => r.status == 'sortie_manquante' || r.status == 'entree_manquante').length;
    final ot = rows.fold<int>(0, (s, r) => s + r.overtimeMin);
    Widget tile(String value, String label, Color? color) => Container(
          width: 150,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value, style: Theme.of(context).textTheme.titleLarge?.copyWith(color: color, fontWeight: FontWeight.w700)),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ]),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
      child: Wrap(spacing: 8, runSpacing: 8, children: [
        tile('$employees', employees > 1 ? 'personnes' : 'personne', null),
        tile(TimesheetRow.hm(worked), 'travaillées', null),
        tile('$lates', lates > 1 ? 'retards' : 'retard', lates > 0 ? AppColors.warn : null),
        tile('$absents', absents > 1 ? 'absences injustifiées' : 'absence injustifiée', absents > 0 ? AppColors.bad : null),
        tile('$justified', justified > 1 ? 'absences justifiées' : 'absence justifiée', null),
        tile('$missing', 'oublis de pointage', missing > 0 ? AppColors.warn : null),
        tile(TimesheetRow.hm(ot), 'heures sup', null),
      ]),
    );
  }
}

class _EmployeeCard extends StatelessWidget {
  final List<TimesheetRow> days;
  final bool showCompany;
  final ValueChanged<TimesheetRow> onDay;
  const _EmployeeCard({required this.days, required this.showCompany, required this.onDay});

  @override
  Widget build(BuildContext context) {
    final f = days.first;
    final worked = days.fold<int>(0, (s, r) => s + r.workedMin);
    final lateDays = days.where((r) => r.lateMin > 0).toList();
    final lateTotal = lateDays.fold<int>(0, (s, r) => s + r.lateMin);
    final absents = days.where((r) => r.status == 'absent').length;
    final justified = days.where((r) => r.status == 'justifie').length;
    final missing = days.where((r) => r.status == 'sortie_manquante' || r.status == 'entree_manquante').length;
    final ot = days.fold<int>(0, (s, r) => s + r.overtimeMin);
    final summary = [
      '${TimesheetRow.hm(worked)} travaillées',
      if (lateDays.isNotEmpty) '${lateDays.length} retard${lateDays.length > 1 ? 's' : ''} ($lateTotal min)',
      if (absents > 0) '$absents absence${absents > 1 ? 's' : ''} injustifiée${absents > 1 ? 's' : ''}',
      if (justified > 0) '$justified justifiée${justified > 1 ? 's' : ''}',
      if (missing > 0) '$missing oubli${missing > 1 ? 's' : ''}',
      if (ot > 0) '${TimesheetRow.hm(ot)} sup',
    ].join(' · ');
    return Card(
      child: ExpansionTile(
        leading: CircleAvatar(child: Text(f.fullName.isEmpty ? '?' : f.fullName[0].toUpperCase())),
        title: Text([f.fullName, if (f.matricule != null) f.matricule, if (showCompany) f.companyName].whereType<String>().join(' · ')),
        subtitle: Text(summary),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [for (final r in days) _DayLine(r: r, onTap: () => onDay(r))],
      ),
    );
  }
}

class _DayLine extends StatelessWidget {
  final TimesheetRow r;
  final VoidCallback onTap;
  const _DayLine({required this.r, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final hm = DateFormat('HH:mm');
    final (color, icon) = switch (r.status) {
      'complet' => (r.lateMin > 0 ? AppColors.warn : AppColors.ok, r.lateMin > 0 ? Icons.schedule : Icons.check_circle_outline),
      'absent' => (AppColors.bad, Icons.event_busy),
      'justifie' => (AppColors.ok, Icons.event_available),
      'en_cours' => (Theme.of(context).colorScheme.primary, Icons.timelapse),
      _ => (AppColors.warn, Icons.error_outline),
    };
    final details = [
      '${r.firstIn == null ? '—' : hm.format(r.firstIn!)} → ${r.lastOut == null ? '—' : hm.format(r.lastOut!)}',
      if (r.status != 'absent' && r.status != 'justifie') TimesheetRow.hm(r.workedMin),
      if (r.absence != null && r.status != 'justifie') Absence.label(r.absence),
      if (r.manual > 0) "saisi par l'admin",
      if (r.lateMin > 0) 'retard ${r.lateMin} min',
      if (r.overtimeMin > 0) '+${TimesheetRow.hm(r.overtimeMin)} sup',
      if (r.expectedMin == 0 && r.status != 'absent' && r.status != 'justifie') 'jour non travaillé',
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        SizedBox(width: 92, child: Text(DateFormat('EEE d MMM', 'fr_FR').format(r.day), style: const TextStyle(fontWeight: FontWeight.w600))),
        Expanded(child: Text(details)),
        const SizedBox(width: 8),
        Text(r.statusLabel, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12)),
      ]),
      ),
    );
  }
}
