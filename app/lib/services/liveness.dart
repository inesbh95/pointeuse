import 'dart:math' as math;

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

/// Épreuves de présence, tirées dans un ordre aléatoire à chaque pointage pour qu'une vidéo
/// préenregistrée ne suffise pas.
enum LivenessStep { blink, turnLeft, turnRight }

extension LivenessStepText on LivenessStep {
  String get instruction => switch (this) {
        LivenessStep.blink => 'Clignez des yeux',
        LivenessStep.turnLeft => 'Tournez lentement la tête vers la gauche',
        LivenessStep.turnRight => 'Tournez lentement la tête vers la droite',
      };
  String get code => name;
}

enum LivenessPhase { searching, step, frontal, done }

/// Machine à états alimentée par les visages détectés image après image.
class LivenessTracker {
  final List<LivenessStep> steps;
  int _index = 0;
  LivenessPhase phase = LivenessPhase.searching;
  String hint = 'Placez votre visage dans le cadre';
  final _start = DateTime.now();
  final completed = <String>[];

  // Clignement : yeux ouverts → fermés → ouverts
  bool _sawOpen = false, _sawClosed = false;
  // Rotation : tête tournée puis revenue de face
  bool _turned = false;

  LivenessTracker._(this.steps);

  factory LivenessTracker.random() {
    final rnd = math.Random();
    final turn = rnd.nextBool() ? LivenessStep.turnLeft : LivenessStep.turnRight;
    final steps = [LivenessStep.blink, turn]..shuffle(rnd);
    return LivenessTracker._(steps);
  }

  LivenessStep? get current => _index < steps.length ? steps[_index] : null;
  int get durationMs => DateTime.now().difference(_start).inMilliseconds;

  /// Retourne true quand la personne est prête pour la photo finale (de face, toutes épreuves réussies).
  bool update(List<Face> faces) {
    if (faces.isEmpty) {
      hint = 'Placez votre visage dans le cadre';
      return false;
    }
    if (faces.length > 1) {
      hint = 'Une seule personne devant la caméra';
      return false;
    }
    final f = faces.first;
    final yaw = f.headEulerAngleY ?? 0; // rotation gauche/droite

    if (phase == LivenessPhase.searching) {
      if (yaw.abs() < 12) phase = LivenessPhase.step;
    }

    if (phase == LivenessPhase.step) {
      final s = current!;
      hint = s.instruction;
      var ok = false;
      switch (s) {
        case LivenessStep.blink:
          final l = f.leftEyeOpenProbability, r = f.rightEyeOpenProbability;
          if (l == null || r == null) break;
          if (l > 0.75 && r > 0.75) {
            if (_sawClosed) ok = true;
            _sawOpen = true;
          } else if (_sawOpen && l < 0.25 && r < 0.25) {
            _sawClosed = true;
          }
        case LivenessStep.turnLeft:
        case LivenessStep.turnRight:
          // Le signe de l'angle dépend de la caméra et de la plateforme : on demande une rotation
          // franche (> 25°) puis un retour de face, ce qu'une photo ne peut pas faire.
          if (yaw.abs() > 25) _turned = true;
          if (_turned && yaw.abs() < 10) ok = true;
      }
      if (ok) {
        completed.add(s.code);
        _index++;
        _sawOpen = _sawClosed = _turned = false;
        if (current == null) phase = LivenessPhase.frontal;
      }
    }

    if (phase == LivenessPhase.frontal) {
      hint = 'Regardez la caméra, ne bougez plus';
      if (yaw.abs() < 10 && (f.headEulerAngleX ?? 0).abs() < 15) {
        phase = LivenessPhase.done;
        return true;
      }
    }
    return false;
  }

  Map<String, dynamic> toJson() => {
        'passed': phase == LivenessPhase.done && completed.length == steps.length,
        'steps': completed,
        'durationMs': durationMs,
      };
}
