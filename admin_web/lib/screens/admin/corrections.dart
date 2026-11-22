import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../models.dart';
import '../../services/api.dart';
import '../../theme.dart';

/// Corrections de l'administrateur depuis les feuilles de temps :
/// pointage oublié (saisi à la main, avec motif) et absences justifiées / jours fériés.

DateTime _dayOnly(DateTime x) => DateTime(x.year, x.month, x.day);
String _dmy(DateTime d) => DateFormat('EEE d MMM yyyy', 'fr_FR').format(d);

Future<TimeOfDay?> _pickTime(BuildContext context, TimeOfDay initial, String help) => showTimePicker(
      context: context,
      initialTime: initial,
      helpText: help,
      builder: (ctx, child) => MediaQuery(data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true), child: child!),
    );

String _hhmm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Actions proposées en touchant un jour de la feuille de temps.
Future<bool> showDayActions(BuildContext context, TimesheetRow r) async {
  final changed = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        ListTile(
          title: Text(r.fullName, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text('${_dmy(r.day)} · ${r.statusLabel}'),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.more_time),
          title: Text(switch (r.status) {
            'sortie_manquante' => 'Ajouter la sortie oubliée',
            'entree_manquante' => "Ajouter l'entrée oubliée",
            'absent' => 'Ajouter les pointages oubliés',
            _ => 'Ajouter un pointage',
          }),
          subtitle: const Text("Signalé « saisi par l'admin », avec votre motif"),
          onTap: () async => Navigator.pop(ctx, await showDialog<bool>(context: ctx, builder: (_) => ManualPunchDialog(row: r))),
        ),
        if (r.punches == 0 || r.absence != null)
          ListTile(
            leading: const Icon(Icons.event_available),
            title: Text(r.absence == null ? 'Déclarer une absence justifiée' : 'Autre absence justifiée'),
            subtitle: const Text('Congé, maladie, mission…'),
            onTap: () async => Navigator.pop(
              ctx,
              await showDialog<bool>(
                context: ctx,
                builder: (_) => AbsenceDialog(companyId: r.companyId!, employees: [(id: r.userId, name: r.fullName)], initialDay: r.day),
              ),
            ),
          ),
        const SizedBox(height: 8),
      ]),
    ),
  );
  return changed == true;
}

/// Saisie d'un ou deux pointages oubliés pour un jour donné.
class ManualPunchDialog extends StatefulWidget {
  final TimesheetRow row;
  const ManualPunchDialog({super.key, required this.row});
  @override
  State<ManualPunchDialog> createState() => _ManualPunchDialogState();
}

class _ManualPunchDialogState extends State<ManualPunchDialog> {
  late bool _withIn = widget.row.status != 'sortie_manquante' && widget.row.status != 'en_cours' && widget.row.status != 'complet';
  late bool _withOut = widget.row.status != 'entree_manquante';
  late TimeOfDay _in = _defaultIn();
  late TimeOfDay _out = _defaultOut();
  final _reason = TextEditingController();
  bool _busy = false;
  String? _error;

  TimeOfDay _defaultIn() {
    final r = widget.row;
    if (r.lastOut != null && r.expectedMin > 0) return TimeOfDay.fromDateTime(r.lastOut!.subtract(Duration(minutes: r.expectedMin)));
    return const TimeOfDay(hour: 8, minute: 0);
  }

  TimeOfDay _defaultOut() {
    final r = widget.row;
    if (r.firstIn != null && r.expectedMin > 0) return TimeOfDay.fromDateTime(r.firstIn!.add(Duration(minutes: r.expectedMin)));
    return const TimeOfDay(hour: 17, minute: 0);
  }

  DateTime _at(TimeOfDay t) => DateTime(widget.row.day.year, widget.row.day.month, widget.row.day.day, t.hour, t.minute);

  Future<void> _save() async {
    final reason = _reason.text.trim();
    if (!_withIn && !_withOut) return setState(() => _error = 'Choisissez au moins un pointage.');
    if (reason.length < 3) return setState(() => _error = 'Indiquez un motif (ex. « oubli confirmé par le chef d\'équipe »).');
    if (_withIn && _withOut && !_at(_out).isAfter(_at(_in))) return setState(() => _error = "La sortie doit être après l'entrée.");
    final now = DateTime.now();
    if ((_withIn && _at(_in).isAfter(now)) || (_withOut && _at(_out).isAfter(now))) {
      return setState(() => _error = 'Impossible de saisir une heure future.');
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_withIn) await Api.instance.addManualPunch(userId: widget.row.userId, type: 'in', at: _at(_in), reason: reason);
      if (_withOut) await Api.instance.addManualPunch(userId: widget.row.userId, type: 'out', at: _at(_out), reason: reason);
      if (mounted) Navigator.pop(context, true);
    } on ApiError catch (e) {
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  Widget _line(String label, bool on, ValueChanged<bool> toggle, TimeOfDay t, ValueChanged<TimeOfDay> set) => Row(children: [
        Checkbox(value: on, onChanged: (v) => setState(() => toggle(v ?? false))),
        Expanded(child: Text(label)),
        TextButton(
          onPressed: on
              ? () async {
                  final v = await _pickTime(context, t, label);
                  if (v != null) setState(() => set(v));
                }
              : null,
          child: Text(_hhmm(t), style: const TextStyle(fontSize: 18)),
        ),
      ]);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Pointage oublié'),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${widget.row.fullName} · ${_dmy(widget.row.day)}'),
          const SizedBox(height: 8),
          _line('Entrée', _withIn, (v) => _withIn = v, _in, (v) => _in = v),
          _line('Sortie', _withOut, (v) => _withOut = v, _out, (v) => _out = v),
          const SizedBox(height: 8),
          TextField(
            controller: _reason,
            maxLength: 300,
            decoration: const InputDecoration(labelText: 'Motif (obligatoire)', hintText: "ex. oubli confirmé par le chef d'équipe"),
          ),
          Text(
            "Ces pointages restent marqués « saisi par l'admin » avec votre nom et le motif, dans l'app, l'Excel et l'API.",
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        ]),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Annuler')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Enregistrer')),
      ],
    );
  }
}

/// Déclaration d'une absence justifiée. [employees] vide ou avec plusieurs choix : liste déroulante,
/// avec « Toute l'entreprise » pour les jours fériés.
class AbsenceDialog extends StatefulWidget {
  final String companyId;
  final List<({String id, String name})> employees;
  final DateTime? initialDay;
  final bool allowCompany;
  const AbsenceDialog({super.key, required this.companyId, required this.employees, this.initialDay, this.allowCompany = false});
  @override
  State<AbsenceDialog> createState() => _AbsenceDialogState();
}

class _AbsenceDialogState extends State<AbsenceDialog> {
  late String? _userId = widget.employees.length == 1 ? widget.employees.first.id : null;
  late String _kind = widget.allowCompany && _userId == null ? 'ferie' : 'conge_paye';
  late DateTimeRange _range = () {
    final d = _dayOnly(widget.initialDay ?? DateTime.now());
    return DateTimeRange(start: d, end: d);
  }();
  final _note = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _pickRange() async {
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(DateTime.now().year - 1),
      lastDate: DateTime(DateTime.now().year + 1, 12, 31),
      initialDateRange: _range,
      helpText: "Période d'absence",
      builder: (ctx, child) => Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420, maxHeight: 640), child: child)),
    );
    if (r != null) setState(() => _range = DateTimeRange(start: _dayOnly(r.start), end: _dayOnly(r.end)));
  }

  Future<void> _save() async {
    if (_userId == null && !widget.allowCompany) return setState(() => _error = 'Choisissez un employé.');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.instance.addAbsence(
        companyId: widget.companyId, userId: _userId, kind: _kind, from: _range.start, to: _range.end,
        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
      );
      if (mounted) Navigator.pop(context, true);
    } on ApiError catch (e) {
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = DateFormat('d MMM yyyy', 'fr_FR');
    final days = _range.end.difference(_range.start).inDays + 1;
    return AlertDialog(
      title: const Text('Absence justifiée'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (widget.employees.length == 1)
              Text(widget.employees.first.name, style: const TextStyle(fontWeight: FontWeight.w600))
            else
              DropdownButtonFormField<String?>(
                initialValue: _userId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Qui ?'),
                items: [
                  if (widget.allowCompany) const DropdownMenuItem<String?>(value: null, child: Text("Toute l'entreprise (jour férié, fermeture)")),
                  for (final e in widget.employees) DropdownMenuItem<String?>(value: e.id, child: Text(e.name)),
                ],
                onChanged: (v) => setState(() {
                  _userId = v;
                  if (v == null) _kind = 'ferie';
                  if (v != null && _kind == 'ferie') _kind = 'conge_paye';
                }),
              ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _kind,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Type'),
              items: [for (final k in Absence.kinds) DropdownMenuItem(value: k, child: Text(Absence.label(k)))],
              onChanged: (v) => setState(() => _kind = v ?? _kind),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _pickRange,
              icon: const Icon(Icons.date_range),
              label: Text(days == 1 ? 'Le ${f.format(_range.start)}' : 'Du ${f.format(_range.start)} au ${f.format(_range.end)} ($days jours)'),
            ),
            const SizedBox(height: 12),
            TextField(controller: _note, maxLength: 300, decoration: const InputDecoration(labelText: 'Note (facultatif)', hintText: 'ex. certificat médical reçu')),
            if (_kind == 'ferie')
              Text('Jour férié : la journée ne compte pas comme travaillée ; un pointage ce jour-là est compté en heures sup.',
                  style: Theme.of(context).textTheme.bodySmall),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Annuler')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Enregistrer')),
      ],
    );
  }
}

/// Liste des absences et jours fériés d'une entreprise sur une période, avec ajout et suppression.
class AbsencesScreen extends StatefulWidget {
  final String companyId;
  final String? companyName;
  final DateTimeRange range;
  const AbsencesScreen({super.key, required this.companyId, this.companyName, required this.range});
  @override
  State<AbsencesScreen> createState() => _AbsencesScreenState();
}

class _AbsencesScreenState extends State<AbsencesScreen> {
  late Future<List<Absence>> _future = _fetch();
  List<({String id, String name})>? _employees;
  bool _changed = false;

  Future<List<Absence>> _fetch() =>
      Api.instance.absences(widget.companyId, widget.range.start.subtract(const Duration(days: 31)), widget.range.end.add(const Duration(days: 92)));

  @override
  void initState() {
    super.initState();
    Api.instance.employees().then((list) {
      if (!mounted) return;
      setState(() => _employees = [
            for (final p in list)
              if (p.companyId == widget.companyId && !p.isSuperAdmin && p.active) (id: p.id, name: p.fullName),
          ]);
    });
  }

  void _reload() => setState(() {
        _changed = true;
        _future = _fetch();
      });

  Future<void> _add() async {
    if (_employees == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AbsenceDialog(companyId: widget.companyId, employees: _employees!, allowCompany: true),
    );
    if (ok == true) _reload();
  }

  Future<void> _delete(Absence a) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer cette absence ?'),
        content: Text('${a.employeeName ?? "Toute l'entreprise"} · ${Absence.label(a.kind)}\n'
            'Les jours concernés redeviendront « absent » s\'il n\'y a pas de pointage.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Supprimer')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.instance.deleteAbsence(a.id);
      _reload();
    } on ApiError catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = DateFormat('d MMM yyyy', 'fr_FR');
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.pop(context, _changed);
      },
      child: Scaffold(
        appBar: AppBar(title: Text(['Absences et jours fériés', if (widget.companyName != null) widget.companyName!].join(' · '))),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _employees == null ? null : _add,
          icon: const Icon(Icons.add),
          label: const Text('Déclarer'),
        ),
        body: FutureBuilder<List<Absence>>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) return Padding(padding: const EdgeInsets.all(24), child: Text('${snap.error}'));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final list = snap.data!;
            return ListView(padding: const EdgeInsets.fromLTRB(8, 8, 8, 96), children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                child: Text('Du ${f.format(widget.range.start.subtract(const Duration(days: 31)))} au ${f.format(widget.range.end.add(const Duration(days: 92)))}',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
              if (list.isEmpty) const ListTile(title: Text('Aucune absence déclarée.')),
              for (final a in list)
                Card(
                  child: ListTile(
                    leading: Icon(a.userId == null ? Icons.celebration_outlined : Icons.event_available, color: AppColors.ok),
                    title: Text('${a.employeeName ?? "Toute l'entreprise"} · ${Absence.label(a.kind)}'),
                    subtitle: Text([
                      a.start == a.end ? f.format(a.start) : 'du ${f.format(a.start)} au ${f.format(a.end)}',
                      if (a.note != null) a.note!,
                    ].join(' · ')),
                    trailing: IconButton(tooltip: 'Supprimer', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(a)),
                  ),
                ),
            ]);
          },
        ),
      ),
    );
  }
}
