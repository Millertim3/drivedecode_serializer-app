// lib/ui/settings_dialog.dart
//
// Where the Worker is and what token to present. Two fields, typed once per
// bench machine.

import 'package:flutter/material.dart';

import '../api/settings.dart';

Future<void> showBenchSettings(BuildContext context) async {
  final current = await BenchSettings.load();
  if (!context.mounted) return;

  final urlController = TextEditingController(text: current.baseUrl);
  final tokenController = TextEditingController(text: current.adminToken);

  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Bench settings'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: urlController,
            decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: 'https://api.millerobd.com',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: tokenController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Admin token',
              helperText: 'Matches ADMIN_BENCH_TOKEN on the Worker.',
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Changes take effect on the next launch. The token is stored on '
            'this machine only — it is never in the app binary, and rotating '
            'it is one wrangler secret put.',
            style: TextStyle(fontSize: 12, color: Color(0xFF8B949E)),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            await BenchSettings.save(
              baseUrl: urlController.text,
              adminToken: tokenController.text,
            );
            if (c.mounted) Navigator.pop(c);
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}
