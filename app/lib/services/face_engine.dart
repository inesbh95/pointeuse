import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// Résultat d'une capture : vecteur du visage (192 valeurs normalisées) + photo compressée.
class FaceCapture {
  final List<double> embedding;
  final Uint8List jpeg;
  const FaceCapture(this.embedding, this.jpeg);
}

class FaceError implements Exception {
  final String message;
  FaceError(this.message);
  @override
  String toString() => message;
}

/// Détection (ML Kit) + vecteur d'identité (MobileFaceNet, 112×112 → 192).
/// Le même traitement sert à l'enrôlement et au pointage, pour que les vecteurs soient comparables.
class FaceEngine {
  FaceEngine._();
  static final instance = FaceEngine._();

  Interpreter? _interpreter;

  /// Détecteur pour le flux vidéo : contours rapides + probabilité d'yeux ouverts (clignement).
  final streamDetector = FaceDetector(options: FaceDetectorOptions(
    enableClassification: true,
    performanceMode: FaceDetectorMode.fast,
    minFaceSize: 0.25,
  ));

  /// Détecteur précis pour la photo finale.
  final _photoDetector = FaceDetector(options: FaceDetectorOptions(
    performanceMode: FaceDetectorMode.accurate,
    minFaceSize: 0.2,
  ));

  Future<void> init() async {
    _interpreter ??= await Interpreter.fromAsset('assets/models/mobilefacenet.tflite');
  }

  /// Calcule le vecteur à partir d'une photo prise par la caméra.
  Future<FaceCapture> fromPhoto(XFile file) async {
    await init();
    final faces = await _photoDetector.processImage(InputImage.fromFilePath(file.path));
    if (faces.isEmpty) throw FaceError('Aucun visage sur la photo. Placez-vous face à la caméra.');
    if (faces.length > 1) throw FaceError('Plusieurs visages détectés. Une seule personne doit être face à la caméra.');

    final bytes = await File(file.path).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw FaceError('Photo illisible. Réessayez.');
    // ML Kit lit l'orientation EXIF : on applique la même rotation avant de recadrer.
    final photo = img.bakeOrientation(decoded);

    final box = faces.first.boundingBox;
    final side = math.max(box.width, box.height) * 1.2; // un peu de marge autour du visage
    final cx = box.center.dx, cy = box.center.dy;
    final x = (cx - side / 2).clamp(0, photo.width - 1).toInt();
    final y = (cy - side / 2).clamp(0, photo.height - 1).toInt();
    final w = math.min(side.toInt(), photo.width - x);
    final h = math.min(side.toInt(), photo.height - y);
    if (w < 60 || h < 60) throw FaceError('Visage trop petit. Rapprochez-vous de la caméra.');

    final face = img.copyResize(img.copyCrop(photo, x: x, y: y, width: w, height: h), width: 112, height: 112, interpolation: img.Interpolation.linear);
    final embedding = _embed(face);

    final small = img.copyResize(photo, width: photo.width > photo.height ? 640 : 480);
    final jpeg = Uint8List.fromList(img.encodeJpg(small, quality: 75));
    return FaceCapture(embedding, jpeg);
  }

  List<double> _embed(img.Image face) {
    final input = List.generate(1, (_) => List.generate(112, (y) => List.generate(112, (x) {
          final p = face.getPixel(x, y);
          return [(p.r - 127.5) / 128.0, (p.g - 127.5) / 128.0, (p.b - 127.5) / 128.0];
        })));
    final output = List.generate(1, (_) => List<double>.filled(192, 0));
    _interpreter!.run(input, output);
    final v = output.first;
    final norm = math.sqrt(v.fold<double>(0, (s, x) => s + x * x));
    return norm == 0 ? v : v.map((x) => x / norm).toList();
  }

  // ---------- Conversion du flux caméra pour ML Kit ----------
  static const _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  static InputImage? inputFromCamera(CameraImage image, CameraDescription camera, DeviceOrientation orientation) {
    final sensor = camera.sensorOrientation;
    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensor);
    } else {
      var comp = _orientations[orientation];
      if (comp == null) return null;
      comp = camera.lensDirection == CameraLensDirection.front ? (sensor + comp) % 360 : (sensor - comp + 360) % 360;
      rotation = InputImageRotationValue.fromRawValue(comp);
    }
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null ||
        (Platform.isAndroid && format != InputImageFormat.nv21) ||
        (Platform.isIOS && format != InputImageFormat.bgra8888)) {
      return null;
    }
    if (image.planes.length != 1) return null;
    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }
}
