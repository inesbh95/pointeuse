import 'package:flutter/material.dart';

import 'models.dart';

class AppColors {
  static const brand = Color(0xFF123A3A);
  static const accent = Color(0xFFE08A1E);
  static const ok = Color(0xFF1F7A4D);
  static const warn = Color(0xFFA8660B);
  static const bad = Color(0xFFB4432E);
  static const okSoft = Color(0xFFE3F3EA);
  static const warnSoft = Color(0xFFFBF0DC);
  static const badSoft = Color(0xFFF8E6E2);
  // Texte sur les fonds pastel ci-dessus : ils restent clairs en mode sombre, le texte doit rester foncé.
  static const onSoft = Color(0xFF1C2626);
}

/// Carte sur fond pastel : le texte reste foncé quel que soit le thème (mode sombre compris).
class SoftCard extends StatelessWidget {
  final Color color;
  final Widget child;
  const SoftCard({super.key, required this.color, required this.child});
  @override
  Widget build(BuildContext context) => Card(
        color: color,
        surfaceTintColor: Colors.transparent,
        child: DefaultTextStyle.merge(style: const TextStyle(color: AppColors.onSoft), child: child),
      );
}

ThemeData appTheme(Brightness b) {
  final scheme = ColorScheme.fromSeed(seedColor: AppColors.brand, brightness: b, secondary: AppColors.accent);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size(0, 52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    ),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
  );
}

({Color fg, Color bg, String label, IconData icon}) statusStyle(PunchStatus s) => switch (s) {
      PunchStatus.ok => (fg: AppColors.ok, bg: AppColors.okSoft, label: 'Vérifié', icon: Icons.verified),
      PunchStatus.suspect => (fg: AppColors.warn, bg: AppColors.warnSoft, label: 'À vérifier', icon: Icons.warning_amber),
      PunchStatus.blocked => (fg: AppColors.bad, bg: AppColors.badSoft, label: 'Refusé', icon: Icons.block),
    };

class StatusChip extends StatelessWidget {
  final PunchStatus status;
  final String? label;
  const StatusChip(this.status, {super.key, this.label});
  @override
  Widget build(BuildContext context) {
    final s = statusStyle(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: s.bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label ?? s.label, style: TextStyle(color: s.fg, fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }
}

class FlagList extends StatelessWidget {
  final List<Flag> flags;
  const FlagList(this.flags, {super.key});
  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: flags
            .map((f) => Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(f.blocks ? Icons.block : Icons.warning_amber, size: 16, color: f.blocks ? AppColors.bad : AppColors.warn),
                    const SizedBox(width: 6),
                    Expanded(child: Text(f.label, style: const TextStyle(fontSize: 13))),
                  ]),
                ))
            .toList(),
      );
}
