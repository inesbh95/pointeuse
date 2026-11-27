// Module Tickets : modèles, accès serveur et petits éléments d'affichage.
// Fichier identique dans app/ et admin_web/ (à regrouper plus tard dans un package commun).
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/api.dart';
import '../theme.dart';

const ticketsModule = 'tickets';

// -----------------------------------------------------------------------------
// Statuts, types, priorités
// -----------------------------------------------------------------------------
enum TicketStatus {
  todo('todo', 'À faire', Icons.radio_button_unchecked),
  inProgress('in_progress', 'En cours', Icons.timelapse),
  blocked('blocked', 'Bloqué', Icons.block),
  review('review', 'En revue', Icons.rate_review_outlined),
  done('done', 'Terminé', Icons.check_circle_outline),
  cancelled('cancelled', 'Annulé', Icons.cancel_outlined);

  final String value;
  final String label;
  final IconData icon;
  const TicketStatus(this.value, this.label, this.icon);

  static TicketStatus of(String? v) => values.firstWhere((s) => s.value == v, orElse: () => todo);

  bool get closed => this == done || this == cancelled;

  /// Couleurs (fond pastel, texte foncé).
  ({Color fg, Color bg}) get colors => switch (this) {
        todo => (fg: const Color(0xFF3D4B4B), bg: const Color(0xFFE7ECEC)),
        inProgress => (fg: const Color(0xFF1F5A8A), bg: const Color(0xFFE1EDF8)),
        blocked => (fg: AppColors.bad, bg: AppColors.badSoft),
        review => (fg: AppColors.warn, bg: AppColors.warnSoft),
        done => (fg: AppColors.ok, bg: AppColors.okSoft),
        cancelled => (fg: const Color(0xFF6B7070), bg: const Color(0xFFEDEDED)),
      };
}

/// Transitions autorisées : même tableau que ticket_transition_allowed() en base.
/// L'admin peut tout faire ; l'employé assigné suit le parcours.
bool canMoveTicket(TicketStatus from, TicketStatus to, {required bool admin}) {
  if (from == to) return false;
  if (admin) return true;
  return switch ((from, to)) {
    (TicketStatus.todo, TicketStatus.inProgress) => true,
    (TicketStatus.inProgress, TicketStatus.blocked) => true,
    (TicketStatus.inProgress, TicketStatus.review) => true,
    (TicketStatus.blocked, TicketStatus.inProgress) => true,
    (TicketStatus.review, TicketStatus.inProgress) => true,
    _ => false,
  };
}

/// Libellé du bouton qui mène à ce statut, selon le statut actuel.
String ticketActionLabel(TicketStatus from, TicketStatus to, {required bool admin}) => switch (to) {
      TicketStatus.inProgress => from == TicketStatus.todo
          ? 'Démarrer'
          : from == TicketStatus.blocked
              ? 'Reprendre'
              : 'Rouvrir',
      TicketStatus.blocked => 'Signaler un blocage',
      TicketStatus.review => 'Terminer',
      TicketStatus.done => admin && from == TicketStatus.review ? 'Valider' : 'Marquer terminé',
      TicketStatus.cancelled => 'Annuler le ticket',
      TicketStatus.todo => 'Remettre à faire',
    };

const ticketTypes = {'task': 'Tâche', 'incident': 'Incident', 'request': 'Demande', 'bug': 'Anomalie'};
const ticketPriorities = {'low': 'Basse', 'normal': 'Normale', 'high': 'Haute', 'urgent': 'Urgente'};

Color priorityColor(String p) => switch (p) {
      'urgent' => AppColors.bad,
      'high' => AppColors.accent,
      'low' => Colors.blueGrey,
      _ => const Color(0xFF5E6B6B),
    };

IconData priorityIcon(String p) => switch (p) {
      'urgent' => Icons.keyboard_double_arrow_up,
      'high' => Icons.keyboard_arrow_up,
      'low' => Icons.keyboard_arrow_down,
      _ => Icons.drag_handle,
    };

// -----------------------------------------------------------------------------
// Modèles
// -----------------------------------------------------------------------------
DateTime? _t(Object? v) => v == null ? null : DateTime.parse(v as String).toLocal();

class Ticket {
  final String id;
  final String companyId;
  final String? companyName;
  final int number;
  final String title;
  final String? description;
  final String type;
  final String priority;
  final TicketStatus status;
  final String? assigneeId;
  final String? assigneeName;
  final DateTime? dueDate;
  final String? blockedReason;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? createdByName;
  final String source;
  final String? externalId;
  final String? externalUrl;

  const Ticket({
    required this.id, required this.companyId, this.companyName, required this.number, required this.title, this.description,
    required this.type, required this.priority, required this.status, this.assigneeId, this.assigneeName, this.dueDate,
    this.blockedReason, required this.createdAt, required this.updatedAt, this.createdByName,
    this.source = 'internal', this.externalId, this.externalUrl,
  });

  String get key => 'TK-$number';
  bool get imported => source != 'internal';
  String get sourceLabel => switch (source) { 'odoo' => 'Odoo', 'jira' => 'Jira', 'api' => 'API', _ => source };

  /// En retard : échéance passée et ticket non clos.
  bool get overdue {
    if (dueDate == null || status.closed) return false;
    final n = DateTime.now();
    return dueDate!.isBefore(DateTime(n.year, n.month, n.day));
  }

  static const select = '*, company:companies(name), '
      'assignee:profiles!ticket_tickets_assignee_id_fkey(full_name), '
      'creator:profiles!ticket_tickets_created_by_fkey(full_name)';

  factory Ticket.fromJson(Map<String, dynamic> j) => Ticket(
        id: j['id'] as String,
        companyId: j['company_id'] as String,
        companyName: (j['company'] as Map?)?['name'] as String?,
        number: (j['number'] as num).toInt(),
        title: j['title'] as String,
        description: j['description'] as String?,
        type: j['type'] as String? ?? 'task',
        priority: j['priority'] as String? ?? 'normal',
        status: TicketStatus.of(j['status'] as String?),
        assigneeId: j['assignee_id'] as String?,
        assigneeName: (j['assignee'] as Map?)?['full_name'] as String?,
        dueDate: j['due_date'] == null ? null : DateTime.parse(j['due_date'] as String),
        blockedReason: j['blocked_reason'] as String?,
        createdAt: _t(j['created_at'])!,
        updatedAt: _t(j['updated_at'])!,
        createdByName: (j['creator'] as Map?)?['full_name'] as String?,
        source: j['source'] as String? ?? 'internal',
        externalId: j['external_id'] as String?,
        externalUrl: j['external_url'] as String?,
      );
}

class TicketAttachment {
  final String id;
  final String? commentId;
  final String path;
  final String fileName;
  final String? mime;
  final int? size;
  const TicketAttachment({required this.id, this.commentId, required this.path, required this.fileName, this.mime, this.size});

  bool get isImage => (mime ?? '').startsWith('image/');

  factory TicketAttachment.fromJson(Map<String, dynamic> j) => TicketAttachment(
        id: j['id'] as String,
        commentId: j['comment_id'] as String?,
        path: j['storage_path'] as String,
        fileName: j['file_name'] as String,
        mime: j['mime'] as String?,
        size: (j['size_bytes'] as num?)?.toInt(),
      );
}

/// Élément du fil d'un ticket : commentaire, note interne ou événement (statut, assignation…).
class TicketActivity {
  final String id;
  final String kind; // comment | note | created | assigned | status | updated
  final String? actorName; // null = système externe (API)
  final String? body; // texte du commentaire
  final String? fromValue;
  final String? toValue;
  final String? note;
  final DateTime at;
  final List<TicketAttachment> files;
  const TicketActivity({required this.id, required this.kind, this.actorName, this.body, this.fromValue, this.toValue, this.note, required this.at, this.files = const []});

  bool get isComment => kind == 'comment' || kind == 'note';
}

class TicketDetail {
  final Ticket ticket;
  final List<TicketActivity> activity; // du plus ancien au plus récent
  final List<TicketAttachment> files; // pièces jointes du ticket lui-même (hors commentaires)
  const TicketDetail(this.ticket, this.activity, this.files);
}

/// Fichier choisi par l'utilisateur (photo, PDF…).
class PickedTicketFile {
  final String name;
  final String mime;
  final Uint8List bytes;
  const PickedTicketFile(this.name, this.mime, this.bytes);
}

// -----------------------------------------------------------------------------
// Accès serveur
// -----------------------------------------------------------------------------
class TicketsApi {
  TicketsApi._();
  static final instance = TicketsApi._();

  SupabaseClient get _db => Supabase.instance.client;
  String get _uid => _db.auth.currentUser!.id;

  Future<T> _rpc<T>(String fn, Map<String, dynamic> params) async {
    try {
      return await _db.rpc(fn, params: params) as T;
    } on PostgrestException catch (e) {
      throw ApiError(e.message);
    }
  }

  /// Admin : tickets de l'entreprise ([companyId] null = toutes, super-admin). Les clos de plus de 30 jours sont omis.
  Future<List<Ticket>> companyTickets({String? companyId}) async {
    final since = DateTime.now().subtract(const Duration(days: 30)).toUtc().toIso8601String();
    var q = _db.from('ticket_tickets').select(Ticket.select).or('status.not.in.(done,cancelled),updated_at.gte.$since');
    if (companyId != null) q = q.eq('company_id', companyId);
    final rows = await q.order('updated_at', ascending: false).limit(500);
    return rows.map(Ticket.fromJson).toList();
  }

  /// Employé : les tickets qui lui sont assignés (clos : 30 derniers jours).
  Future<List<Ticket>> myTickets() async {
    final since = DateTime.now().subtract(const Duration(days: 30)).toUtc().toIso8601String();
    final rows = await _db.from('ticket_tickets').select(Ticket.select).eq('assignee_id', _uid)
        .or('status.not.in.(done,cancelled),updated_at.gte.$since')
        .order('updated_at', ascending: false).limit(200);
    return rows.map(Ticket.fromJson).toList();
  }

  /// Nombre de tickets « À faire » assignés à l'utilisateur (pastille du menu).
  Future<int> myTodoCount() async {
    final res = await _db.from('ticket_tickets').select('id').eq('assignee_id', _uid).eq('status', 'todo').count(CountOption.exact);
    return res.count;
  }

  Future<TicketDetail> detail(String id) async {
    final t = Ticket.fromJson(await _db.from('ticket_tickets').select(Ticket.select).eq('id', id).single());
    final comments = await _db.from('ticket_comments')
        .select('id, body, is_internal, created_at, author:profiles!ticket_comments_author_id_fkey(full_name)')
        .eq('ticket_id', id).order('created_at');
    final events = await _db.from('ticket_events')
        .select('id, kind, from_value, to_value, note, created_at, actor:profiles!ticket_events_actor_id_fkey(full_name)')
        .eq('ticket_id', id).inFilter('kind', ['created', 'assigned', 'status', 'updated']).order('created_at');
    final files = (await _db.from('ticket_attachments').select().eq('ticket_id', id).order('created_at'))
        .map(TicketAttachment.fromJson).toList();

    final activity = <TicketActivity>[
      for (final c in comments)
        TicketActivity(
          id: c['id'] as String,
          kind: c['is_internal'] == true ? 'note' : 'comment',
          actorName: (c['author'] as Map?)?['full_name'] as String?,
          body: c['body'] as String,
          at: _t(c['created_at'])!,
          files: files.where((f) => f.commentId == c['id']).toList(),
        ),
      for (final e in events)
        TicketActivity(
          id: e['id'] as String,
          kind: e['kind'] as String,
          actorName: (e['actor'] as Map?)?['full_name'] as String?,
          fromValue: e['from_value'] as String?,
          toValue: e['to_value'] as String?,
          note: e['note'] as String?,
          at: _t(e['created_at'])!,
        ),
    ]..sort((a, b) => a.at.compareTo(b.at));
    return TicketDetail(t, activity, files.where((f) => f.commentId == null).toList());
  }

  /// Admin : crée ([id] null) ou modifie un ticket. Renvoie son identifiant.
  Future<String> save({
    String? id, required String companyId, required String title, String? description, required String type,
    required String priority, String? assigneeId, DateTime? dueDate,
  }) =>
      _rpc<String>('ticket_save', {
        'p_id': id, 'p_company': companyId, 'p_title': title, 'p_description': description, 'p_type': type,
        'p_priority': priority, 'p_assignee': assigneeId,
        'p_due': dueDate == null ? null : '${dueDate.year}-${dueDate.month.toString().padLeft(2, '0')}-${dueDate.day.toString().padLeft(2, '0')}',
      });

  Future<void> changeStatus(String id, TicketStatus status, {String? note}) =>
      _rpc<dynamic>('ticket_change_status', {'p_ticket': id, 'p_status': status.value, 'p_note': note});

  Future<String> comment(String id, String body, {bool internal = false}) =>
      _rpc<String>('ticket_add_comment', {'p_ticket': id, 'p_body': body, 'p_internal': internal});

  /// Dépose le fichier (dossier du ticket) puis l'enregistre, rattaché au commentaire si [commentId].
  Future<void> attach(String ticketId, PickedTicketFile f, {String? commentId}) async {
    final safe = f.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final path = '$ticketId/${DateTime.now().millisecondsSinceEpoch}_${safe.length > 80 ? safe.substring(safe.length - 80) : safe}';
    try {
      await _db.storage.from('ticket-files').uploadBinary(path, f.bytes, fileOptions: FileOptions(contentType: f.mime));
    } on StorageException catch (e) {
      throw ApiError(e.statusCode == '413' ? 'Fichier trop lourd (10 Mo maximum).' : "Envoi du fichier impossible : ${e.message}");
    }
    await _rpc<dynamic>('ticket_add_attachment', {
      'p_ticket': ticketId, 'p_comment': commentId, 'p_path': path, 'p_name': f.name, 'p_mime': f.mime, 'p_size': f.bytes.length,
    });
  }

  Future<String> fileUrl(String path) => _db.storage.from('ticket-files').createSignedUrl(path, 600);
}

// -----------------------------------------------------------------------------
// Affichage
// -----------------------------------------------------------------------------
class TicketStatusChip extends StatelessWidget {
  final TicketStatus status;
  const TicketStatusChip(this.status, {super.key});
  @override
  Widget build(BuildContext context) {
    final c = status.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.bg, borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(status.icon, size: 13, color: c.fg),
        const SizedBox(width: 4),
        Text(status.label, style: TextStyle(color: c.fg, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

class TicketPriorityBadge extends StatelessWidget {
  final String priority;
  final bool withLabel;
  const TicketPriorityBadge(this.priority, {super.key, this.withLabel = true});
  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Priorité ${ticketPriorities[priority]?.toLowerCase() ?? priority}',
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(priorityIcon(priority), size: 16, color: priorityColor(priority)),
          if (withLabel) Text(ticketPriorities[priority] ?? priority, style: TextStyle(fontSize: 12, color: priorityColor(priority))),
        ]),
      );
}

/// Petite pastille « Odoo », « API »… pour les tickets importés.
class TicketSourceBadge extends StatelessWidget {
  final Ticket ticket;
  const TicketSourceBadge(this.ticket, {super.key});
  @override
  Widget build(BuildContext context) => !ticket.imported
      ? const SizedBox.shrink()
      : Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(border: Border.all(color: Theme.of(context).colorScheme.outline), borderRadius: BorderRadius.circular(6)),
          child: Text(ticket.sourceLabel, style: const TextStyle(fontSize: 11)),
        );
}
