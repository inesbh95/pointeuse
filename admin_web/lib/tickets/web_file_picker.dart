import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'tickets.dart';

/// Choix d'un fichier dans le navigateur (photo, PDF…).
Future<PickedTicketFile?> pickWebFile(BuildContext _) {
  final done = Completer<PickedTicketFile?>();
  final input = web.document.createElement('input') as web.HTMLInputElement
    ..type = 'file'
    ..accept = 'image/*,application/pdf,.doc,.docx,.xls,.xlsx,.txt';
  input.onchange = (web.Event _) {
    final file = input.files?.item(0);
    if (file == null) return done.complete(null);
    final reader = web.FileReader();
    reader.onload = (web.Event _) {
      final buf = (reader.result as JSArrayBuffer).toDart;
      done.complete(PickedTicketFile(file.name, file.type.isEmpty ? 'application/octet-stream' : file.type, buf.asUint8List()));
    }.toJS;
    reader.onerror = (web.Event _) {
      if (!done.isCompleted) done.complete(null);
    }.toJS;
    reader.readAsArrayBuffer(file);
  }.toJS;
  // Fenêtre fermée sans choix de fichier.
  input.oncancel = (web.Event _) {
    if (!done.isCompleted) done.complete(null);
  }.toJS;
  input.click();
  return done.future;
}
