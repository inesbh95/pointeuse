class Profile {
  final String id;
  final String fullName;
  final String? matricule;
  final String role; // 'employee' | 'admin' | 'superadmin'
  final bool active;
  final String? companyId;
  final String? companyName;
  final bool sitesEnabled; // option de l'entreprise : gestion des sites clients
  const Profile({required this.id, required this.fullName, this.matricule, required this.role, required this.active, this.companyId, this.companyName, this.sitesEnabled = false});

  /// Admin de son entreprise, ou super-admin (toutes les entreprises).
  bool get isAdmin => role == 'admin' || role == 'superadmin';
  bool get isSuperAdmin => role == 'superadmin';

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
        id: j['id'] as String,
        fullName: (j['full_name'] ?? '') as String,
        matricule: j['matricule'] as String?,
        role: (j['role'] ?? 'employee') as String,
        active: (j['active'] ?? true) as bool,
        companyId: j['company_id'] as String?,
        companyName: (j['company'] as Map?)?['name'] as String?,
        sitesEnabled: (j['company'] as Map?)?['sites_enabled'] as bool? ?? false,
      );
}

class Company {
  final String id;
  final String name;
  final bool active;
  final int employees;
  const Company({required this.id, required this.name, required this.active, required this.employees});

  factory Company.fromJson(Map<String, dynamic> j) => Company(
        id: j['id'] as String,
        name: j['name'] as String,
        active: (j['active'] ?? true) as bool,
        employees: ((j['profiles'] as List?)?.firstOrNull as Map?)?['count'] as int? ?? 0,
      );
}

/// Rappels de pointage d'une entreprise.
class NotifySettings {
  final bool enabled;
  final ({int h, int m}) timeIn;
  final ({int h, int m}) timeOut;
  final Set<int> days; // ISO : 1 = lundi … 7 = dimanche
  final int graceMin; // tolérance de retard (minutes)
  const NotifySettings({required this.enabled, required this.timeIn, required this.timeOut, required this.days, this.graceMin = 5});

  static ({int h, int m}) _t(Object? v, int defH) {
    final p = (v as String? ?? '').split(':');
    return p.length >= 2 ? (h: int.parse(p[0]), m: int.parse(p[1])) : (h: defH, m: 0);
  }

  static String fmt(({int h, int m}) t) => '${t.h.toString().padLeft(2, '0')}:${t.m.toString().padLeft(2, '0')}';

  factory NotifySettings.fromJson(Map<String, dynamic> j) => NotifySettings(
        enabled: (j['notify_enabled'] ?? false) as bool,
        timeIn: _t(j['notify_in'], 8),
        timeOut: _t(j['notify_out'], 17),
        days: ((j['notify_days'] as List?) ?? const [1, 2, 3, 4, 5]).map((d) => (d as num).toInt()).toSet(),
        graceMin: (j['late_grace_min'] as num?)?.toInt() ?? 5,
      );
}

class Site {
  final String id;
  final String client;
  final String name;
  final double lat;
  final double lng;
  final int radiusM;
  final String? companyName; // affiché au super-admin
  const Site({required this.id, required this.client, required this.name, required this.lat, required this.lng, required this.radiusM, this.companyName});

  String get label => '$client — $name';

  factory Site.fromJson(Map<String, dynamic> j) => Site(
        id: j['id'] as String,
        client: j['client'] as String,
        name: j['name'] as String,
        lat: (j['lat'] as num).toDouble(),
        lng: (j['lng'] as num).toDouble(),
        radiusM: (j['radius_m'] as num).toInt(),
        companyName: (j['company'] as Map?)?['name'] as String?,
      );
}

class Flag {
  final String code;
  final String level; // 'block' | 'warn'
  final String label;
  const Flag(this.code, this.level, this.label);

  bool get blocks => level == 'block';

  factory Flag.fromJson(Map<String, dynamic> j) => Flag(j['code'] as String, j['level'] as String, j['label'] as String);
}

enum PunchStatus { ok, suspect, blocked }

PunchStatus statusFrom(String s) => switch (s) {
      'blocked' => PunchStatus.blocked,
      'suspect' => PunchStatus.suspect,
      _ => PunchStatus.ok,
    };

class Punch {
  final String id;
  final String userId;
  final String type; // 'in' | 'out'
  final DateTime serverTs;
  final double? lat;
  final double? lng;
  final double? accuracyM;
  final String? siteLabel;
  final int? siteDistanceM;
  final String? address;
  final PunchStatus status;
  final List<Flag> flags;
  final String? photoPath;
  final double? faceSimilarity;
  final String? employeeName;
  final String? employeeMatricule;
  final String? companyName;
  final String? reviewDecision;
  final String? reviewNote;
  final Map<String, dynamic>? ipInfo;
  final bool manual; // saisi par l'administrateur (oubli de pointage)
  final String? manualReason;

  const Punch({
    required this.id, required this.userId, required this.type, required this.serverTs,
    this.lat, this.lng, this.accuracyM, this.siteLabel, this.siteDistanceM, this.address,
    required this.status, required this.flags, this.photoPath, this.faceSimilarity,
    this.employeeName, this.employeeMatricule, this.companyName, this.reviewDecision, this.reviewNote, this.ipInfo,
    this.manual = false, this.manualReason,
  });

  bool get isIn => type == 'in';

  factory Punch.fromJson(Map<String, dynamic> j) {
    final site = j['sites'] as Map<String, dynamic>?;
    final prof = j['profiles'] as Map<String, dynamic>?;
    return Punch(
      id: j['id'] as String,
      userId: j['user_id'] as String,
      type: j['type'] as String,
      serverTs: DateTime.parse(j['server_ts'] as String).toLocal(),
      lat: (j['lat'] as num?)?.toDouble(),
      lng: (j['lng'] as num?)?.toDouble(),
      accuracyM: (j['accuracy_m'] as num?)?.toDouble(),
      siteLabel: site == null ? null : '${site['client']} — ${site['name']}',
      siteDistanceM: (j['site_distance_m'] as num?)?.toInt(),
      address: j['address'] as String?,
      status: statusFrom(j['status'] as String),
      flags: ((j['flags'] as List?) ?? []).map((f) => Flag.fromJson(Map<String, dynamic>.from(f as Map))).toList(),
      photoPath: j['photo_path'] as String?,
      faceSimilarity: (j['face_similarity'] as num?)?.toDouble(),
      employeeName: prof?['full_name'] as String?,
      employeeMatricule: prof?['matricule'] as String?,
      companyName: (j['company'] as Map?)?['name'] as String?,
      reviewDecision: j['review_decision'] as String?,
      reviewNote: j['review_note'] as String?,
      manual: j['manual'] as bool? ?? false,
      manualReason: j['manual_reason'] as String?,
      ipInfo: j['ip_info'] == null ? null : Map<String, dynamic>.from(j['ip_info'] as Map),
    );
  }
}

/// Un relevé GPS brut envoyé au serveur.
class Fix {
  final double lat, lng, acc;
  final int ts;
  final bool mocked;
  const Fix({required this.lat, required this.lng, required this.acc, required this.ts, required this.mocked});
  Map<String, dynamic> toJson() => {'lat': lat, 'lng': lng, 'acc': acc, 'ts': ts, 'mocked': mocked};
}

/// Résultat renvoyé par la fonction serveur « punch ».
class PunchResult {
  final PunchStatus status;
  final List<Flag> flags;
  final String? siteLabel;
  final int? siteDistance;
  final String? address;
  final DateTime serverTime;
  /// iPhone : réponse du serveur à la preuve App Attest ('ok', 'reattest' ou null).
  final String? appAttest;
  const PunchResult({required this.status, required this.flags, this.siteLabel, this.siteDistance, this.address, required this.serverTime, this.appAttest});

  factory PunchResult.fromJson(Map<String, dynamic> j) {
    final site = j['site'] as Map<String, dynamic>?;
    return PunchResult(
      status: statusFrom(j['status'] as String),
      flags: ((j['flags'] as List?) ?? []).map((f) => Flag.fromJson(Map<String, dynamic>.from(f as Map))).toList(),
      siteLabel: site == null ? null : '${site['client']} — ${site['name']}',
      siteDistance: (j['siteDistance'] as num?)?.toInt(),
      address: j['address'] as String?,
      serverTime: DateTime.parse(j['serverTime'] as String).toLocal(),
      appAttest: j['appAttest'] as String?,
    );
  }
}

/// Une ligne de feuille de temps : un employé, un jour (calculée par le serveur).
class TimesheetRow {
  final DateTime day;
  final String userId;
  final String? companyId;
  final String fullName;
  final String? matricule;
  final String? companyName;
  final DateTime? firstIn;
  final DateTime? lastOut;
  final int workedMin, expectedMin, lateMin, overtimeMin, punches;
  final String status; // complet | absent | justifie | sortie_manquante | entree_manquante | en_cours
  final String? absence; // type d'absence couvrant ce jour (voir Absence.kinds)
  final int manual; // pointages saisis par l'admin ce jour-là

  const TimesheetRow({
    required this.day, required this.userId, this.companyId, required this.fullName, this.matricule, this.companyName,
    this.firstIn, this.lastOut, required this.workedMin, required this.expectedMin,
    required this.lateMin, required this.overtimeMin, required this.punches, required this.status,
    this.absence, this.manual = 0,
  });

  static String hm(int min) => '${min ~/ 60} h ${(min % 60).toString().padLeft(2, '0')}';

  String get statusLabel => switch (status) {
        'complet' => 'Complet',
        'absent' => 'Absent',
        'justifie' => Absence.label(absence),
        'sortie_manquante' => 'Sortie manquante',
        'entree_manquante' => 'Entrée manquante',
        'en_cours' => 'En cours',
        _ => status,
      };

  factory TimesheetRow.fromJson(Map<String, dynamic> j) {
    DateTime? t(Object? v) => v == null ? null : DateTime.parse(v as String).toLocal();
    return TimesheetRow(
      day: DateTime.parse(j['day'] as String),
      userId: j['user_id'] as String,
      companyId: j['company_id'] as String?,
      fullName: (j['full_name'] ?? '') as String,
      matricule: j['matricule'] as String?,
      companyName: j['company_name'] as String?,
      firstIn: t(j['first_in']),
      lastOut: t(j['last_out']),
      workedMin: (j['worked_min'] as num).toInt(),
      expectedMin: (j['expected_min'] as num).toInt(),
      lateMin: (j['late_min'] as num).toInt(),
      overtimeMin: (j['overtime_min'] as num).toInt(),
      punches: (j['punches'] as num).toInt(),
      status: j['status'] as String,
      absence: j['absence'] as String?,
      manual: (j['manual'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Clé d'API d'une entreprise (la clé complète n'est jamais relue : seul son début est affiché).
class ApiKey {
  final String id;
  final String label;
  final String prefix;
  final DateTime createdAt;
  final DateTime? lastUsedAt;
  final DateTime? revokedAt;
  const ApiKey({required this.id, required this.label, required this.prefix, required this.createdAt, this.lastUsedAt, this.revokedAt});

  bool get active => revokedAt == null;

  factory ApiKey.fromJson(Map<String, dynamic> j) {
    DateTime? t(Object? v) => v == null ? null : DateTime.parse(v as String).toLocal();
    return ApiKey(
      id: j['id'] as String,
      label: j['label'] as String,
      prefix: j['prefix'] as String,
      createdAt: t(j['created_at'])!,
      lastUsedAt: t(j['last_used_at']),
      revokedAt: t(j['revoked_at']),
    );
  }
}

/// Webhook d'entreprise : adresse appelée à chaque pointage (le secret n'est jamais relu).
class Webhook {
  final String id;
  final String url;
  final bool active;
  final DateTime createdAt;
  final DateTime? lastAttemptAt;
  final DateTime? lastSuccessAt;
  final int? lastStatus;
  final String? lastError;
  const Webhook({required this.id, required this.url, required this.active, required this.createdAt,
      this.lastAttemptAt, this.lastSuccessAt, this.lastStatus, this.lastError});

  /// La dernière tentative a-t-elle réussi ? (null = jamais appelé)
  bool? get lastOk => lastAttemptAt == null ? null : lastError == null;

  factory Webhook.fromJson(Map<String, dynamic> j) {
    DateTime? t(Object? v) => v == null ? null : DateTime.parse(v as String).toLocal();
    return Webhook(
      id: j['id'] as String,
      url: j['url'] as String,
      active: j['active'] as bool,
      createdAt: t(j['created_at'])!,
      lastAttemptAt: t(j['last_attempt_at']),
      lastSuccessAt: t(j['last_success_at']),
      lastStatus: j['last_status'] as int?,
      lastError: j['last_error'] as String?,
    );
  }
}

/// Absence justifiée (congé, maladie…) d'un employé, ou de toute l'entreprise (jour férié).
class Absence {
  final String id;
  final String? userId; // null = toute l'entreprise
  final String? employeeName;
  final String kind;
  final DateTime start;
  final DateTime end;
  final String? note;
  const Absence({required this.id, this.userId, this.employeeName, required this.kind, required this.start, required this.end, this.note});

  static const kinds = ['conge_paye', 'maladie', 'sans_solde', 'mission', 'ferie', 'autre'];

  static String label(String? kind) => switch (kind) {
        'conge_paye' => 'Congé payé',
        'maladie' => 'Maladie',
        'sans_solde' => 'Congé sans solde',
        'mission' => 'Mission',
        'ferie' => 'Jour férié',
        'autre' => 'Absence justifiée',
        _ => 'Justifié',
      };

  factory Absence.fromJson(Map<String, dynamic> j) => Absence(
        id: j['id'] as String,
        userId: j['user_id'] as String?,
        employeeName: (j['employee'] as Map?)?['full_name'] as String?,
        kind: j['kind'] as String,
        start: DateTime.parse(j['start_date'] as String),
        end: DateTime.parse(j['end_date'] as String),
        note: j['note'] as String?,
      );
}
