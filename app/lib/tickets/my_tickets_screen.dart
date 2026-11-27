// App mobile › Mes tickets : les tickets assignés à l'employé, à traiter (pas de création).
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../models.dart';
import '../theme.dart';
import 'ticket_detail_screen.dart';
import 'tickets.dart';

/// Photo prise avec l'appareil ou choisie dans la galerie (réduite pour l'envoi).
Future<PickedTicketFile?> pickMobilePhoto(BuildContext context) async {
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(leading: const Icon(Icons.photo_camera_outlined), title: const Text('Prendre une photo'), onTap: () => Navigator.pop(ctx, ImageSource.camera)),
        ListTile(leading: const Icon(Icons.photo_library_outlined), title: const Text('Choisir dans la galerie'), onTap: () => Navigator.pop(ctx, ImageSource.gallery)),
      ]),
    ),
  );
  if (source == null) return null;
  final x = await ImagePicker().pickImage(source: source, maxWidth: 1920, maxHeight: 1920, imageQuality: 80);
  if (x == null) return null;
  final name = x.name.isEmpty ? 'photo.jpg' : x.name;
  return PickedTicketFile(name, x.mimeType ?? (name.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg'), await x.readAsBytes());
}

class MyTicketsScreen extends StatefulWidget {
  final Profile profile;
  /// Appelé après un changement (mise à jour de la pastille du menu).
  final VoidCallback? onChanged;
  const MyTicketsScreen({super.key, required this.profile, this.onChanged});
  @override
  State<MyTicketsScreen> createState() => MyTicketsScreenState();
}

class MyTicketsScreenState extends State<MyTicketsScreen> {
  late Future<List<Ticket>> _future = TicketsApi.instance.myTickets();
  bool _showClosed = false;

  Future<void> reload() async {
    setState(() => _future = TicketsApi.instance.myTickets());
    await _future;
    widget.onChanged?.call();
  }

  Future<void> _open(Ticket t) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => TicketDetailScreen(ticketId: t.id, admin: widget.profile.isAdmin && t.companyId == widget.profile.companyId, pickFile: pickMobilePhoto)),
    );
    if (changed == true) reload();
  }

  /// À traiter en premier : bloqués, en cours, à faire (urgents d'abord), puis en revue, puis clos.
  static int _rank(Ticket t) => switch (t.status) {
        TicketStatus.blocked => 0,
        TicketStatus.inProgress => 1,
        TicketStatus.todo => 2,
        TicketStatus.review => 3,
        _ => 4,
      };
  static const _prio = ['urgent', 'high', 'normal', 'low'];

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        onRefresh: reload,
        child: FutureBuilder<List<Ticket>>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) return ListView(children: [Padding(padding: const EdgeInsets.all(24), child: Text('Erreur : ${snap.error}'))]);
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final all = [...snap.data!]..sort((a, b) {
                final r = _rank(a).compareTo(_rank(b));
                if (r != 0) return r;
                final p = _prio.indexOf(a.priority).compareTo(_prio.indexOf(b.priority));
                if (p != 0) return p;
                return (a.dueDate ?? DateTime(9999)).compareTo(b.dueDate ?? DateTime(9999));
              });
            final open = all.where((t) => !t.status.closed).toList();
            final closed = all.where((t) => t.status.closed).toList();
            return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
              if (open.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Column(children: [
                    Icon(Icons.task_alt, size: 48, color: AppColors.ok),
                    SizedBox(height: 8),
                    Text('Aucun ticket à traiter.', textAlign: TextAlign.center),
                  ]),
                ),
              for (final t in open) _TicketTile(t, onTap: () => _open(t)),
              if (closed.isNotEmpty)
                ListTile(
                  title: Text('Terminés récemment (${closed.length})'),
                  trailing: Icon(_showClosed ? Icons.expand_less : Icons.expand_more),
                  onTap: () => setState(() => _showClosed = !_showClosed),
                ),
              if (_showClosed) for (final t in closed) _TicketTile(t, onTap: () => _open(t)),
            ]);
          },
        ),
      );
}

class _TicketTile extends StatelessWidget {
  final Ticket t;
  final VoidCallback onTap;
  const _TicketTile(this.t, {required this.onTap});

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              TicketStatusChip(t.status),
              const SizedBox(width: 8),
              TicketPriorityBadge(t.priority),
              const Spacer(),
              TicketSourceBadge(t),
              const SizedBox(width: 6),
              Text(t.key, style: small),
            ]),
            const SizedBox(height: 8),
            Text(t.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
            if (t.status == TicketStatus.blocked && t.blockedReason != null)
              Padding(padding: const EdgeInsets.only(top: 4), child: Text('Bloqué : ${t.blockedReason}', style: const TextStyle(color: AppColors.bad))),
            if (t.dueDate != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Échéance ${DateFormat('EEEE d MMMM', 'fr_FR').format(t.dueDate!)}${t.overdue ? ' · en retard' : ''}',
                  style: TextStyle(fontSize: 13, color: t.overdue ? AppColors.bad : null, fontWeight: t.overdue ? FontWeight.w600 : null),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
