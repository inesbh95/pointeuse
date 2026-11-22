import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models.dart';

/// Export Excel (.xlsx) des pointages : une feuille détaillée et un résumé par employé et par jour.
class ExportService {
  /// Positions arrondies à ~10 m : un même lieu n'est géocodé qu'une fois.
  static String _key(double lat, double lng) => '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';

  /// Géocode les lieux distincts par lots parallèles, 5 s max par lieu et 25 s au total :
  /// au-delà, l'adresse reste vide (latitude, longitude et lien carte restent dans le fichier).
  static Future<Map<String, String?>> _resolveAddresses(List<Punch> punches, Future<String?> Function(double, double) addressOf) async {
    final todo = <String, Punch>{};
    for (final p in punches) {
      if ((p.address == null || p.address!.isEmpty) && p.lat != null && p.lng != null) todo.putIfAbsent(_key(p.lat!, p.lng!), () => p);
    }
    final out = <String, String?>{};
    final deadline = DateTime.now().add(const Duration(seconds: 25));
    final keys = todo.keys.toList();
    for (var i = 0; i < keys.length && DateTime.now().isBefore(deadline); i += 6) {
      final batch = keys.skip(i).take(6);
      await Future.wait(batch.map((k) async {
        final p = todo[k]!;
        try {
          out[k] = await addressOf(p.lat!, p.lng!).timeout(const Duration(seconds: 5));
        } catch (_) {}
      }));
    }
    return out;
  }

  /// [addressOf] : adresse calculée sur le téléphone quand le serveur n'en a pas.
  static Future<File> buildFile(
    List<Punch> punches, {
    required DateTime from,
    required DateTime to,
    bool withCompany = false,
    bool withSites = true,
    String? fileTag, // ex. nom de l'entreprise filtrée, ajouté au nom du fichier
    List<TimesheetRow> timesheet = const [], // feuille « Feuille de temps » (vide = pas de feuille)
    Future<String?> Function(double lat, double lng)? addressOf,
  }) async {
    final day = DateFormat('dd/MM/yyyy'), hour = DateFormat('HH:mm:ss');
    final xl = Excel.createExcel();
    final def = xl.getDefaultSheet()!;
    xl.rename(def, 'Pointages');
    final sheet = xl['Pointages'];
    final bold = CellStyle(bold: true, backgroundColorHex: ExcelColor.fromHexString('#DDEBE8'));

    void header(Sheet s, List<String> titles) {
      s.appendRow([for (final t in titles) TextCellValue(t)]);
      for (var c = 0; c < titles.length; c++) {
        s.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0)).cellStyle = bold;
        s.setColumnWidth(c, titles[c].length < 10 ? 14 : titles[c].length + 6);
      }
    }

    TextCellValue? t(String? v) => v == null || v.isEmpty ? null : TextCellValue(v);

    header(sheet, [
      'Date', 'Heure', 'Employé', 'Matricule',
      if (withCompany) 'Entreprise',
      'Type', 'Statut',
      if (withSites) ...['Site', 'Distance site (m)'],
      'Saisie admin (motif)',
      'Adresse', 'Latitude', 'Longitude', 'Précision (m)', 'Visage (%)', 'Alertes', 'Décision admin', 'Note', 'Carte',
    ]);
    final addresses = addressOf == null ? const <String, String?>{} : await _resolveAddresses(punches, addressOf);
    for (final p in punches) {
      var address = p.address;
      if ((address == null || address.isEmpty) && p.lat != null && p.lng != null) address = addresses[_key(p.lat!, p.lng!)];
      sheet.appendRow([
        TextCellValue(day.format(p.serverTs)),
        TextCellValue(hour.format(p.serverTs)),
        t(p.employeeName),
        t(p.employeeMatricule),
        if (withCompany) t(p.companyName),
        TextCellValue(p.isIn ? 'Entrée' : 'Sortie'),
        TextCellValue(switch (p.status) { PunchStatus.ok => 'Validé', PunchStatus.suspect => 'À vérifier', PunchStatus.blocked => 'Refusé' }),
        if (withSites) ...[t(p.siteLabel), p.siteDistanceM == null ? null : IntCellValue(p.siteDistanceM!)],
        p.manual ? TextCellValue('Oui : ${p.manualReason ?? ''}') : null,
        t(address),
        p.lat == null ? null : DoubleCellValue(p.lat!),
        p.lng == null ? null : DoubleCellValue(p.lng!),
        p.accuracyM == null ? null : IntCellValue(p.accuracyM!.round()),
        p.faceSimilarity == null ? null : IntCellValue((p.faceSimilarity! * 100).round()),
        t(p.flags.map((f) => f.label).join(' ; ')),
        t(switch (p.reviewDecision) { 'approved' => 'Accepté', 'rejected' => 'Rejeté', _ => null }),
        t(p.reviewNote),
        p.lat == null ? null : TextCellValue('https://maps.google.com/?q=${p.lat},${p.lng}'),
      ]);
    }

    // Feuille de temps (calcul serveur) : une ligne par employé et par jour.
    if (timesheet.isNotEmpty) {
      final ts = xl['Feuille de temps'];
      header(ts, [
        'Date', 'Employé', 'Matricule', if (withCompany) 'Entreprise', 'Arrivée', 'Départ',
        'Travaillé (min)', 'Travaillé', 'Prévu (min)', 'Retard (min)', 'Heures sup (min)', 'Pointages', 'Statut', 'Absence', 'Saisies admin',
      ]);
      final h = DateFormat('HH:mm');
      for (final r in timesheet) {
        ts.appendRow([
          TextCellValue(day.format(r.day)),
          TextCellValue(r.fullName),
          t(r.matricule),
          if (withCompany) t(r.companyName),
          r.firstIn == null ? null : TextCellValue(h.format(r.firstIn!)),
          r.lastOut == null ? null : TextCellValue(h.format(r.lastOut!)),
          IntCellValue(r.workedMin),
          TextCellValue(TimesheetRow.hm(r.workedMin)),
          IntCellValue(r.expectedMin),
          IntCellValue(r.lateMin),
          IntCellValue(r.overtimeMin),
          IntCellValue(r.punches),
          TextCellValue(r.statusLabel),
          t(r.absence == null ? null : Absence.label(r.absence)),
          r.manual == 0 ? null : IntCellValue(r.manual),
        ]);
      }
    }

    final bytes = xl.encode();
    if (bytes == null) throw Exception('Fichier Excel non généré.');
    final tag = fileTag == null ? '' : '${fileTag.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-')}_';
    final name = 'pointages_$tag${DateFormat('yyyy-MM-dd').format(from)}_au_${DateFormat('yyyy-MM-dd').format(to)}.xlsx';
    final file = File('${(await getTemporaryDirectory()).path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  static const _mime = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

  /// Ouvre la fenêtre « Enregistrer sous » du téléphone (Téléchargements, Drive…). Null si annulé.
  static Future<String?> save(File file) =>
      FlutterFileDialog.saveFile(params: SaveFileDialogParams(sourceFilePath: file.path, mimeTypesFilter: const [_mime]));

  /// Envoi par e-mail, WhatsApp, etc.
  static Future<void> share(File file) =>
      SharePlus.instance.share(ShareParams(files: [XFile(file.path, mimeType: _mime)], subject: 'Pointages'));
}
