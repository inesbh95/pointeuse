// Backoffice › Tickets : tableau Kanban (glisser-déposer entre statuts) ou liste, création et assignation.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../services/api.dart';
import '../theme.dart';
import 'ticket_detail_screen.dart';
import 'tickets.dart';
import 'web_file_picker.dart';

class AdminTicketsTab extends StatefulWidget {
  final Profile profile;
  const AdminTicketsTab({super.key, required this.profile});
  @override
  State<AdminTicketsTab> createState() => _AdminTicketsTabState();
}

class _AdminTicketsTabState extends State<AdminTicketsTab> {
  // Super-admin : choisit une entreprise où le module est actif ; admin : la sienne.
  List<Company>? _companies;
  late String? _companyId = widget.profile.isSuperAdmin ? null : widget.profile.companyId;
  Future<List<Ticket>>? _future;
  bool _board = true;
  String _search = '';
  String? _assignee; // null = tous, '' = non assignés
  bool _showCancelled = false;

  @override
  void initState() {
    super.initState();
    if (widget.profile.isSuperAdmin) {
      Api.instance.companies().then((all) {
        if (!mounted) return;
        final withModule = all.where((c) => c.modules.contains(ticketsModule)).toList();
        setState(() {
          _companies = withModule;
          _companyId = withModule.where((c) => c.id == widget.profile.companyId).firstOrNull?.id ?? withModule.firstOrNull?.id;
          _reload();
        });
      });
    } else {
      _reload();
    }
  }

  void _reload() {
    if (_companyId == null) return;
    setState(() => _future = TicketsApi.instance.companyTickets(companyId: _companyId));
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  List<Ticket> _filter(List<Ticket> all) {
    final q = _search.trim().toLowerCase();
    return all.where((t) {
      if (!_showCancelled && t.status == TicketStatus.cancelled) return false;
      if (_assignee != null && (t.assigneeId ?? '') != _assignee) return false;
      if (q.isEmpty) return true;
      return t.title.toLowerCase().contains(q) || t.key.toLowerCase() == q || (t.assigneeName ?? '').toLowerCase().contains(q) ||
          (t.externalId ?? '').toLowerCase() == q;
    }).toList();
  }

  Future<void> _open(Ticket t) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => TicketDetailScreen(
          ticketId: t.id,
          admin: true,
          pickFile: pickWebFile,
          onEdit: (ctx, ticket) async => await showDialog<bool>(context: ctx, builder: (_) => TicketFormDialog(companyId: ticket.companyId, ticket: ticket)) == true,
        ),
      ),
    );
    if (changed == true) _reload();
  }

  Future<void> _create() async {
    if (_companyId == null) return;
    final created = await showDialog<bool>(context: context, builder: (_) => TicketFormDialog(companyId: _companyId!));
    if (created == true) _reload();
  }

  /// Glisser-déposer sur le tableau : l'admin peut mettre n'importe quel statut.
  Future<void> _drop(Ticket t, TicketStatus to) async {
    if (t.status == to) return;
    String? note;
    if (to == TicketStatus.blocked) {
      final c = TextEditingController();
      note = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('${t.key} bloqué : pourquoi ?'),
          content: TextField(controller: c, autofocus: true, maxLines: 3, decoration: const InputDecoration(hintText: 'Motif (obligatoire)')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
            FilledButton(onPressed: () => c.text.trim().length >= 3 ? Navigator.pop(ctx, c.text.trim()) : null, child: const Text('Confirmer')),
          ],
        ),
      );
      if (note == null) return;
    }
    try {
      await TicketsApi.instance.changeStatus(t.id, to, note: note);
      _reload();
    } on ApiError catch (e) {
      _snack(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.profile.isSuperAdmin && _companies != null && _companies!.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('Aucune entreprise n\'a le module Tickets.\nActivez-le dans Entreprises › Modules.', textAlign: TextAlign.center),
        ),
      );
    }
    return Scaffold(
      floatingActionButton: _companyId == null
          ? null
          : FloatingActionButton.extended(onPressed: _create, icon: const Icon(Icons.add_task), label: const Text('Nouveau ticket')),
      body: Column(children: [
        _toolbar(),
        Expanded(
          child: _future == null
              ? const Center(child: CircularProgressIndicator())
              : FutureBuilder<List<Ticket>>(
                  future: _future,
                  builder: (context, snap) {
                    if (snap.hasError) return Padding(padding: const EdgeInsets.all(24), child: Text('Erreur : ${snap.error}'));
                    if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                    final list = _filter(snap.data!);
                    if (snap.data!.isEmpty) {
                      return const Center(child: Text('Aucun ticket. Créez-en un et assignez-le à un employé.'));
                    }
                    return _board ? _Board(tickets: list, showCancelled: _showCancelled, onOpen: _open, onDrop: _drop) : _list(list);
                  },
                ),
        ),
      ]),
    );
  }

  Widget _toolbar() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (_companies != null)
            SizedBox(
              width: 240,
              child: DropdownButtonFormField<String>(
                initialValue: _companyId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Entreprise', isDense: true),
                items: [for (final c in _companies!) DropdownMenuItem(value: c.id, child: Text(c.name))],
                onChanged: (v) {
                  _companyId = v;
                  _assignee = null;
                  _reload();
                },
              ),
            ),
          SizedBox(
            width: 240,
            child: TextField(
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Rechercher (titre, TK-12, employé)', isDense: true),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          if (_companyId != null)
            SizedBox(
              width: 220,
              child: FutureBuilder<List<Profile>>(
                key: ValueKey(_companyId),
                future: _assignable(_companyId!),
                builder: (_, s) => DropdownButtonFormField<String?>(
                  initialValue: _assignee,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Assigné à', isDense: true),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('Tout le monde')),
                    const DropdownMenuItem<String?>(value: '', child: Text('Non assignés')),
                    for (final p in s.data ?? const <Profile>[]) DropdownMenuItem<String?>(value: p.id, child: Text(p.fullName)),
                  ],
                  onChanged: (v) => setState(() => _assignee = v),
                ),
              ),
            ),
          FilterChip(label: const Text('Annulés'), selected: _showCancelled, onSelected: (v) => setState(() => _showCancelled = v)),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: true, icon: Icon(Icons.view_kanban_outlined), label: Text('Tableau')),
              ButtonSegment(value: false, icon: Icon(Icons.view_list_outlined), label: Text('Liste')),
            ],
            selected: {_board},
            onSelectionChanged: (s) => setState(() => _board = s.first),
          ),
          IconButton(tooltip: 'Actualiser', onPressed: _reload, icon: const Icon(Icons.refresh)),
        ]),
      );

  Widget _list(List<Ticket> list) {
    const order = TicketStatus.values;
    final sorted = [...list]..sort((a, b) {
        final s = order.indexOf(a.status).compareTo(order.indexOf(b.status));
        return s != 0 ? s : b.updatedAt.compareTo(a.updatedAt);
      });
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: sorted.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final t = sorted[i];
        return ListTile(
          onTap: () => _open(t),
          leading: TicketPriorityBadge(t.priority, withLabel: false),
          title: Text('${t.key} · ${t.title}', overflow: TextOverflow.ellipsis),
          subtitle: Text([
            t.assigneeName ?? 'Non assigné',
            ticketTypes[t.type] ?? t.type,
            if (t.dueDate != null) 'échéance ${DateFormat('d MMM', 'fr_FR').format(t.dueDate!)}${t.overdue ? ' (en retard)' : ''}',
            if (t.imported) t.sourceLabel,
          ].join(' · ')),
          trailing: TicketStatusChip(t.status),
        );
      },
    );
  }
}

/// Employés à qui l'on peut assigner un ticket (actifs, de l'entreprise, hors super-admin).
Future<List<Profile>> _assignable(String companyId) async =>
    (await Api.instance.employees()).where((p) => p.active && p.companyId == companyId && !p.isSuperAdmin).toList();

// =============================================================================
// Tableau Kanban
// =============================================================================
class _Board extends StatelessWidget {
  final List<Ticket> tickets;
  final bool showCancelled;
  final void Function(Ticket) onOpen;
  final Future<void> Function(Ticket, TicketStatus) onDrop;
  const _Board({required this.tickets, required this.showCancelled, required this.onOpen, required this.onDrop});

  @override
  Widget build(BuildContext context) {
    final columns = [for (final s in TicketStatus.values) if (s != TicketStatus.cancelled || showCancelled) s];
    return LayoutBuilder(builder: (context, box) {
      final width = (box.maxWidth / columns.length).clamp(220.0, 320.0);
      return Scrollbar(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final s in columns)
              SizedBox(
                width: width,
                height: box.maxHeight - 8,
                child: _Column(status: s, tickets: tickets.where((t) => t.status == s).toList(), onOpen: onOpen, onDrop: onDrop),
              ),
          ]),
        ),
      );
    });
  }
}

class _Column extends StatelessWidget {
  final TicketStatus status;
  final List<Ticket> tickets;
  final void Function(Ticket) onOpen;
  final Future<void> Function(Ticket, TicketStatus) onDrop;
  const _Column({required this.status, required this.tickets, required this.onOpen, required this.onDrop});

  @override
  Widget build(BuildContext context) {
    final c = status.colors;
    return DragTarget<Ticket>(
      onWillAcceptWithDetails: (d) => d.data.status != status,
      onAcceptWithDetails: (d) => onDrop(d.data, status),
      builder: (context, candidates, _) => Container(
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: candidates.isNotEmpty ? c.bg : Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: candidates.isNotEmpty ? c.fg : Colors.transparent, width: 2),
        ),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(children: [
              Icon(status.icon, size: 18, color: c.fg),
              const SizedBox(width: 6),
              Expanded(child: Text(status.label, style: const TextStyle(fontWeight: FontWeight.w700))),
              Text('${tickets.length}', style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(6, 0, 6, 80), children: [
              for (final t in tickets)
                Draggable<Ticket>(
                  data: t,
                  feedback: Material(
                    elevation: 8,
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(width: 240, child: _Card(ticket: t)),
                  ),
                  childWhenDragging: Opacity(opacity: 0.3, child: _Card(ticket: t)),
                  child: _Card(ticket: t, onTap: () => onOpen(t)),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Ticket ticket;
  final VoidCallback? onTap;
  const _Card({required this.ticket, this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = ticket;
    final small = Theme.of(context).textTheme.bodySmall;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.title, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Row(children: [
              Text(t.key, style: small),
              const SizedBox(width: 6),
              TicketPriorityBadge(t.priority, withLabel: false),
              const SizedBox(width: 4),
              TicketSourceBadge(t),
              const Spacer(),
              if (t.dueDate != null)
                Text(DateFormat('d MMM', 'fr_FR').format(t.dueDate!),
                    style: TextStyle(fontSize: 12, color: t.overdue ? AppColors.bad : null, fontWeight: t.overdue ? FontWeight.w700 : null)),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              CircleAvatar(
                radius: 10,
                child: Text(t.assigneeName == null || t.assigneeName!.isEmpty ? '?' : t.assigneeName![0].toUpperCase(), style: const TextStyle(fontSize: 11)),
              ),
              const SizedBox(width: 6),
              Expanded(child: Text(t.assigneeName ?? 'Non assigné', style: small, overflow: TextOverflow.ellipsis)),
            ]),
          ]),
        ),
      ),
    );
  }
}

// =============================================================================
// Création / modification
// =============================================================================
class TicketFormDialog extends StatefulWidget {
  final String companyId;
  final Ticket? ticket; // null = création
  const TicketFormDialog({super.key, required this.companyId, this.ticket});
  @override
  State<TicketFormDialog> createState() => _TicketFormDialogState();
}

class _TicketFormDialogState extends State<TicketFormDialog> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.ticket?.title);
  late final _description = TextEditingController(text: widget.ticket?.description);
  late String _type = widget.ticket?.type ?? 'task';
  late String _priority = widget.ticket?.priority ?? 'normal';
  late String? _assignee = widget.ticket?.assigneeId;
  late DateTime? _due = widget.ticket?.dueDate;
  late final Future<List<Profile>> _people = _assignable(widget.companyId);
  final _files = <PickedTicketFile>[];
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await TicketsApi.instance.save(
        id: widget.ticket?.id, companyId: widget.companyId, title: _title.text.trim(), description: _description.text.trim(),
        type: _type, priority: _priority, assigneeId: _assignee, dueDate: _due,
      );
      for (final f in _files) {
        await TicketsApi.instance.attach(id, f);
      }
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
        title: Text(widget.ticket == null ? 'Nouveau ticket' : 'Modifier ${widget.ticket!.key}'),
        content: SizedBox(
          width: 520,
          child: Form(
            key: _form,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                TextFormField(
                  controller: _title,
                  autofocus: widget.ticket == null,
                  maxLength: 200,
                  decoration: const InputDecoration(labelText: 'Titre'),
                  validator: (v) => (v ?? '').trim().length < 3 ? '3 caractères minimum' : null,
                ),
                TextFormField(
                  controller: _description,
                  minLines: 3,
                  maxLines: 8,
                  maxLength: 10000,
                  decoration: const InputDecoration(labelText: 'Description', alignLabelWithHint: true),
                ),
                Row(children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _type,
                      decoration: const InputDecoration(labelText: 'Type'),
                      items: [for (final e in ticketTypes.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                      onChanged: (v) => setState(() => _type = v!),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _priority,
                      decoration: const InputDecoration(labelText: 'Priorité'),
                      items: [
                        for (final e in ticketPriorities.entries)
                          DropdownMenuItem(value: e.key, child: Row(children: [Icon(priorityIcon(e.key), size: 16, color: priorityColor(e.key)), const SizedBox(width: 6), Text(e.value)])),
                      ],
                      onChanged: (v) => setState(() => _priority = v!),
                    ),
                  ),
                ]),
                const SizedBox(height: 12),
                FutureBuilder<List<Profile>>(
                  future: _people,
                  builder: (_, s) => DropdownButtonFormField<String?>(
                    initialValue: _assignee,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Assigné à', prefixIcon: Icon(Icons.person_outline)),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('Personne pour l\'instant')),
                      for (final p in s.data ?? const <Profile>[])
                        DropdownMenuItem<String?>(value: p.id, child: Text([p.fullName, if ((p.matricule ?? '').isNotEmpty) p.matricule].join(' · '))),
                    ],
                    onChanged: (v) => setState(() => _assignee = v),
                  ),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  const Icon(Icons.event_outlined),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_due == null ? 'Pas d\'échéance' : 'Échéance : ${DateFormat('EEEE d MMMM yyyy', 'fr_FR').format(_due!)}')),
                  if (_due != null) IconButton(tooltip: 'Retirer', onPressed: () => setState(() => _due = null), icon: const Icon(Icons.close)),
                  TextButton(
                    onPressed: () async {
                      final now = DateTime.now();
                      final d = await showDatePicker(context: context, firstDate: DateTime(now.year - 1), lastDate: DateTime(now.year + 3), initialDate: _due ?? now);
                      if (d != null) setState(() => _due = d);
                    },
                    child: const Text('Choisir'),
                  ),
                ]),
                if (widget.ticket == null) ...[
                  const SizedBox(height: 4),
                  Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    TextButton.icon(
                      onPressed: () async {
                        final f = await pickWebFile(context);
                        if (f == null) return;
                        if (f.bytes.length > 10 * 1024 * 1024) {
                          setState(() => _error = 'Fichier trop lourd (10 Mo maximum).');
                          return;
                        }
                        setState(() => _files.add(f));
                      },
                      icon: const Icon(Icons.attach_file),
                      label: const Text('Joindre un fichier'),
                    ),
                    for (final f in _files) InputChip(label: Text(f.name), onDeleted: () => setState(() => _files.remove(f))),
                  ]),
                ],
                if (widget.ticket?.imported == true)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('Ticket importé de ${widget.ticket!.sourceLabel} : le titre et la description peuvent être remplacés à la prochaine synchronisation.',
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
                if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: AppColors.bad))),
              ]),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: _busy ? null : _save, child: Text(widget.ticket == null ? 'Créer' : 'Enregistrer')),
        ],
      );
}
