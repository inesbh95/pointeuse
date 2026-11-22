import 'package:flutter/material.dart';

import '../../models.dart';
import '../../services/api.dart';
import 'api_keys_section.dart';
import 'webhooks_section.dart';

/// Réglages d'une entreprise : gestion des sites clients et rappels de pointage
/// (admin ; le super-admin choisit l'entreprise).
class RemindersTab extends StatefulWidget {
  final Profile profile;
  const RemindersTab({super.key, required this.profile});
  @override
  State<RemindersTab> createState() => _RemindersTabState();
}

class _RemindersTabState extends State<RemindersTab> {
  static const _dayLabels = ['L', 'M', 'M', 'J', 'V', 'S', 'D'];
  static const _dayNames = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];

  List<Company>? _companies;
  String? _companyId;
  NotifySettings? _s;
  bool? _sites; // option « gestion des sites clients » de l'entreprise affichée
  bool _sitesBusy = false;
  bool _busy = false, _dirty = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _companyId = widget.profile.companyId;
    if (widget.profile.isSuperAdmin) {
      Api.instance.companies().then((c) => mounted ? setState(() => _companies = c) : null);
    }
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _s = null;
      _sites = null;
      _error = null;
      _dirty = false;
    });
    try {
      final s = await Api.instance.notifySettings(_companyId!);
      final sites = await Api.instance.sitesEnabled(_companyId!);
      if (mounted) setState(() {
        _s = s;
        _sites = sites;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Chargement impossible : $e');
    }
  }

  void _set(NotifySettings s) => setState(() {
        _s = s;
        _dirty = true;
      });

  NotifySettings _copy({bool? enabled, ({int h, int m})? timeIn, ({int h, int m})? timeOut, Set<int>? days, int? graceMin}) => NotifySettings(
        enabled: enabled ?? _s!.enabled,
        timeIn: timeIn ?? _s!.timeIn,
        timeOut: timeOut ?? _s!.timeOut,
        days: days ?? _s!.days,
        graceMin: graceMin ?? _s!.graceMin,
      );

  Future<({int h, int m})?> _pick(({int h, int m}) t, String help) async {
    final r = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: t.h, minute: t.m),
      helpText: help,
      builder: (ctx, child) => MediaQuery(data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true), child: child!),
    );
    return r == null ? null : (h: r.hour, m: r.minute);
  }

  /// Active ou désactive la gestion des sites (appliqué tout de suite, après confirmation).
  Future<void> _toggleSites(bool on) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(on ? 'Activer la gestion des sites ?' : 'Désactiver la gestion des sites ?'),
        content: Text(on
            ? "Les prochains pointages seront rattachés au site client le plus proche. Pensez à ajouter vos sites dans l'onglet « Sites clients » : sans site, chaque pointage sera signalé « hors site »."
            : "Les prochains pointages ne seront plus contrôlés par rapport aux sites clients. Les sites et les anciens pointages sont conservés."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(on ? 'Activer' : 'Désactiver')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _sitesBusy = true);
    try {
      await Api.instance.setSitesEnabled(_companyId!, on);
      if (!mounted) return;
      setState(() => _sites = on);
      // Sa propre entreprise : l'app se recharge (onglet « Sites clients » affiché ou masqué).
      if (_companyId == widget.profile.companyId) Api.instance.profileVersion.value++;
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _sitesBusy = false);
    }
  }

  Future<void> _save() async {
    final s = _s!;
    if (s.days.isEmpty) return setState(() => _error = 'Choisissez au moins un jour travaillé.');
    if (s.timeOut.h * 60 + s.timeOut.m <= s.timeIn.h * 60 + s.timeIn.m) {
      return setState(() => _error = "L'heure de départ doit être après l'heure d'arrivée.");
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.instance.setNotifySettings(_companyId!, s);
      // Le téléphone de l'admin applique tout de suite ; les autres à leur prochaine ouverture de l'app.
      if (!mounted) return;
      setState(() => _dirty = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(s.enabled ? 'Horaires et rappels enregistrés.' : 'Horaires enregistrés (rappels désactivés).'),
      ));
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    return ListView(padding: const EdgeInsets.all(16), children: [
      if (_companies != null) ...[
        DropdownButtonFormField<String>(
          initialValue: _companyId,
          decoration: const InputDecoration(labelText: 'Entreprise'),
          items: [for (final c in _companies!) DropdownMenuItem(value: c.id, child: Text(c.name))],
          onChanged: (v) {
            if (v == null || v == _companyId) return;
            _companyId = v;
            _load();
          },
        ),
        const SizedBox(height: 12),
      ],
      if (s == null && _error == null) const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
      if (s != null && _sites != null) ...[
        Text('Sites clients', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Card(
          child: SwitchListTile(
            title: const Text('Gestion des sites clients'),
            subtitle: Text(_sites!
                ? 'Chaque pointage est rattaché au site client le plus proche ; « hors site » est signalé.'
                : "Pas de sites : l'adresse exacte du pointage est affichée, sans contrôle de site."),
            value: _sites!,
            onChanged: _sitesBusy ? null : _toggleSites,
          ),
        ),
        const SizedBox(height: 20),
        Text('Horaires de travail', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
      ],
      if (s != null) ...[
        Card(
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.login),
              title: const Text("Heure d'arrivée"),
              trailing: Text(NotifySettings.fmt(s.timeIn), style: Theme.of(context).textTheme.titleLarge),
              onTap: () async {
                final t = await _pick(s.timeIn, "Heure d'arrivée");
                if (t != null) _set(_copy(timeIn: t));
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Heure de départ'),
              trailing: Text(NotifySettings.fmt(s.timeOut), style: Theme.of(context).textTheme.titleLarge),
              onTap: () async {
                final t = await _pick(s.timeOut, 'Heure de départ');
                if (t != null) _set(_copy(timeOut: t));
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('Tolérance de retard'),
              subtitle: const Text('Une arrivée dans ce délai ne compte pas comme un retard.'),
              trailing: DropdownButton<int>(
                value: const [0, 5, 10, 15, 20, 30].contains(s.graceMin) ? s.graceMin : 5,
                underline: const SizedBox.shrink(),
                items: [for (final m in const [0, 5, 10, 15, 20, 30]) DropdownMenuItem(value: m, child: Text('$m min'))],
                onChanged: (m) => m == null ? null : _set(_copy(graceMin: m)),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: SizedBox(
                width: double.infinity,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Jours travaillés'),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (var d = 1; d <= 7; d++)
                    Tooltip(
                      message: _dayNames[d - 1],
                      child: FilterChip(
                        label: Text(_dayLabels[d - 1]),
                        showCheckmark: false,
                        selected: s.days.contains(d),
                        onSelected: (on) => _set(_copy(days: {...s.days}..removeWhere((x) => x == d)..addAll(on ? [d] : []))),
                      ),
                    ),
                ]),
              ]),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 4),
        Text(
          'Ces horaires servent aux feuilles de temps (retards, absences, heures sup) et aux rappels.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        Text('Rappels de pointage', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Card(
          child: SwitchListTile(
            title: const Text('Envoyer des rappels'),
            subtitle: const Text("Chaque employé reçoit une notification à l'heure d'arrivée et de départ (sauf s'il a déjà pointé)."),
            value: s.enabled,
            onChanged: (v) => _set(_copy(enabled: v)),
          ),
        ),
      ],
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      if (s != null) ...[
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy || !_dirty ? null : _save,
          icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save),
          label: const Text('Enregistrer'),
        ),
        const SizedBox(height: 12),
        Text(
          "Les employés reçoivent les nouveaux horaires à leur prochaine ouverture de l'app.",
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 28),
        ApiKeysSection(
          companyId: _companyId!,
          companyName: _companies?.where((c) => c.id == _companyId).firstOrNull?.name ?? widget.profile.companyName,
        ),
        const SizedBox(height: 28),
        WebhooksSection(companyId: _companyId!, companyName: _companies?.where((c) => c.id == _companyId).firstOrNull?.name ?? widget.profile.companyName),
      ],
    ]);
  }
}
