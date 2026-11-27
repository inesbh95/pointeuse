import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models.dart';

/// Erreur lisible par l'utilisateur.
class ApiError implements Exception {
  final String message;
  ApiError(this.message);
  @override
  String toString() => message;
}

class Api {
  Api._();
  static final instance = Api._();

  SupabaseClient get _db => Supabase.instance.client;
  String get uid => _db.auth.currentUser!.id;

  /// Incrémenté quand le profil ou les options de l'entreprise changent : l'écran d'accueil se recharge.
  final profileVersion = ValueNotifier<int>(0);

  // ---------- Session ----------
  Future<void> signIn(String email, String password) async {
    try {
      await _db.auth.signInWithPassword(email: email.trim(), password: password);
    } on AuthException catch (e) {
      throw ApiError(e.message.contains('Invalid') ? 'E-mail ou mot de passe incorrect.' : e.message);
    }
  }

  Future<void> signOut() => _db.auth.signOut();

  /// Vérifie le mot de passe actuel avant de le remplacer.
  Future<void> changePassword(String current, String next) async {
    final email = _db.auth.currentUser!.email!;
    try {
      await _db.auth.signInWithPassword(email: email, password: current);
    } on AuthException {
      throw ApiError('Mot de passe actuel incorrect.');
    }
    try {
      await _db.auth.updateUser(UserAttributes(password: next));
    } on AuthException catch (e) {
      throw ApiError(e.message.toLowerCase().contains('different') ? 'Choisissez un mot de passe différent de l\'actuel.' : 'Changement impossible : ${e.message}');
    }
  }

  Future<Profile> me() async {
    final row = await _db.from('profiles').select('*, company:companies(name, sites_enabled, company_modules(module_key, enabled))').eq('id', uid).single();
    return Profile.fromJson(row);
  }

  // ---------- Fonctions serveur ----------
  Future<Map<String, dynamic>> _invoke(String fn, Map<String, dynamic> body) async {
    try {
      final res = await _db.functions.invoke(fn, body: body);
      return Map<String, dynamic>.from(res.data as Map);
    } on FunctionException catch (e) {
      final d = e.details;
      final msg = d is Map && d['error'] is Map ? d['error']['message'] as String? : null;
      throw ApiError(msg ?? 'Erreur du serveur (${e.status}). Réessayez.');
    } catch (e) {
      if (e is ApiError) rethrow;
      throw ApiError('Pas de connexion au serveur. Vérifiez internet et réessayez.');
    }
  }

  Future<({String id, String nonce})> challenge() async {
    final j = await _invoke('punch-challenge', {});
    return (id: j['challengeId'] as String, nonce: j['nonce'] as String);
  }

  Future<PunchResult> punch(Map<String, dynamic> payload) async => PunchResult.fromJson(await _invoke('punch', payload));

  Future<String> enrollFace(String userId, List<List<double>> embeddings) async {
    final j = await _invoke('enroll-face', {'userId': userId, 'embeddings': embeddings});
    return j['name'] as String;
  }

  /// [companyId] : réservé au super-admin ; un admin crée toujours dans sa propre entreprise.
  Future<void> createEmployee({required String email, required String password, required String fullName, required String matricule, bool admin = false, String? companyId}) =>
      _invoke('create-employee', {
        'email': email, 'password': password, 'fullName': fullName, 'matricule': matricule,
        'role': admin ? 'admin' : 'employee', if (companyId != null) 'companyId': companyId,
      });

  // ---------- Photos ----------
  Future<String> uploadPhoto(Uint8List jpeg) async {
    final now = DateTime.now();
    final path = '$uid/${now.millisecondsSinceEpoch}.jpg';
    await _db.storage.from('punch-photos').uploadBinary(path, jpeg, fileOptions: const FileOptions(contentType: 'image/jpeg'));
    return path;
  }

  Future<String> photoUrl(String path) => _db.storage.from('punch-photos').createSignedUrl(path, 600);

  // ---------- Pointages ----------
  static const _punchCols = '*, sites(client, name), profiles!punches_user_id_fkey(full_name, matricule)';

  Future<List<Punch>> myPunches({int limit = 60}) async {
    final rows = await _db.from('punches').select(_punchCols).eq('user_id', uid).order('server_ts', ascending: false).limit(limit);
    return rows.map(Punch.fromJson).toList();
  }

  Future<Punch?> lastValidPunchToday() async {
    final start = DateTime.now();
    final dayStart = DateTime(start.year, start.month, start.day).toUtc().toIso8601String();
    final rows = await _db.from('punches').select(_punchCols).eq('user_id', uid).neq('status', 'blocked')
        .gte('server_ts', dayStart).order('server_ts', ascending: false).limit(1);
    return rows.isEmpty ? null : Punch.fromJson(rows.first);
  }

  /// Types ('in' / 'out') des pointages acceptés aujourd'hui (pour ne pas rappeler un pointage déjà fait).
  Future<Set<String>> todayPunchTypes() async {
    final n = DateTime.now();
    final rows = await _db.from('punches').select('type').eq('user_id', uid).neq('status', 'blocked')
        .gte('server_ts', DateTime(n.year, n.month, n.day).toUtc().toIso8601String());
    return rows.map((r) => r['type'] as String).toSet();
  }

  /// Pointages de l'équipe (admin). [filter] : 'review' | 'blocked' | 'all'
  /// [companyId] : filtre du super-admin (null = toutes les entreprises).
  Future<List<Punch>> teamPunches(String filter, {int days = 7, String? companyId}) async {
    final since = DateTime.now().subtract(Duration(days: days)).toUtc().toIso8601String();
    var q = _db.from('punches').select(_punchCols).gte('server_ts', since);
    if (companyId != null) q = q.eq('company_id', companyId);
    if (filter == 'review') q = q.eq('status', 'suspect').isFilter('review_decision', null);
    if (filter == 'blocked') q = q.eq('status', 'blocked');
    final rows = await q.order('server_ts', ascending: false).limit(200);
    return rows.map(Punch.fromJson).toList();
  }

  /// Tous les pointages entre deux dates (export Excel), du plus ancien au plus récent.
  Future<List<Punch>> punchesBetween(DateTime from, DateTime to, {String? companyId}) async {
    final out = <Punch>[];
    const page = 1000;
    for (var offset = 0;; offset += page) {
      var q = _db.from('punches').select('$_punchCols, company:companies(name)');
      if (companyId != null) q = q.eq('company_id', companyId);
      final rows = await q
          .gte('server_ts', from.toUtc().toIso8601String()).lt('server_ts', to.toUtc().toIso8601String())
          .order('server_ts').range(offset, offset + page - 1);
      out.addAll(rows.map(Punch.fromJson));
      if (rows.length < page) return out;
    }
  }

  Future<void> review(String punchId, {required bool approved, String? note}) async {
    await _db.from('punches').update({
      'review_decision': approved ? 'approved' : 'rejected',
      'review_note': note,
      'reviewed_by': uid,
      'reviewed_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', punchId);
  }

  // ---------- Sites ----------
  Future<List<Site>> sites() async {
    final rows = await _db.from('sites').select('*, company:companies(name)').eq('active', true).order('client');
    return rows.map(Site.fromJson).toList();
  }

  /// [companyId] : réservé au super-admin (sinon le site va dans l'entreprise de l'admin).
  Future<void> addSite({required String client, required String name, required double lat, required double lng, required int radiusM, String? companyId}) =>
      _db.from('sites').insert({'client': client, 'name': name, 'lat': lat, 'lng': lng, 'radius_m': radiusM, 'created_by': uid, if (companyId != null) 'company_id': companyId});

  Future<void> archiveSite(String id) => _db.from('sites').update({'active': false}).eq('id', id);

  // ---------- Employés ----------
  Future<List<Profile>> employees() async {
    final rows = await _db.from('profiles').select('*, company:companies(name, sites_enabled)').order('full_name');
    return rows.map(Profile.fromJson).toList();
  }

  // ---------- Entreprises (super-admin) ----------
  Future<List<Company>> companies() async {
    final rows = await _db.from('companies').select('id, name, active, profiles(count), company_modules(module_key, enabled)').order('name');
    return rows.map(Company.fromJson).toList();
  }

  Future<String> createCompany(String name) async {
    try {
      final row = await _db.from('companies').insert({'name': name.trim()}).select('id').single();
      return row['id'] as String;
    } on PostgrestException catch (e) {
      throw ApiError(e.code == '23505' ? 'Une entreprise porte déjà ce nom.' : 'Création impossible : ${e.message}');
    }
  }

  // ---------- Modules (activés par le super-admin) ----------
  Future<List<AppModuleInfo>> modules() async {
    final rows = await _db.from('modules').select('key, label, description').order('position');
    return rows.map(AppModuleInfo.fromJson).toList();
  }

  Future<void> setCompanyModule(String companyId, String module, bool enabled) =>
      _rpc<dynamic>('set_company_module', {'company': companyId, 'mod': module, 'enabled': enabled});

  // ---------- Rappels de pointage ----------
  // ---------- Option « gestion des sites clients » ----------
  Future<bool> sitesEnabled(String companyId) async {
    final row = await _db.from('companies').select('sites_enabled').eq('id', companyId).single();
    return row['sites_enabled'] as bool? ?? false;
  }

  Future<void> setSitesEnabled(String companyId, bool enabled) async {
    try {
      await _db.rpc('set_company_sites', params: {'company': companyId, 'enabled': enabled});
    } on PostgrestException catch (e) {
      throw ApiError(e.message);
    }
  }

  Future<NotifySettings> notifySettings(String companyId) async {
    final row = await _db.from('companies').select('notify_enabled, notify_in, notify_out, notify_days, late_grace_min').eq('id', companyId).single();
    return NotifySettings.fromJson(row);
  }

  Future<void> setNotifySettings(String companyId, NotifySettings s) async {
    try {
      // Horaires de travail + tolérance + rappels, en une fois.
      await _db.rpc('set_company_schedule', params: {
        'company': companyId,
        'time_in': NotifySettings.fmt(s.timeIn),
        'time_out': NotifySettings.fmt(s.timeOut),
        'days': (s.days.toList()..sort()),
        'grace': s.graceMin,
        'reminders': s.enabled,
      });
    } on PostgrestException catch (e) {
      throw ApiError(e.message);
    }
  }

  // ---------- Clés d'API (ERP) ----------
  /// Adresse de base de l'API pour les ERP.
  String get erpApiBase => '${Supabase.instance.client.rest.url.replaceFirst('/rest/v1', '')}/functions/v1/api/v1';

  Future<List<ApiKey>> apiKeys(String companyId) async {
    final rows = await _db.from('api_keys').select('id, label, prefix, created_at, last_used_at, revoked_at, scopes')
        .eq('company_id', companyId).order('created_at', ascending: false);
    return rows.map(ApiKey.fromJson).toList();
  }

  /// Crée une clé et la renvoie en clair : elle ne pourra plus jamais être relue.
  /// [ticketsWrite] : la clé peut aussi créer des tickets et y commenter (module Tickets).
  Future<String> createApiKey(String companyId, String label, {bool ticketsWrite = false}) async {
    try {
      return await _db.rpc('create_api_key', params: {'company': companyId, 'label': label, 'scopes': ['read', if (ticketsWrite) 'tickets:write']}) as String;
    } on PostgrestException catch (e) {
      throw ApiError(e.message);
    }
  }

  Future<void> revokeApiKey(String id) async {
    try {
      await _db.rpc('revoke_api_key', params: {'key_id': id});
    } on PostgrestException catch (e) {
      throw ApiError(e.message);
    }
  }

  // ---------- Webhooks (ERP) ----------
  Future<List<Webhook>> webhooks(String companyId) async {
    final rows = await _db.from('webhooks')
        .select('id, url, active, created_at, last_attempt_at, last_success_at, last_status, last_error')
        .eq('company_id', companyId).order('created_at');
    return rows.map(Webhook.fromJson).toList();
  }

  Future<T> _rpc<T>(String fn, Map<String, dynamic> params) async {
    try {
      return await _db.rpc(fn, params: params) as T;
    } on PostgrestException catch (e) {
      throw ApiError(e.message);
    }
  }

  /// Ajoute une adresse et renvoie le secret de signature (montré une seule fois).
  Future<String> createWebhook(String companyId, String url) => _rpc<String>('create_webhook', {'company': companyId, 'url': url});
  Future<void> setWebhookActive(String id, bool active) => _rpc<dynamic>('set_webhook_active', {'hook': id, 'enabled': active});
  Future<void> deleteWebhook(String id) => _rpc<dynamic>('delete_webhook', {'hook': id});
  Future<void> testWebhook(String id) => _rpc<dynamic>('test_webhook', {'hook': id});

  // ---------- Corrections de l'admin ----------
  static String _day(DateTime x) => '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';

  /// Pointage saisi à la main (oubli), toujours signalé « saisi par l'admin » avec le motif.
  Future<void> addManualPunch({required String userId, required String type, required DateTime at, required String reason}) =>
      _rpc<dynamic>('add_manual_punch', {'p_user': userId, 'p_type': type, 'p_ts': at.toUtc().toIso8601String(), 'p_reason': reason});

  /// Absences qui touchent la période (employés et jours fériés de l'entreprise).
  Future<List<Absence>> absences(String companyId, DateTime from, DateTime to) async {
    final rows = await _db.from('absences')
        .select('id, user_id, kind, start_date, end_date, note, employee:profiles!absences_user_id_fkey(full_name)')
        .eq('company_id', companyId).lte('start_date', _day(to)).gte('end_date', _day(from))
        .order('start_date');
    return rows.map(Absence.fromJson).toList();
  }

  /// [userId] null = toute l'entreprise (ex. jour férié).
  Future<void> addAbsence({required String companyId, String? userId, required String kind, required DateTime from, required DateTime to, String? note}) =>
      _rpc<dynamic>('add_absence', {'p_company': companyId, 'p_user': userId, 'p_kind': kind, 'p_from': _day(from), 'p_to': _day(to), 'p_note': note});

  Future<void> deleteAbsence(String id) => _rpc<dynamic>('delete_absence', {'p_id': id});

  // ---------- Feuilles de temps ----------
  /// Une ligne par employé et par jour (calcul serveur). [companyId] null = toutes (super-admin).
  Future<List<TimesheetRow>> timesheet(DateTime from, DateTime to, {String? companyId}) async {
    String d(DateTime x) => '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
    try {
      final rows = await _db.rpc('timesheet', params: {'p_company': companyId, 'p_from': d(from), 'p_to': d(to)}) as List;
      return rows.map((r) => TimesheetRow.fromJson(Map<String, dynamic>.from(r as Map))).toList();
    } on PostgrestException catch (e) {
      throw ApiError(e.message);
    }
  }

  Future<void> setCompanyActive(String id, bool active) => _db.from('companies').update({'active': active}).eq('id', id);

  Future<Set<String>> enrolledIds() async {
    final rows = await _db.from('face_templates').select('user_id');
    return rows.map((r) => r['user_id'] as String).toSet();
  }
}
