import 'package:flutter/material.dart';

import '../models.dart';
import '../services/api.dart';
import '../services/reminder_service.dart';
import '../tickets/my_tickets_screen.dart';
import '../tickets/tickets.dart';
import 'admin/admin_screen.dart';
import 'history_screen.dart';
import 'password_dialog.dart';
import 'punch_screen.dart';

class HomeScreen extends StatefulWidget {
  final Profile profile;
  const HomeScreen({super.key, required this.profile});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _tab = 0;
  bool _exactDismissed = false;
  final _tickets = GlobalKey<MyTicketsScreenState>();
  int _todo = 0; // tickets « À faire » assignés : pastille du menu

  bool get _hasTickets => widget.profile.hasModule(ticketsModule);

  Future<void> _refreshTodo() async {
    if (!_hasTickets) return;
    try {
      final n = await TicketsApi.instance.myTodoCount();
      if (mounted && n != _todo) setState(() => _todo = n);
    } catch (_) {
      // hors ligne : la pastille sera mise à jour plus tard
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ReminderService.sync(widget.profile.companyId);
    _refreshTodo();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Retour dans l'app (après le réglage Android, ou le lendemain) : on reprogramme les rappels.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ReminderService.sync(widget.profile.companyId);
      _refreshTodo();
      if (_hasTickets) _tickets.currentState?.reload();
    }
  }

  /// Bandeau : rappels à l'heure exacte (sinon Android peut les retarder jusqu'à 1 h).
  Widget _exactBanner() => ValueListenableBuilder<bool>(
        valueListenable: ReminderService.needsExactPermission,
        builder: (context, needed, _) => !needed || _exactDismissed
            ? const SizedBox.shrink()
            : MaterialBanner(
                leading: const Icon(Icons.alarm),
                content: const Text("Pour recevoir les rappels de pointage à l'heure exacte, autorisez « Alarmes et rappels »."),
                actions: [
                  TextButton(onPressed: () => setState(() => _exactDismissed = true), child: const Text('Plus tard')),
                  FilledButton(onPressed: () => ReminderService.requestExact(widget.profile.companyId), child: const Text('Autoriser')),
                ],
              ),
      );

  @override
  Widget build(BuildContext context) {
    final pages = [
      PunchScreen(profile: widget.profile),
      const HistoryScreen(),
      if (_hasTickets) MyTicketsScreen(key: _tickets, profile: widget.profile, onChanged: _refreshTodo),
      if (widget.profile.isAdmin) AdminScreen(profile: widget.profile),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.profile.fullName),
          if (widget.profile.companyName != null)
            Text(
              widget.profile.isSuperAdmin ? '${widget.profile.companyName} · super-admin' : widget.profile.companyName!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ]),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Mon compte',
            icon: const Icon(Icons.account_circle_outlined),
            onSelected: (v) async {
              if (v == 'logout') {
                await ReminderService.clear();
                return Api.instance.signOut();
              }
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
        ],
      ),
      body: Column(children: [
        _exactBanner(),
        Expanded(child: IndexedStack(index: _tab, children: pages)),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) {
          setState(() => _tab = i);
          if (_hasTickets && i == 2) _tickets.currentState?.reload();
        },
        destinations: [
          const NavigationDestination(icon: Icon(Icons.fingerprint), label: 'Pointer'),
          const NavigationDestination(icon: Icon(Icons.history), label: 'Mes pointages'),
          if (_hasTickets)
            NavigationDestination(
              icon: Badge(isLabelVisible: _todo > 0, label: Text('$_todo'), child: const Icon(Icons.confirmation_number_outlined)),
              label: 'Mes tickets',
            ),
          if (widget.profile.isAdmin) const NavigationDestination(icon: Icon(Icons.admin_panel_settings), label: 'Administration'),
        ],
      ),
    );
  }
}
