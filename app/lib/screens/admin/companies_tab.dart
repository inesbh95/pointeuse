import 'package:flutter/material.dart';

import '../../models.dart';
import '../../services/api.dart';
import '../../theme.dart';

/// Entreprises (super-admin uniquement) : création avec leur premier administrateur, activation.
class CompaniesTab extends StatefulWidget {
  const CompaniesTab({super.key});
  @override
  State<CompaniesTab> createState() => _CompaniesTabState();
}

class _CompaniesTabState extends State<CompaniesTab> {
  late Future<List<Company>> _future = Api.instance.companies();
  void _reload() => setState(() => _future = Api.instance.companies());

  Future<void> _toggle(Company c) async {
    final off = c.active;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(off ? 'Désactiver ${c.name} ?' : 'Réactiver ${c.name} ?'),
        content: Text(off
            ? 'Ses employés ne pourront plus pointer ni se servir de l\'application. Les données sont conservées.'
            : 'Ses employés pourront de nouveau pointer.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(off ? 'Désactiver' : 'Réactiver')),
        ],
      ),
    );
    if (ok != true) return;
    await Api.instance.setCompanyActive(c.id, !c.active);
    _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () async {
            final created = await showDialog<bool>(context: context, builder: (_) => const _CompanyDialog());
            if (created == true) _reload();
          },
          icon: const Icon(Icons.add_business),
          label: const Text('Nouvelle entreprise'),
        ),
        body: FutureBuilder<List<Company>>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) return Padding(padding: const EdgeInsets.all(24), child: Text('Erreur : ${snap.error}'));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            return RefreshIndicator(
              onRefresh: () async => _reload(),
              child: ListView(padding: const EdgeInsets.only(bottom: 88), children: [
                for (final c in snap.data!)
                  ListTile(
                    leading: Icon(Icons.business, color: c.active ? null : Colors.grey),
                    title: Text(c.name, style: c.active ? null : const TextStyle(color: Colors.grey)),
                    subtitle: Text('${c.employees} compte${c.employees > 1 ? 's' : ''}${c.active ? '' : ' · désactivée'}'),
                    trailing: Switch(value: c.active, onChanged: (_) => _toggle(c)),
                  ),
              ]),
            );
          },
        ),
      );
}

/// Nouvelle entreprise et son premier administrateur.
class _CompanyDialog extends StatefulWidget {
  const _CompanyDialog();
  @override
  State<_CompanyDialog> createState() => _CompanyDialogState();
}

class _CompanyDialogState extends State<_CompanyDialog> {
  final _form = GlobalKey<FormState>();
  final _company = TextEditingController(), _name = TextEditingController();
  final _email = TextEditingController(), _password = TextEditingController();
  String? _companyId; // entreprise déjà créée si la création de l'admin a échoué
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _companyId ??= await Api.instance.createCompany(_company.text);
      await Api.instance.createEmployee(
        email: _email.text, password: _password.text, fullName: _name.text, matricule: '', admin: true, companyId: _companyId,
      );
      if (mounted) Navigator.pop(context, true);
    } on ApiError catch (e) {
      setState(() {
        _error = _companyId == null ? e.message : 'Entreprise créée, mais pas son administrateur : ${e.message}';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Nouvelle entreprise'),
        content: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextFormField(
                controller: _company,
                enabled: _companyId == null,
                decoration: const InputDecoration(labelText: 'Nom de l\'entreprise'),
                validator: (v) => (v ?? '').trim().length < 2 ? 'Obligatoire' : null,
              ),
              const SizedBox(height: 16),
              Text('Son administrateur', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              TextFormField(controller: _name, decoration: const InputDecoration(labelText: 'Nom complet'), validator: (v) => (v ?? '').trim().length < 2 ? 'Obligatoire' : null),
              const SizedBox(height: 10),
              TextFormField(controller: _email, decoration: const InputDecoration(labelText: 'E-mail'), keyboardType: TextInputType.emailAddress, validator: (v) => (v ?? '').contains('@') ? null : 'E-mail invalide'),
              const SizedBox(height: 10),
              TextFormField(controller: _password, decoration: const InputDecoration(labelText: 'Mot de passe provisoire'), validator: (v) => (v ?? '').length < 8 ? '8 caractères minimum' : null),
              if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: const TextStyle(color: AppColors.bad))),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, _companyId != null), child: const Text('Annuler')),
          FilledButton(onPressed: _busy ? null : _save, child: const Text('Créer')),
        ],
      );
}
