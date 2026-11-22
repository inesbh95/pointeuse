import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../services/face_engine.dart';
import '../services/liveness.dart';
import '../theme.dart';

/// Résultat renvoyé par l'écran de capture.
class CaptureResult {
  final List<FaceCapture> captures;
  final Map<String, dynamic>? liveness;
  const CaptureResult(this.captures, this.liveness);
}

/// Caméra frontale.
/// - mode pointage : épreuves de présence (clignement + rotation) puis une photo ;
/// - mode enrôlement : 3 photos (de face, légèrement à gauche, légèrement à droite).
class FaceCaptureScreen extends StatefulWidget {
  final bool enrollment;
  final String title;
  const FaceCaptureScreen({super.key, this.enrollment = false, this.title = 'Vérification du visage'});

  @override
  State<FaceCaptureScreen> createState() => _FaceCaptureScreenState();
}

class _FaceCaptureScreenState extends State<FaceCaptureScreen> {
  CameraController? _cam;
  CameraDescription? _desc;
  final _engine = FaceEngine.instance;
  late final LivenessTracker _tracker = LivenessTracker.random();
  bool _busy = false, _capturing = false;
  String? _error;
  String _hint = 'Préparation de la caméra…';
  final _captures = <FaceCapture>[];
  Timer? _timeout;

  static const _enrollHints = ['Regardez la caméra de face', 'Tournez légèrement la tête à gauche', 'Tournez légèrement la tête à droite'];

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      await _engine.init();
      final cams = await availableCameras();
      _desc = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.front, orElse: () => cams.first);
      final cam = CameraController(
        _desc!,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
      );
      await cam.initialize();
      if (!mounted) return cam.dispose();
      setState(() => _cam = cam);
      if (widget.enrollment) {
        setState(() => _hint = _enrollHints[0]);
      } else {
        _timeout = Timer(const Duration(seconds: 30), () {
          if (mounted && !_capturing) _fail('Temps écoulé. Recommencez dans un endroit bien éclairé.');
        });
        await cam.startImageStream(_onFrame);
      }
    } on CameraException catch (e) {
      _fail(e.code == 'CameraAccessDenied' ? 'Autorisez la caméra dans les réglages du téléphone.' : 'Caméra indisponible.');
    } catch (e) {
      _fail('Impossible de démarrer la reconnaissance faciale : $e');
    }
  }

  void _fail(String msg) {
    if (!mounted) return;
    setState(() => _error = msg);
  }

  Future<void> _onFrame(CameraImage image) async {
    if (_busy || _capturing || _cam == null) return;
    _busy = true;
    try {
      final input = FaceEngine.inputFromCamera(image, _desc!, _cam!.value.deviceOrientation);
      if (input == null) return;
      final faces = await _engine.streamDetector.processImage(input);
      final ready = _tracker.update(faces);
      if (mounted && _hint != _tracker.hint) setState(() => _hint = _tracker.hint);
      if (ready) await _takePhoto();
    } catch (_) {
      // image ignorée
    } finally {
      _busy = false;
    }
  }

  Future<void> _takePhoto() async {
    if (_capturing) return;
    setState(() {
      _capturing = true;
      _hint = 'Analyse…';
    });
    try {
      if (_cam!.value.isStreamingImages) await _cam!.stopImageStream();
      final file = await _cam!.takePicture();
      final cap = await _engine.fromPhoto(file);
      _captures.add(cap);
      try { await File(file.path).delete(); } catch (_) {}

      if (!widget.enrollment) {
        _timeout?.cancel();
        if (mounted) Navigator.pop(context, CaptureResult(_captures, _tracker.toJson()));
        return;
      }
      if (_captures.length >= 3) {
        if (mounted) Navigator.pop(context, CaptureResult(_captures, null));
        return;
      }
      setState(() {
        _hint = _enrollHints[_captures.length];
        _capturing = false;
      });
    } on FaceError catch (e) {
      setState(() {
        _hint = e.message;
        _capturing = false;
      });
      if (!widget.enrollment && mounted) {
        // On relance l'épreuve finale
        _tracker.phase = LivenessPhase.frontal;
        await _cam!.startImageStream(_onFrame);
      }
    } catch (e, st) {
      debugPrint('Capture échouée : $e\n$st');
      _fail('La photo a échoué. Réessayez.\n\nDétail : $e');
    }
  }

  @override
  void dispose() {
    _timeout?.cancel();
    final cam = _cam;
    _cam = null;
    if (cam != null) {
      if (cam.value.isStreamingImages) cam.stopImageStream().catchError((_) {});
      cam.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cam = _cam;
    final total = widget.enrollment ? 3 : _tracker.steps.length;
    final done = widget.enrollment ? _captures.length : _tracker.completed.length;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(widget.title), backgroundColor: Colors.black, foregroundColor: Colors.white),
      body: _error != null
          ? _ErrorView(message: _error!, onBack: () => Navigator.pop(context))
          : Column(children: [
              Expanded(
                child: Center(
                  child: cam == null || !cam.value.isInitialized
                      ? const CircularProgressIndicator()
                      : ClipOval(
                          child: SizedBox(
                            width: 280,
                            height: 360,
                            child: FittedBox(
                              fit: BoxFit.cover,
                              child: SizedBox(
                                width: cam.value.previewSize?.height ?? 480,
                                height: cam.value.previewSize?.width ?? 640,
                                child: CameraPreview(cam),
                              ),
                            ),
                          ),
                        ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                child: Column(children: [
                  Text(_hint, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(total, (i) => Container(
                          width: 36, height: 6, margin: const EdgeInsets.symmetric(horizontal: 4),
                          decoration: BoxDecoration(color: i < done ? AppColors.ok : Colors.white24, borderRadius: BorderRadius.circular(3)),
                        )),
                  ),
                  if (widget.enrollment) ...[
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: cam == null || _capturing ? null : _takePhoto,
                      icon: const Icon(Icons.camera_alt),
                      label: Text('Capturer (${_captures.length}/3)'),
                    ),
                  ],
                ]),
              ),
            ]),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onBack;
  const _ErrorView({required this.message, required this.onBack});
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, color: Colors.white70, size: 48),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 17)),
            const SizedBox(height: 20),
            OutlinedButton(onPressed: onBack, child: const Text('Retour')),
          ]),
        ),
      );
}
