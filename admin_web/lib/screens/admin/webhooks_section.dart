import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../models.dart';
import '../../services/api.dart';
import '../../theme.dart';

/// Réglages › Webhooks : adresses de l'ERP prévenues à chaque pointage.
class WebhooksSection extends StatefulWidget {
  final String companyId;
  final String? companyName;
  const WebhooksSection({super.key, required this.companyId, this.companyName});
  @override
  State<WebhooksSection> createState() => _WebhooksSectionState();
}

class _WebhooksSectionState extends State<WebhooksSection> {
  late Future<List<Webhook>> _future = Api.instance.webhooks(widget.companyId);
  final _busy = <String>{};

  @override
  void didUpdateWidget(WebhooksSection old) {
    super.didUpdateWidget(old);
    if (old.companyId != widget.companyId) _reload();
  }

  void _reload() => setState(() => _future = Api.instance.webhooks(widget.companyId));
  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _run(String id, Future<void> Function() action, [String? done]) async {
    setState(() => _busy.add(id));
    try {
      await action();
      if (done != null) _snack(done);
    } on ApiError catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _busy.remove(id));
      _reload();
    }
  }

  Future<void> _create() async {
    final ctrl = TextEditingController(text: 'https://');
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nouveau webhook'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (widget.companyName != null)
            Text('Entreprise : ${widget.companyName}', style: const TextStyle(fontWeight: FontWeight.bold)),
          const Text("L'ERP recevra un appel à cette adresse à chaque pointage, décision de l'administrateur, absence déclarée et changement d'employé."),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: "Adresse de l'ERP (https://…)"),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Ajouter')),
        ],
      ),
    );
    if (url == null || url.isEmpty || !mounted) return;
    if (!url.startsWith('https://') || Uri.tryParse(url)?.host.isNotEmpty != true) {
      return _snack("L'adresse doit commencer par https://");
    }
    if (url.contains('#')) {
      return _snack("Cette adresse contient « # » : c'est l'adresse d'une page, pas l'adresse de réception. "
          "Sur webhook.site, copiez « Your unique URL » (https://webhook.site/xxxxxxxx-…).");
    }
    try {
      final secret = await Api.instance.createWebhook(widget.companyId, url);
      _reload();
      if (mounted) await _showSecret(secret);
    } on ApiError catch (e) {
      _snack(e.message);
    }
  }

  Future<void> _showSecret(String secret) => showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Webhook ajouté'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text("Voici le secret de signature. Le développeur de l'ERP s'en sert pour vérifier que "
                'les appels viennent bien de Pointeuse. Il ne sera plus jamais affiché.'),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: AppColors.warnSoft, borderRadius: BorderRadius.circular(8)),
              child: SelectableText(secret, style: const TextStyle(fontFamily: 'monospace', color: AppColors.onSoft)),
            ),
          ]),
          actions: [
            TextButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Copier le secret'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: secret));
                if (ctx.mounted) ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Secret copié.')));
              },
            ),
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text("J'ai copié le secret")),
          ],
        ),
      );

  Future<void> _delete(Webhook w) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer ce webhook ?'),
        content: Text("${w.url}\n\nL'ERP ne sera plus prévenu des pointages. Les envois en attente sont annulés. Action définitive."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Supprimer')),
        ],
      ),
    );
    if (ok == true) _run(w.id, () => Api.instance.deleteWebhook(w.id));
  }

  String _status(Webhook w, DateFormat f) {
    if (!w.active) return 'en pause';
    if (w.lastOk == null) return 'jamais appelé';
    if (w.lastOk!) return 'OK le ${f.format(w.lastAttemptAt!)}';
    return 'échec le ${f.format(w.lastAttemptAt!)} : ${w.lastError}';
  }

  @override
  Widget build(BuildContext context) {
    final f = DateFormat('dd/MM/yyyy HH:mm');
    final scheme = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Webhooks', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      Text(
        "L'ERP est prévenu en temps réel (pointages, absences, employés) : un appel signé est envoyé à son adresse. "
        "En cas d'échec, l'envoi est relancé pendant 24 h.",
        style: Theme.of(context).textTheme.bodySmall,
      ),
      const SizedBox(height: 6),
      Card(
        child: FutureBuilder<List<Webhook>>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) return Padding(padding: const EdgeInsets.all(16), child: Text('${snap.error}'));
            if (!snap.hasData) return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
            final hooks = snap.data!;
            return Column(children: [
              if (hooks.isEmpty) const ListTile(title: Text('Aucun webhook.')),
              for (final w in hooks)
                ListTile(
                  leading: Icon(
                    !w.active ? Icons.pause_circle_outline : w.lastOk == false ? Icons.error_outline : Icons.webhook,
                    color: !w.active ? Theme.of(context).disabledColor : w.lastOk == false ? scheme.error : null,
                  ),
                  title: Text(w.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(_status(w, f), maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: w.active && w.lastOk == false ? TextStyle(color: scheme.error) : null),
                  trailing: _busy.contains(w.id)
                      ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                      : PopupMenuButton<String>(
                          onSelected: (a) => switch (a) {
                            'test' => _run(w.id, () => Api.instance.testWebhook(w.id), 'Test envoyé : le résultat s\'affiche dans quelques secondes.'),
                            'pause' => _run(w.id, () => Api.instance.setWebhookActive(w.id, !w.active)),
                            _ => _delete(w),
                          },
                          itemBuilder: (_) => [
                            if (w.active) const PopupMenuItem(value: 'test', child: Text('Envoyer un test')),
                            PopupMenuItem(value: 'pause', child: Text(w.active ? 'Mettre en pause' : 'Réactiver')),
                            const PopupMenuItem(value: 'delete', child: Text('Supprimer')),
                          ],
                        ),
                ),
              const Divider(height: 1),
              ListTile(leading: const Icon(Icons.add), title: const Text('Nouveau webhook'), onTap: _create),
              if (hooks.isNotEmpty) ...[
                const Divider(height: 1),
                ListTile(leading: const Icon(Icons.refresh), title: const Text("Actualiser l'état"), onTap: _reload),
              ],
            ]);
          },
        ),
      ),
    ]);
  }
}
