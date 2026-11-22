import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models.dart';
import 'api.dart';

/// Rappels de pointage : programmés sur le téléphone selon les réglages de l'entreprise.
/// Ils sonnent même app fermée, sont reprogrammés à chaque ouverture de l'app et après chaque pointage,
/// et ne sonnent pas pour un pointage déjà fait aujourd'hui
/// (ils survivent à un redémarrage du téléphone).
class ReminderService {
  ReminderService._();
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static const _channel = AndroidNotificationDetails(
    'rappels_pointage',
    'Rappels de pointage',
    channelDescription: "Rappel à l'heure d'arrivée et de départ",
    importance: Importance.high,
    priority: Priority.high,
    category: AndroidNotificationCategory.reminder,
  );

  static Future<void> _init() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation((await FlutterTimezone.getLocalTimezone()).identifier));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('Africa/Tunis'));
    }
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(requestAlertPermission: false, requestBadgePermission: false, requestSoundPermission: false),
      ),
    );
    _ready = true;
  }

  /// Vrai quand les rappels sont actifs mais qu'Android ne les autorise qu'« approximatifs »
  /// (jusqu'à 1 h de retard) : l'écran d'accueil propose alors d'autoriser « Alarmes et rappels ».
  static final needsExactPermission = ValueNotifier<bool>(false);

  /// Ouvre le réglage Android « Alarmes et rappels », puis reprogramme.
  static Future<void> requestExact(String? companyId) async {
    await _init();
    await _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestExactAlarmsPermission();
    await sync(companyId);
  }

  /// Relit les réglages de l'entreprise et reprogramme les rappels des 4 prochaines semaines.
  static Future<void> sync(String? companyId) async {
    try {
      await _init();
      await _plugin.cancelAll();
      needsExactPermission.value = false;
      if (companyId == null) return;
      final s = await Api.instance.notifySettings(companyId);
      if (!s.enabled || s.days.isEmpty) return;

      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
      await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, sound: true);
      final exact = android == null || (await android.canScheduleExactNotifications() ?? false);
      needsExactPermission.value = !exact;
      final mode = exact ? AndroidScheduleMode.exactAllowWhileIdle : AndroidScheduleMode.inexactAllowWhileIdle;

      // Pointages déjà faits aujourd'hui : pas de rappel pour ceux-là.
      Set<String> done = const {};
      try {
        done = await Api.instance.todayPunchTypes();
      } catch (_) {}

      // Rappels ponctuels sur les 4 prochaines semaines (reprogrammés à chaque ouverture et après chaque pointage).
      final now = tz.TZDateTime.now(tz.local);
      for (var i = 0; i < _horizonDays; i++) {
        final d = tz.TZDateTime(tz.local, now.year, now.month, now.day + i);
        if (!s.days.contains(d.weekday)) continue;
        final today = i == 0;
        if (!(today && done.contains('in'))) {
          await _once(1000 + i * 2, d, s.timeIn, now, "Pointage d'arrivée", 'Il est ${NotifySettings.fmt(s.timeIn)} : pensez à pointer votre arrivée.', mode);
        }
        if (!(today && done.contains('out'))) {
          await _once(1001 + i * 2, d, s.timeOut, now, 'Pointage de départ', 'Il est ${NotifySettings.fmt(s.timeOut)} : pensez à pointer votre départ.', mode);
        }
      }
    } catch (e) {
      debugPrint('Rappels non programmés : $e');
    }
  }

  /// À la déconnexion : plus aucun rappel sur ce téléphone.
  static Future<void> clear() async {
    try {
      await _init();
      await _plugin.cancelAll();
    } catch (_) {}
  }

  static const _horizonDays = 28;

  static Future<void> _once(int id, tz.TZDateTime day, ({int h, int m}) t, tz.TZDateTime now, String title, String body, AndroidScheduleMode mode) async {
    final at = tz.TZDateTime(tz.local, day.year, day.month, day.day, t.h, t.m);
    if (!at.isAfter(now)) return;
    await _plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: at,
      notificationDetails: const NotificationDetails(android: _channel, iOS: DarwinNotificationDetails()),
      androidScheduleMode: mode,
    );
  }
}
