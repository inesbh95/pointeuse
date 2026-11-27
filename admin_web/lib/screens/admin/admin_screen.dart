import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models.dart';
import '../../services/api.dart';
import '../../services/export_service.dart';
import '../../services/location_service.dart';
import '../../services/place_service.dart';
import '../../theme.dart';
import '../../tickets/admin_tickets_tab.dart';
import '../../tickets/tickets.dart';
import '../history_screen.dart';
import 'companies_tab.dart';
import 'reminders_tab.dart';
import 'timesheet_tab.dart';
import 'site_map_picker.dart';

/// Administration web : menu latéral sur grand écran, onglets sur petit écran.
class AdminScreen extends StatefulWidget {
  final Profile profile;
  const AdminScreen({super.key, required this.profile});
  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final p = widget.profile;
    final sections = <(IconData, String, Widget)>[
      (Icons.fact_check_outlined, 'Pointages', _ReviewTab(superAdmin: p.isSuperAdmin, ownCompanyId: p.companyId)),
      (Icons.calendar_month_outlined, 'Feuilles de temps', TimesheetTab(profile: p)),
      (Icons.badge_outlined, 'Employés', _EmployeesTab(profile: p)),
      if (p.hasModule(ticketsModule) || p.isSuperAdmin) (Icons.confirmation_number_outlined, 'Tickets', AdminTicketsTab(profile: p)),
      if (p.sitesEnabled || p.isSuperAdmin) (Icons.place_outlined, 'Sites clients', _SitesTab(profile: p)),
      (Icons.tune, 'Réglages', RemindersTab(profile: p)),
      if (p.isSuperAdmin) (Icons.apartment_outlined, 'Entreprises', const CompaniesTab()),
    ];
    final i = _index.clamp(0, sections.length - 1);
    final content = KeyedSubtree(key: ValueKey(i), child: sections[i].$3);

    if (MediaQuery.sizeOf(context).width >= 900) {
      return Row(children: [
        NavigationRail(
          selectedIndex: i,
          onDestinationSelected: (v) => setState(() => _index = v),
          labelType: NavigationRailLabelType.all,
          destinations: [for (final s in sections) NavigationRailDestination(icon: Icon(s.$1), label: Text(s.$2))],
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1100), child: content),
          ),
        ),
      ]);
    }
    return Column(children: [
      Expanded(child: content),
      NavigationBar(
        selectedIndex: i,
        onDestinationSelected: (v) => setState(() => _index = v),
        destinations: [for (final s in sections) NavigationDestination(icon: Icon(s.$1), label: s.$2)],
      ),
    ]);
  }
}

void _snack(BuildContext context, String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

// =============================================================================
// Revue des pointages
// =============================================================================
class _ReviewTab extends StatefulWidget {
  final bool superAdmin;
  final String? ownCompanyId; // entreprise de l'admin connecté (feuille de temps de l'export)
  const _ReviewTab({required this.superAdmin, this.ownCompanyId});
  @override
  State<_ReviewTab> createState() => _ReviewTabState();
}

class _ReviewTabState extends State<_ReviewTab> {
  String _filter = 'review';
  String? _companyId; // super-admin : null = toutes les entreprises
  List<Company>? _companies;
  late Future<List<Punch>> _future = Api.instance.teamPunches(_filter);

  @override
  void initState() {
    super.initState();
    if (widget.superAdmin) Api.instance.companies().then((c) => mounted ? setState(() => _companies = c) : null);
  }

  String? get _companyName => _companies?.where((c) => c.id == _companyId).firstOrNull?.name;

  Future<void> _reload() async {
    setState(() => _future = Api.instance.teamPunches(_filter, companyId: _companyId));
    await _future;
  }

  bool _exporting = false;

  /// Choix de la période puis partage du fichier Excel (e-mail, WhatsApp, Drive…).
  Future<void> _export() async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: now,
      initialDateRange: DateTimeRange(start: DateTime(now.year, now.month, 1), end: now),
      helpText: 'Période à exporter',
      saveText: 'Exporter',
      // Sur ordinateur : calendrier en fenêtre plutôt qu'en plein écran.
      builder: (ctx, child) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 640),
          child: ClipRRect(borderRadius: BorderRadius.circular(16), child: child),
        ),
      ),
    );
    if (range == null || !mounted) return;
    final from = DateTime(range.start.year, range.start.month, range.start.day);
    final to = DateTime(range.end.year, range.end.month, range.end.day);
    setState(() => _exporting = true);
    try {
      final punches = await Api.instance.punchesBetween(from, to.add(const Duration(days: 1)), companyId: _companyId);
      if (!mounted) return;
      if (punches.isEmpty) return _snack(context, 'Aucun pointage sur cette période.');
      final timesheet = await Api.instance.timesheet(from, to, companyId: widget.superAdmin ? _companyId : widget.ownCompanyId);
      await ExportService.download(punches, from: from, to: to, withCompany: widget.superAdmin && _companyId == null, fileTag: _companyName, timesheet: timesheet, addressOf: PlaceService.addressOf);
      if (mounted) _snack(context, 'Fichier Excel téléchargé (${punches.length} pointages).');
    } catch (e) {
      if (mounted) _snack(context, 'Export impossible : $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        if (_companies != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: DropdownButtonFormField<String?>(
              initialValue: _companyId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Entreprise', prefixIcon: Icon(Icons.apartment_outlined), isDense: true),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('Toutes les entreprises')),
                for (final c in _companies!) DropdownMenuItem<String?>(value: c.id, child: Text(c.name)),
              ],
              onChanged: (v) {
                _companyId = v;
                _reload();
              },
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
          child: Row(children: [
            Expanded(
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'review', label: Text('À vérifier')),
                  ButtonSegment(value: 'blocked', label: Text('Refusés')),
                  ButtonSegment(value: 'all', label: Text('Tous (7 j)')),
                ],
                selected: {_filter},
                onSelectionChanged: (s) {
                  _filter = s.first;
                  _reload();
                },
              ),
            ),
            IconButton(
              tooltip: 'Exporter en Excel',
              onPressed: _exporting ? null : _export,
              icon: _exporting
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.file_download_outlined),
            ),
          ]),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _reload,
            child: FutureBuilder<List<Punch>>(
              future: _future,
              builder: (context, snap) {
                if (snap.hasError) return ListView(children: [Padding(padding: const EdgeInsets.all(24), child: Text('Erreur : ${snap.error}'))]);
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                if (snap.data!.isEmpty) return ListView(children: const [Padding(padding: EdgeInsets.all(24), child: Text('Rien à afficher.'))]);
                return ListView(children: [
                  for (final p in snap.data!)
                    PunchTile(punch: p, showName: true, onTap: () => _openDetail(p)),
                ]);
              },
            ),
          ),
        ),
      ]);

  Future<void> _openDetail(Punch p) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 600), child: _PunchDetail(punch: p)),
      ),
    );
    if (changed == true) _reload();
  }
}

class _PunchDetail extends StatefulWidget {
  final Punch punch;
  const _PunchDetail({required this.punch});
  @override
  State<_PunchDetail> createState() => _PunchDetailState();
}

class _PunchDetailState extends State<_PunchDetail> {
  final _note = TextEditingController();
  Future<String>? _photo;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final path = widget.punch.photoPath;
    if (path != null) _photo = Api.instance.photoUrl(path);
    _note.text = widget.punch.reviewNote ?? '';
  }

  Future<void> _decide(bool approved) async {
    setState(() => _busy = true);
    try {
      await Api.instance.review(widget.punch.id, approved: approved, note: _note.text.trim().isEmpty ? null : _note.text.trim());
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) _snack(context, 'Enregistrement impossible. Réessayez.');
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.punch;
    final ip = p.ipInfo;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (_photo != null)
                FutureBuilder<String>(
                  future: _photo,
                  builder: (_, s) => ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: s.hasData
                        ? InkWell(
                            onTap: () => launchUrl(Uri.parse(s.data!)),
                            child: Image.network(s.data!, width: 140, height: 140, fit: BoxFit.cover),
                          )
                        : const SizedBox(width: 140, height: 140, child: Center(child: CircularProgressIndicator())),
                  ),
                ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.employeeName ?? '—', style: Theme.of(context).textTheme.titleLarge),
                  Text('${p.isIn ? 'Arrivée' : 'Départ'} · ${DateFormat('EEEE d MMMM, HH:mm', 'fr_FR').format(p.serverTs)}'),
                  const SizedBox(height: 6),
                  StatusChip(p.status),
                  if (p.faceSimilarity != null) Text('Ressemblance du visage : ${(p.faceSimilarity! * 100).round()} %', style: const TextStyle(fontSize: 12)),
                ]),
              ),
            ]),
            const Divider(height: 28),
            if (p.manual) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text("Saisi par l'administrateur. Motif : ${p.manualReason ?? '—'}", style: const TextStyle(fontWeight: FontWeight.w600))),
            if (p.siteLabel != null) Text(p.siteLabel!, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (p.address != null)
              Text(p.address!)
            else if (p.lat != null)
              FutureBuilder<String?>(
                future: PlaceService.addressOf(p.lat!, p.lng!),
                builder: (_, s) => Text(s.connectionState == ConnectionState.waiting ? 'Recherche de l\'adresse…' : s.data ?? 'Adresse introuvable'),
              ),
            if (p.lat != null)
              TextButton.icon(
                icon: const Icon(Icons.map),
                label: Text('${p.lat!.toStringAsFixed(6)}, ${p.lng!.toStringAsFixed(6)} (± ${p.accuracyM?.round() ?? '?'} m)'),
                onPressed: () => launchUrl(Uri.parse('https://www.google.com/maps/search/?api=1&query=${p.lat},${p.lng}'), mode: LaunchMode.externalApplication),
              ),
            if (ip != null && ip['error'] == null)
              Text('Réseau : ${[ip['operator'], ip['city'], ip['country']].whereType<String>().join(', ')} · IP ${ip['ip'] ?? '?'}', style: const TextStyle(fontSize: 13)),
            if (p.flags.isNotEmpty) ...[const SizedBox(height: 8), FlagList(p.flags)],
            const SizedBox(height: 16),
            TextField(controller: _note, decoration: const InputDecoration(labelText: 'Note (facultatif)'), maxLines: 2),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: _busy ? null : () => _decide(false), child: const Text('Rejeter'))),
              const SizedBox(width: 12),
              Expanded(child: FilledButton(onPressed: _busy ? null : () => _decide(true), child: const Text('Valider'))),
            ]),
          ]),
        ),
      ),
    );
  }
}

// =============================================================================
// Sites clients
// =============================================================================
class _SitesTab extends StatefulWidget {
  final Profile profile; // l'admin connecté : le super-admin voit et choisit l'entreprise
  const _SitesTab({required this.profile});
  @override
  State<_SitesTab> createState() => _SitesTabState();
}

class _SitesTabState extends State<_SitesTab> {
  late Future<List<Site>> _future = Api.instance.sites();
  void _reload() => setState(() => _future = Api.instance.sites());

  @override
  Widget build(BuildContext context) => Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () async {
            final added = await showDialog<bool>(context: context, builder: (_) => _SiteDialog(admin: widget.profile));
            if (added == true) _reload();
          },
          icon: const Icon(Icons.add_location_alt),
          label: const Text('Ajouter un site'),
        ),
        body: FutureBuilder<List<Site>>(
          future: _future,
          builder: (context, snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            if (snap.data!.isEmpty) {
              return const Padding(padding: EdgeInsets.all(24), child: Text('Aucun site client. Sans site, chaque pointage sera marqué « hors site ».'));
            }
            return ListView(padding: const EdgeInsets.only(bottom: 88), children: [
              for (final s in snap.data!)
                ListTile(
                  leading: const Icon(Icons.place),
                  title: Text(s.client),
                  subtitle: Text([if (widget.profile.isSuperAdmin) s.companyName, s.name, 'rayon ${s.radiusM} m'].whereType<String>().join(' · ')),
                  onTap: () => launchUrl(Uri.parse('https://www.google.com/maps/search/?api=1&query=${s.lat},${s.lng}'), mode: LaunchMode.externalApplication),
                  trailing: IconButton(
                    tooltip: 'Archiver',
                    icon: const Icon(Icons.archive_outlined),
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const Text('Archiver ce site ?'),
                          content: Text('${s.label} ne sera plus proposé. Les anciens pointages restent intacts.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
                            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Archiver')),
                          ],
                        ),
                      );
                      if (ok == true) {
                        await Api.instance.archiveSite(s.id);
                        _reload();
                      }
                    },
                  ),
                ),
            ]);
          },
        ),
      );
}

class _SiteDialog extends StatefulWidget {
  final Profile admin;
  const _SiteDialog({required this.admin});
  @override
  State<_SiteDialog> createState() => _SiteDialogState();
}

class _SiteDialogState extends State<_SiteDialog> {
  final _form = GlobalKey<FormState>();
  late String? _companyId = widget.admin.companyId;
  late final Future<List<Company>>? _companies = widget.admin.isSuperAdmin ? Api.instance.companies() : null;
  final _client = TextEditingController(), _name = TextEditingController();
  final _lat = TextEditingController(), _lng = TextEditingController(), _radius = TextEditingController(text: '200');
  bool _busy = false;
  String? _gpsInfo;

  Future<void> _here() async {
    setState(() => _gpsInfo = 'Localisation…');
    try {
      final p = await LocationService.current();
      _lat.text = p.latitude.toStringAsFixed(6);
      _lng.text = p.longitude.toStringAsFixed(6);
      setState(() => _gpsInfo = 'Position relevée (± ${p.accuracy.round()} m)');
    } catch (e) {
      setState(() => _gpsInfo = e.toString());
    }
  }

  Future<void> _pickOnMap() async {
    final lat = double.tryParse(_lat.text.replaceAll(',', '.')), lng = double.tryParse(_lng.text.replaceAll(',', '.'));
    final picked = await Navigator.push<PickedPlace>(
      context,
      MaterialPageRoute(builder: (_) => SiteMapPicker(
            initial: lat != null && lng != null ? LatLng(lat, lng) : null,
            radiusM: int.tryParse(_radius.text) ?? 200,
          )),
    );
    if (picked == null || !mounted) return;
    _lat.text = picked.point.latitude.toStringAsFixed(6);
    _lng.text = picked.point.longitude.toStringAsFixed(6);
    // Nominatim renvoie l'adresse complète jusqu'au pays : on garde rue, quartier, ville.
    if (_name.text.trim().isEmpty && picked.address != null) _name.text = picked.address!.split(', ').take(3).join(', ');
    setState(() => _gpsInfo = 'Emplacement choisi sur la carte');
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await Api.instance.addSite(
        client: _client.text.trim(), name: _name.text.trim(),
        lat: double.parse(_lat.text.replaceAll(',', '.')), lng: double.parse(_lng.text.replaceAll(',', '.')),
        radiusM: int.parse(_radius.text),
        companyId: widget.admin.isSuperAdmin ? _companyId : null,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      setState(() => _busy = false);
      if (mounted) _snack(context, 'Enregistrement impossible.');
    }
  }

  String? _required(String? v) => (v == null || v.trim().isEmpty) ? 'Obligatoire' : null;
  String? _coord(String? v, double max) {
    final d = double.tryParse((v ?? '').replaceAll(',', '.'));
    return d == null || d.abs() > max ? 'Valeur invalide' : null;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Nouveau site client'),
        content: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (_companies != null) ...[
                FutureBuilder<List<Company>>(
                  future: _companies,
                  builder: (_, s) => DropdownButtonFormField<String>(
                    initialValue: _companyId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Entreprise'),
                    items: [for (final c in s.data ?? const <Company>[]) if (c.active) DropdownMenuItem(value: c.id, child: Text(c.name))],
                    onChanged: (v) => setState(() => _companyId = v),
                    validator: (v) => v == null ? 'Obligatoire' : null,
                  ),
                ),
                const SizedBox(height: 10),
              ],
              TextFormField(controller: _client, decoration: const InputDecoration(labelText: 'Client'), validator: _required),
              const SizedBox(height: 10),
              TextFormField(controller: _name, decoration: const InputDecoration(labelText: 'Site (adresse, bâtiment)'), validator: _required),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: TextFormField(controller: _lat, decoration: const InputDecoration(labelText: 'Latitude'), keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), validator: (v) => _coord(v, 90))),
                const SizedBox(width: 8),
                Expanded(child: TextFormField(controller: _lng, decoration: const InputDecoration(labelText: 'Longitude'), keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), validator: (v) => _coord(v, 180))),
              ]),
              Wrap(children: [
                TextButton.icon(onPressed: _pickOnMap, icon: const Icon(Icons.map_outlined), label: const Text('Choisir sur la carte')),
                TextButton.icon(onPressed: _here, icon: const Icon(Icons.my_location), label: const Text('Ma position actuelle')),
              ]),
              if (_gpsInfo != null) Align(alignment: Alignment.centerLeft, child: Text(_gpsInfo!, style: const TextStyle(fontSize: 12))),
              const SizedBox(height: 10),
              TextFormField(
                controller: _radius,
                decoration: const InputDecoration(labelText: 'Rayon autorisé (m)'),
                keyboardType: TextInputType.number,
                validator: (v) {
                  final n = int.tryParse(v ?? '');
                  return n == null || n < 20 || n > 5000 ? 'Entre 20 et 5000 m' : null;
                },
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: _busy ? null : _save, child: const Text('Ajouter')),
        ],
      );
}

// =============================================================================
// Employés : création de compte et enregistrement du visage
// =============================================================================
class _EmployeesTab extends StatefulWidget {
  final Profile profile; // l'admin connecté
  const _EmployeesTab({required this.profile});
  @override
  State<_EmployeesTab> createState() => _EmployeesTabState();
}

class _EmployeesTabState extends State<_EmployeesTab> {
  late Future<(List<Profile>, Set<String>)> _future = _load();
  Future<(List<Profile>, Set<String>)> _load() async => (await Api.instance.employees(), await Api.instance.enrolledIds());
  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) => Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () async {
            final created = await showDialog<bool>(context: context, builder: (_) => _EmployeeDialog(admin: widget.profile));
            if (created == true) _reload();
          },
          icon: const Icon(Icons.person_add),
          label: const Text('Nouvel employé'),
        ),
        body: FutureBuilder<(List<Profile>, Set<String>)>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) return Padding(padding: const EdgeInsets.all(24), child: Text('Erreur : ${snap.error}'));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final (people, enrolled) = snap.data!;
            return ListView(padding: const EdgeInsets.only(bottom: 88), children: [
              for (final p in people)
                ListTile(
                  leading: CircleAvatar(child: Text(p.fullName.isEmpty ? '?' : p.fullName[0].toUpperCase())),
                  title: Text(p.fullName),
                  subtitle: Text([
                    if (widget.profile.isSuperAdmin) p.companyName,
                    p.matricule,
                    p.isSuperAdmin ? 'Super-admin' : p.isAdmin ? 'Administrateur' : null,
                    enrolled.contains(p.id) ? 'Visage enregistré' : 'Visage à enregistrer',
                  ].whereType<String>().where((s) => s.isNotEmpty).join(' · ')),
                  trailing: Tooltip(
                    message: enrolled.contains(p.id)
                        ? 'Visage enregistré'
                        : "Le visage s'enregistre depuis l'app mobile (Administration › Employés).",
                    child: Icon(enrolled.contains(p.id) ? Icons.face : Icons.phone_android),
                  ),
                ),
            ]);
          },
        ),
      );
}

class _EmployeeDialog extends StatefulWidget {
  final Profile admin; // l'admin connecté : le super-admin choisit l'entreprise
  const _EmployeeDialog({required this.admin});
  @override
  State<_EmployeeDialog> createState() => _EmployeeDialogState();
}

class _EmployeeDialogState extends State<_EmployeeDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(), _matricule = TextEditingController();
  final _email = TextEditingController(), _password = TextEditingController();
  bool _admin = false, _busy = false;
  String? _error;
  late String? _companyId = widget.admin.companyId;
  late final Future<List<Company>>? _companies = widget.admin.isSuperAdmin ? Api.instance.companies() : null;

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.instance.createEmployee(email: _email.text, password: _password.text, fullName: _name.text, matricule: _matricule.text, admin: _admin,
          companyId: widget.admin.isSuperAdmin ? _companyId : null);
      if (mounted) Navigator.pop(context, true);
    } on ApiError catch (e) {
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Nouvel employé'),
        content: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (_companies != null) ...[
                FutureBuilder<List<Company>>(
                  future: _companies,
                  builder: (_, s) => DropdownButtonFormField<String>(
                    initialValue: _companyId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Entreprise'),
                    items: [for (final c in s.data ?? const <Company>[]) if (c.active) DropdownMenuItem(value: c.id, child: Text(c.name))],
                    onChanged: (v) => setState(() => _companyId = v),
                    validator: (v) => v == null ? 'Obligatoire' : null,
                  ),
                ),
                const SizedBox(height: 10),
              ],
              TextFormField(controller: _name, decoration: const InputDecoration(labelText: 'Nom complet'), validator: (v) => (v ?? '').trim().length < 2 ? 'Obligatoire' : null),
              const SizedBox(height: 10),
              TextFormField(controller: _matricule, decoration: const InputDecoration(labelText: 'Matricule')),
              const SizedBox(height: 10),
              TextFormField(controller: _email, decoration: const InputDecoration(labelText: 'E-mail'), keyboardType: TextInputType.emailAddress, validator: (v) => (v ?? '').contains('@') ? null : 'E-mail invalide'),
              const SizedBox(height: 10),
              TextFormField(controller: _password, decoration: const InputDecoration(labelText: 'Mot de passe provisoire'), validator: (v) => (v ?? '').length < 8 ? '8 caractères minimum' : null),
              SwitchListTile(contentPadding: EdgeInsets.zero, value: _admin, onChanged: (v) => setState(() => _admin = v), title: const Text('Administrateur')),
              if (_error != null) Text(_error!, style: const TextStyle(color: AppColors.bad)),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: _busy ? null : _save, child: const Text('Créer')),
        ],
      );
}
