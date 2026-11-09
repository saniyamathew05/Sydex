import 'package:flutter/material.dart';

class SignatureSettingsScreen extends StatelessWidget {
  const SignatureSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Signature Settings')),

      body: ListView(
        padding: const EdgeInsets.all(20),

        children: [
          Container(
            padding: const EdgeInsets.all(18),

            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,

              borderRadius: BorderRadius.circular(18),
            ),

            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,

              children: [
                Icon(Icons.draw_outlined, size: 30),

                SizedBox(width: 14),

                Expanded(
                  child: Text(
                    'Signatures are stored securely with payment records.',
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          Card(
            child: ListTile(
              leading: const Icon(Icons.security_outlined),

              title: const Text('Digital signatures'),

              subtitle: const Text(
                'Signatures are attached to payment records and cannot be deleted by salesmen.',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
