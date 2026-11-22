/// Configuration passée à la compilation :
///   flutter run --dart-define=SUPABASE_URL=https://xxxx.supabase.co \
///               --dart-define=SUPABASE_ANON_KEY=eyJ... \
///               --dart-define=GOOGLE_CLOUD_PROJECT_NUMBER=123456789012
/// (ou --dart-define-from-file=config.json, voir README)
class Config {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// Numéro du projet Google Cloud lié à la Play Console (Play Integrity). Facultatif en test.
  static const cloudProjectNumber = int.fromEnvironment('GOOGLE_CLOUD_PROJECT_NUMBER');

  /// Durée maximale de collecte des positions GPS.
  static const gpsWindow = Duration(seconds: 12);

  /// Nombre de relevés GPS visés (au moins 3 pour détecter une position figée).
  static const gpsFixes = 4;

  static bool get isConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;
}
