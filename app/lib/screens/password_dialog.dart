import 'package:flutter/material.dart';

import '../services/api.dart';
import '../theme.dart';

/// Changement du mot de passe par l'utilisateur connecté (mot de passe provisoire reçu de l'admin).
class PasswordDialog extends StatefulWidget {
  const PasswordDialog({super.key});
  @override
  State<PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<PasswordDialog> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController(), _next = TextEditingController(), _confirm = TextEditingController();
  bool _busy = false, _show = false;
  String? _error;

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.instance.changePassword(_current.text, _next.text);
      if (mounted) Navigator.pop(context, true);
    } on ApiError catch (e) {
      setState(() {
        _error = e.message;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    InputDecoration deco(String label) => InputDecoration(
          labelText: label,
          suffixIcon: IconButton(icon: Icon(_show ? Icons.visibility_off : Icons.visibility), onPressed: () => setState(() => _show = !_show)),
        );
    return AlertDialog(
      title: const Text('Changer mon mot de passe'),
      content: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(controller: _current, obscureText: !_show, decoration: deco('Mot de passe actuel'), validator: (v) => (v ?? '').isEmpty ? 'Obligatoire' : null),
            const SizedBox(height: 10),
            TextFormField(controller: _next, obscureText: !_show, decoration: deco('Nouveau mot de passe'), validator: (v) => (v ?? '').length < 8 ? '8 caractères minimum' : null),
            const SizedBox(height: 10),
            TextFormField(controller: _confirm, obscureText: !_show, decoration: deco('Confirmer le nouveau'), validator: (v) => v != _next.text ? 'Les deux mots de passe diffèrent' : null),
            if (_error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_error!, style: const TextStyle(color: AppColors.bad))),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Enregistrer')),
      ],
    );
  }
}
