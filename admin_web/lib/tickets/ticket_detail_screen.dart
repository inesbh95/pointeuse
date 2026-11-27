// Fiche d'un ticket : informations, actions de statut, fil (commentaires et historique), réponse.
// Fichier identique dans app/ et admin_web/.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/api.dart';
import '../theme.dart';
import 'tickets.dart';

typedef TicketFilePicker = Future<PickedTicketFile?> Function(BuildContext context);

class TicketDetailScreen extends StatefulWidget {
  final String ticketId;
  final bool admin; // admin de l'entreprise : tous les statuts, notes internes, modification
  final TicketFilePicker? pickFile;

  /// Ouvre le formulaire de modification (backoffice). Renvoie true si le ticket a changé.
  final Future<bool> Function(BuildContext context, Ticket ticket)? onEdit;
  const TicketDetailScreen({super.key, required this.ticketId, required this.admin, this.pickFile, this.onEdit});

  @override
  State<TicketDetailScreen> createState() => _TicketDetailScreenState();
}

class _TicketDetailScreenState extends State<TicketDetailScreen> {
  late Future<TicketDetail> _future = TicketsApi.instance.detail(widget.ticketId);
  final _reply = TextEditingController();
  final _pending = <PickedTicketFile>[];
  bool _internal = false, _busy = false, _changed = false;

  void _reload() => setState(() => _future = TicketsApi.instance.detail(widget.ticketId));
  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      _changed = true;
      _reload();
    } on ApiError catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('Erreur : $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _move(Ticket t, TicketStatus to) async {
    String? note;
    if (to == TicketStatus.blocked) {
      note = await _askText(title: 'Pourquoi le ticket est-il bloqué ?', hint: 'ex. pièce manquante, accès refusé…', required: true);
      if (note == null) return;
    } else if (to == TicketStatus.inProgress && (t.status == TicketStatus.review || t.status == TicketStatus.done) && widget.admin) {
      note = await _askText(title: 'Rouvrir le ticket', hint: 'Ce qu\'il reste à faire (facultatif)');
      if (note == null) return;
    } else if (to == TicketStatus.cancelled) {
      note = await _askText(title: 'Annuler le ticket', hint: 'Motif (facultatif)');
      if (note == null) return;
    }
    await _run(() => TicketsApi.instance.changeStatus(t.id, to, note: note == null || note.isEmpty ? null : note));
  }

  Future<String?> _askText({required String title, required String hint, bool required = false}) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLines: 3,
          maxLength: 1000,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Retour')),
          FilledButton(
            onPressed: () {
              if (required && c.text.trim().length < 3) return;
              Navigator.pop(ctx, c.text.trim());
            },
            child: const Text('Confirmer'),
          ),
        ],
      ),
    );
  }

  Future<void> _addFile() async {
    final f = await widget.pickFile?.call(context);
    if (f == null) return;
    if (f.bytes.length > 10 * 1024 * 1024) return _snack('Fichier trop lourd (10 Mo maximum).');
    setState(() => _pending.add(f));
  }

  Future<void> _send(Ticket t) async {
    final text = _reply.text.trim();
    if (text.isEmpty && _pending.isEmpty) return;
    await _run(() async {
      final id = await TicketsApi.instance.comment(t.id, text.isEmpty ? '📎 Pièce jointe' : text, internal: _internal);
      for (final f in List.of(_pending)) {
        await TicketsApi.instance.attach(t.id, f, commentId: id);
        _pending.remove(f);
      }
      _reply.clear();
      _internal = false;
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) Navigator.pop(context, _changed);
    },
    child: FutureBuilder<TicketDetail>(
      future: _future,
      builder: (context, snap) {
        final d = snap.data;
        return Scaffold(
          appBar: AppBar(
            title: Text(d == null ? 'Ticket' : '${d.ticket.key} · ${d.ticket.title}', overflow: TextOverflow.ellipsis),
            actions: [
              if (d != null && widget.onEdit != null)
                IconButton(
                  tooltip: 'Modifier',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () async {
                    if (await widget.onEdit!(context, d.ticket)) {
                      _changed = true;
                      _reload();
                    }
                  },
                ),
              IconButton(tooltip: 'Actualiser', onPressed: _reload, icon: const Icon(Icons.refresh)),
            ],
          ),
          body: snap.hasError
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('Ticket introuvable ou module désactivé.\n${snap.error}', textAlign: TextAlign.center),
                  ),
                )
              : d == null
              ? const Center(child: CircularProgressIndicator())
              : _body(d),
        );
      },
    ),
  );

  Widget _body(TicketDetail d) {
    final t = d.ticket;
    final moves = [
      for (final s in TicketStatus.values)
        if (canMoveTicket(t.status, s, admin: widget.admin)) s,
    ];
    // Employé : actions principales seulement ; admin : menu complet.
    return Column(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _header(t),
                  if (t.status == TicketStatus.blocked && t.blockedReason != null) ...[
                    const SizedBox(height: 10),
                    SoftCard(
                      color: AppColors.badSoft,
                      child: ListTile(
                        leading: const Icon(Icons.block, color: AppColors.bad),
                        title: const Text('Bloqué'),
                        subtitle: Text(t.blockedReason!),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  _actions(t, moves),
                  if ((t.description ?? '').isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text('Description', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 4),
                    SelectableText(t.description!),
                  ],
                  if (d.files.isNotEmpty) ...[const SizedBox(height: 12), _Files(d.files)],
                  const Divider(height: 32),
                  Text('Activité', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  for (final a in d.activity) _ActivityRow(a),
                ],
              ),
            ),
          ),
        ),
        if (!t.status.closed || widget.admin) _composer(t),
      ],
    );
  }

  Widget _header(Ticket t) {
    final df = DateFormat('d MMM yyyy', 'fr_FR');
    final small = Theme.of(context).textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TicketStatusChip(t.status),
            TicketPriorityBadge(t.priority),
            Text(ticketTypes[t.type] ?? t.type, style: small),
            TicketSourceBadge(t),
            if (t.overdue)
              const Text(
                'En retard',
                style: TextStyle(color: AppColors.bad, fontWeight: FontWeight.w600, fontSize: 12),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(t.title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            _info(Icons.person_outline, t.assigneeName ?? 'Non assigné'),
            if (t.dueDate != null) _info(Icons.event_outlined, 'Échéance ${df.format(t.dueDate!)}'),
            _info(Icons.schedule, 'Créé le ${df.format(t.createdAt)}${t.createdByName == null ? '' : ' par ${t.createdByName}'}'),
            if (t.companyName != null && widget.admin) _info(Icons.apartment_outlined, t.companyName!),
          ],
        ),
        if (t.externalUrl != null)
          TextButton.icon(
            onPressed: () => launchUrl(Uri.parse(t.externalUrl!), mode: LaunchMode.externalApplication),
            icon: const Icon(Icons.open_in_new, size: 16),
            label: Text('Ouvrir dans ${t.sourceLabel}${t.externalId == null ? '' : ' (#${t.externalId})'}'),
          ),
      ],
    );
  }

  Widget _info(IconData icon, String text) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 16, color: Theme.of(context).colorScheme.outline),
      const SizedBox(width: 4),
      Text(text, style: Theme.of(context).textTheme.bodySmall),
    ],
  );

  Widget _actions(Ticket t, List<TicketStatus> moves) {
    if (moves.isEmpty) {
      return Text(
        t.status == TicketStatus.review ? "En attente de validation par l'administrateur." : 'Aucune action possible.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    // Bouton principal : l'étape suivante logique.
    final next = switch (t.status) {
      TicketStatus.todo || TicketStatus.blocked => TicketStatus.inProgress,
      TicketStatus.inProgress => widget.admin ? TicketStatus.done : TicketStatus.review,
      TicketStatus.review => TicketStatus.done,
      _ => null,
    };
    final primary = next != null && moves.contains(next) ? next : null;
    final others = moves.where((s) => s != primary).toList();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (primary != null)
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: _busy ? null : () => _move(t, primary),
            icon: Icon(primary.icon),
            label: Text(ticketActionLabel(t.status, primary, admin: widget.admin)),
          ),
        if (!widget.admin)
          for (final s in others)
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: _busy ? null : () => _move(t, s),
              icon: Icon(s.icon),
              label: Text(ticketActionLabel(t.status, s, admin: false)),
            )
        else if (others.isNotEmpty)
          PopupMenuButton<TicketStatus>(
            enabled: !_busy,
            tooltip: 'Changer le statut',
            onSelected: (s) => _move(t, s),
            itemBuilder: (_) => [
              for (final s in others)
                PopupMenuItem(
                  value: s,
                  child: ListTile(leading: Icon(s.icon), title: Text(s.label), dense: true),
                ),
            ],
            child: const Chip(avatar: Icon(Icons.swap_horiz, size: 18), label: Text('Changer le statut')),
          ),
      ],
    );
  }

  Widget _composer(Ticket t) {
    final wide = MediaQuery.sizeOf(context).width >= 600;
    final sending = _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send);
    return Material(
      elevation: 6,
      child: SafeArea(
        top: false,
        // Même largeur que la fiche : le bouton Envoyer reste à côté du champ sur grand écran.
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_pending.isNotEmpty)
                    Wrap(
                      spacing: 6,
                      children: [
                        for (final f in _pending)
                          InputChip(
                            label: Text(f.name, overflow: TextOverflow.ellipsis),
                            onDeleted: () => setState(() => _pending.remove(f)),
                          ),
                      ],
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (widget.pickFile != null)
                        IconButton(tooltip: 'Joindre une photo ou un fichier', onPressed: _busy ? null : _addFile, icon: const Icon(Icons.attach_file)),
                      Expanded(
                        child: CallbackShortcuts(
                          bindings: {const SingleActivator(LogicalKeyboardKey.enter, control: true): () => _busy ? null : _send(t)},
                          child: TextField(
                            controller: _reply,
                            minLines: 1,
                            maxLines: 5,
                            maxLength: 5000,
                            decoration: InputDecoration(
                              hintText: _internal ? 'Note interne (invisible pour l\'employé)…' : 'Écrire un commentaire…',
                              counterText: '',
                              isDense: true,
                              filled: _internal,
                              fillColor: AppColors.warnSoft,
                            ),
                            style: _internal ? const TextStyle(color: AppColors.onSoft) : null,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (wide)
                        FilledButton.icon(
                          style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                          onPressed: _busy ? null : () => _send(t),
                          icon: sending,
                          label: Text(_internal ? 'Ajouter la note' : 'Envoyer'),
                        )
                      else
                        IconButton.filled(tooltip: 'Envoyer', onPressed: _busy ? null : () => _send(t), icon: sending),
                    ],
                  ),
                  if (wide)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text('Ctrl + Entrée pour envoyer', style: Theme.of(context).textTheme.bodySmall),
                    ),
                  if (widget.admin)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilterChip(
                        selected: _internal,
                        onSelected: (v) => setState(() => _internal = v),
                        avatar: const Icon(Icons.lock_outline, size: 16),
                        label: const Text('Note interne'),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Ligne du fil : commentaire (bulle) ou événement (texte discret).
class _ActivityRow extends StatelessWidget {
  final TicketActivity a;
  const _ActivityRow(this.a);

  String get _event {
    final who = a.actorName ?? 'Système externe';
    return switch (a.kind) {
      'created' => '$who a créé le ticket',
      'assigned' => a.toValue == null ? '$who a retiré l\'assignation' : '$who a assigné à ${a.toValue}',
      'status' => '$who : ${TicketStatus.of(a.fromValue).label} → ${TicketStatus.of(a.toValue).label}${a.note == null ? '' : ' — ${a.note}'}',
      'updated' => '$who a modifié ${a.note ?? 'le ticket'}',
      _ => who,
    };
  }

  @override
  Widget build(BuildContext context) {
    final when = DateFormat('d MMM HH:mm', 'fr_FR').format(a.at);
    final small = Theme.of(context).textTheme.bodySmall;
    if (!a.isComment) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              a.kind == 'status'
                  ? Icons.swap_horiz
                  : a.kind == 'assigned'
                  ? Icons.person_outline
                  : Icons.history,
              size: 16,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(_event, style: small)),
            Text(when, style: small),
          ],
        ),
      );
    }
    final internal = a.kind == 'note';
    final bubble = internal ? AppColors.warnSoft : Theme.of(context).colorScheme.surfaceContainerHighest;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: bubble, borderRadius: BorderRadius.circular(10)),
        child: DefaultTextStyle.merge(
          style: internal ? const TextStyle(color: AppColors.onSoft) : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (internal)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Icon(Icons.lock_outline, size: 14, color: AppColors.onSoft),
                    ),
                  Expanded(
                    child: Text(
                      '${a.actorName ?? 'Système externe'}${internal ? ' · note interne' : ''}',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                  ),
                  Text(when, style: TextStyle(fontSize: 12, color: internal ? AppColors.onSoft : null)),
                ],
              ),
              const SizedBox(height: 4),
              SelectableText(a.body ?? ''),
              if (a.files.isNotEmpty) ...[const SizedBox(height: 8), _Files(a.files)],
            ],
          ),
        ),
      ),
    );
  }
}

/// Pièces jointes : vignettes pour les images, lien pour les autres fichiers (lien signé, 10 min).
class _Files extends StatelessWidget {
  final List<TicketAttachment> files;
  const _Files(this.files);

  Future<void> _open(TicketAttachment f) async {
    final url = await TicketsApi.instance.fileUrl(f.path);
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final f in files)
        if (f.isImage)
          FutureBuilder<String>(
            future: TicketsApi.instance.fileUrl(f.path),
            builder: (_, s) => InkWell(
              onTap: () => _open(f),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: s.hasData
                    ? Image.network(
                        s.data!,
                        width: 110,
                        height: 110,
                        fit: BoxFit.cover,
                        errorBuilder: (ctx, error, stack) => const SizedBox(width: 110, height: 110, child: Icon(Icons.broken_image_outlined)),
                      )
                    : const SizedBox(width: 110, height: 110, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
              ),
            ),
          )
        else
          ActionChip(avatar: const Icon(Icons.description_outlined, size: 18), label: Text(f.fileName), onPressed: () => _open(f)),
    ],
  );
}
