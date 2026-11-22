import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'models.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/api.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('fr_FR');
  if (Config.isConfigured) {
    await Supabase.initialize(url: Config.supabaseUrl, anonKey: Config.supabaseAnonKey);
  }
  runApp(const PointeuseApp());
}

class PointeuseApp extends StatelessWidget {
  const PointeuseApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Pointeuse',
        debugShowCheckedModeBanner: false,
        theme: appTheme(Brightness.light),
        darkTheme: appTheme(Brightness.dark),
        home: Config.isConfigured ? const AuthGate() : const _NotConfigured(),
      );
}

/// Affiche la connexion ou l'application selon la session.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});
  @override
  Widget build(BuildContext context) => StreamBuilder<AuthState>(
        stream: Supabase.instance.client.auth.onAuthStateChange,
        builder: (context, _) {
          final session = Supabase.instance.client.auth.currentSession;
          if (session == null) return const LoginScreen();
          // Rechargé quand une option de l'entreprise change (ex. gestion des sites) : l'écran reste en place.
          return ValueListenableBuilder<int>(
            valueListenable: Api.instance.profileVersion,
            builder: (context, _, __) => FutureBuilder<Profile>(
            key: ValueKey(session.user.id),
            future: Api.instance.me(),
            builder: (context, snap) {
              if (snap.hasError) {
                return Scaffold(
                  body: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Text('Profil introuvable ou compte désactivé.'),
                      TextButton(onPressed: Api.instance.signOut, child: const Text('Se déconnecter')),
                    ]),
                  ),
                );
              }
              if (!snap.hasData) return const Scaffold(body: Center(child: CircularProgressIndicator()));
              if (!snap.data!.active) {
                return Scaffold(body: Center(child: TextButton(onPressed: Api.instance.signOut, child: const Text('Compte désactivé. Se déconnecter'))));
              }
              return HomeScreen(profile: snap.data!);
            },
          ));
        },
      );
}

class _NotConfigured extends StatelessWidget {
  const _NotConfigured();
  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Padding(
          padding: EdgeInsets.all(24),
          child: Center(
            child: Text(
              'Application non configurée.\nLancez-la avec --dart-define-from-file=config.json (voir README).',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
}
