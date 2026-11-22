import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'models.dart';
import 'screens/admin/admin_screen.dart';
import 'screens/login_screen.dart';
import 'screens/password_dialog.dart';
import 'services/api.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('fr_FR');
  if (Config.isConfigured) {
    await Supabase.initialize(url: Config.supabaseUrl, publishableKey: Config.supabaseAnonKey);
  }
  runApp(const AdminWebApp());
}

class AdminWebApp extends StatelessWidget {
  const AdminWebApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Pointeuse · Administration',
        debugShowCheckedModeBanner: false,
        theme: appTheme(Brightness.light),
        darkTheme: appTheme(Brightness.dark),
        locale: const Locale('fr', 'FR'),
        supportedLocales: const [Locale('fr', 'FR')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Config.isConfigured
            ? const AuthGate()
            : const Scaffold(body: Center(child: Text('Application non configurée (config.json).'))),
      );
}

/// Connexion, puis accès réservé aux administrateurs.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});
  @override
  Widget build(BuildContext context) => StreamBuilder<AuthState>(
        stream: Supabase.instance.client.auth.onAuthStateChange,
        builder: (context, _) {
          final session = Supabase.instance.client.auth.currentSession;
          if (session == null) return const _Centered(child: LoginScreen());
          return ValueListenableBuilder<int>(
            valueListenable: Api.instance.profileVersion,
            builder: (context, _, __) => FutureBuilder<Profile>(
            key: ValueKey(session.user.id),
            future: Api.instance.me(),
            builder: (context, snap) {
              if (snap.hasError) return const _Refused('Profil introuvable ou compte désactivé.');
              if (!snap.hasData) return const Scaffold(body: Center(child: CircularProgressIndicator()));
              final p = snap.data!;
              if (!p.active) return const _Refused('Compte désactivé.');
              if (!p.isAdmin) {
                return const _Refused("L'administration web est réservée aux administrateurs.\nPour pointer, utilisez l'app mobile.");
              }
              return WebHome(profile: p);
            },
          ));
        },
      );
}

class WebHome extends StatelessWidget {
  final Profile profile;
  const WebHome({super.key, required this.profile});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Pointeuse · Administration'),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(profile.fullName, style: Theme.of(context).textTheme.labelLarge),
                if (profile.companyName != null)
                  Text(
                    profile.isSuperAdmin ? '${profile.companyName} · super-admin' : profile.companyName!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ]),
            ),
            PopupMenuButton<String>(
              tooltip: 'Mon compte',
              icon: const Icon(Icons.account_circle_outlined),
              onSelected: (v) async {
                if (v == 'logout') return Api.instance.signOut();
                final changed = await showDialog<bool>(context: context, builder: (_) => const PasswordDialog());
                if (changed == true && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Mot de passe modifié.')));
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'password', child: ListTile(leading: Icon(Icons.lock_reset), title: Text('Changer mon mot de passe'))),
                PopupMenuItem(value: 'logout', child: ListTile(leading: Icon(Icons.logout), title: Text('Se déconnecter'))),
              ],
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: AdminScreen(profile: profile),
      );
}

/// Écran de connexion centré et limité en largeur sur grand écran.
class _Centered extends StatelessWidget {
  final Widget child;
  const _Centered({required this.child});
  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460, maxHeight: 720),
            child: Card(clipBehavior: Clip.antiAlias, child: child),
          ),
        ),
      );
}

class _Refused extends StatelessWidget {
  final String message;
  const _Refused(this.message);
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.lock_outline, size: 48),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: Api.instance.signOut, child: const Text('Se déconnecter')),
          ]),
        ),
      );
}
