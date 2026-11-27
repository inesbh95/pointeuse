import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../models.dart';
import '../../services/api.dart';
import '../../theme.dart';

/// Réglages › API pour les ERP : clés d'accès de l'entreprise (création, révocation).
class ApiKeysSection extends StatefulWidget {
  final String companyId;
  final String? companyName;
  const ApiKeysSection({super.key, required this.companyId, this.companyName});
  @override
  State<ApiKeysSection> createState() => _ApiKeysSectionState();
}

class _ApiKeysSectionState extends State<ApiKeysSection> {
  late Future<List<ApiKey>> _future = Api.instance.apiKeys(widget.companyId);

  @override
  void didUpdateWidget(ApiKeysSection old) {
    super.didUpdateWidget(old);
    if (old.companyId != widget.companyId) _reload();
  }

  void _reload() => setState(() => _future = Api.instance.apiKeys(widget.companyId));

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _create() async {
    final label = TextEditingController();
    var write = false;
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) => AlertDialog(
        title: const Text("Nouvelle clé d'API"),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (widget.companyName != null) ...[
            Text("Entreprise : ${widget.companyName}", style: const TextStyle(fontWeight: FontWeight.bold)),
            const Text("La clé ne donnera accès qu'aux données de cette entreprise."),
            const SizedBox(height: 12),
          ],
          TextField(
          controller: label,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Nom de la clé', hintText: 'ex. ERP Odoo, Paie Sage'),
        ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: write,
            onChanged: (v) => setLocal(() => write = v ?? false),
            title: const Text('Peut aussi créer des tickets'),
            subtitle: const Text('Import depuis Odoo ou un autre système (module Tickets). Sinon : lecture seule.'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, label.text.trim()), child: const Text('Créer')),
        ],
      )),
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final key = await Api.instance.createApiKey(widget.companyId, name, ticketsWrite: write);
      _reload();
      if (mounted) await _showOnce(key);
    } on ApiError catch (e) {
      _snack(e.message);
    }
  }

  /// La clé n'est affichée qu'une seule fois.
  Future<void> _showOnce(String key) => showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Clé créée'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text("Copiez-la maintenant et transmettez-la au développeur de l'ERP par un moyen sûr. "
                "Elle ne sera plus jamais affichée."),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: AppColors.warnSoft, borderRadius: BorderRadius.circular(8)),
              child: SelectableText(key, style: const TextStyle(fontFamily: 'monospace', color: AppColors.onSoft)),
            ),
            const SizedBox(height: 12),
            Text('Adresse de l\'API : ${Api.instance.erpApiBase}', style: Theme.of(ctx).textTheme.bodySmall),
          ]),
          actions: [
            TextButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Copier la clé'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: key));
                if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Clé copiée.')));
              },
            ),
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text("J'ai copié la clé")),
          ],
        ),
      );

  Future<void> _revoke(ApiKey k) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Révoquer cette clé ?'),
        content: Text("« ${k.label} » ne fonctionnera plus immédiatement. L'ERP qui l'utilise perdra l'accès. Action définitive."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Révoquer')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.instance.revokeApiKey(k.id);
      _reload();
    } on ApiError catch (e) {
      _snack(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final f = DateFormat('dd/MM/yyyy HH:mm');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(widget.companyName == null ? 'API pour les ERP' : 'API pour les ERP · ${widget.companyName}', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      Text(
        widget.companyName == null
            ? "Une clé permet à un logiciel (ERP, paie) de lire les employés, pointages et feuilles de temps de l'entreprise. Lecture seule, uniquement cette entreprise."
            : "Une clé permet à un logiciel (ERP, paie) de lire les employés, pointages et feuilles de temps de ${widget.companyName}. Lecture seule, uniquement cette entreprise.",
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 6),
      Card(
        child: FutureBuilder<List<ApiKey>>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) return Padding(padding: const EdgeInsets.all(16), child: Text('${snap.error}'));
            if (!snap.hasData) return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
            final keys = snap.data!;
            return Column(children: [
              if (keys.isEmpty) const ListTile(title: Text('Aucune clé.')),
              for (final k in keys)
                ListTile(
                  leading: Icon(k.active ? Icons.key : Icons.key_off, color: k.active ? null : Theme.of(context).disabledColor),
                  title: Text(k.label, style: k.active ? null : const TextStyle(decoration: TextDecoration.lineThrough)),
                  subtitle: Text([
                    '${k.prefix}…',
                    if (k.scopes.contains('tickets:write')) 'lecture + tickets',
                    'créée le ${f.format(k.createdAt)}',
                    k.active
                        ? (k.lastUsedAt == null ? 'jamais utilisée' : 'utilisée le ${f.format(k.lastUsedAt!)}')
                        : 'révoquée le ${f.format(k.revokedAt!)}',
                  ].join(' · ')),
                  trailing: k.active ? TextButton(onPressed: () => _revoke(k), child: const Text('Révoquer')) : null,
                ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('Nouvelle clé'),
                onTap: _create,
              ),
            ]);
          },
        ),
      ),
      const SizedBox(height: 6),
      SelectableText('Adresse : ${Api.instance.erpApiBase}', style: Theme.of(context).textTheme.bodySmall),
    ]);
  }
}
