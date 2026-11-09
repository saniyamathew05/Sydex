import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SyncStatusScreen extends StatefulWidget {
  const SyncStatusScreen({super.key});

  @override
  State<SyncStatusScreen> createState() => _SyncStatusScreenState();
}

class _SyncStatusScreenState extends State<SyncStatusScreen> {
  bool _checking = false;

  bool _connected = false;

  @override
  void initState() {
    super.initState();

    _checkConnection();
  }

  Future<void> _checkConnection() async {
    setState(() {
      _checking = true;
    });

    try {
      await Supabase.instance.client.from('customers').select('id').limit(1);

      if (mounted) {
        setState(() {
          _connected = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _connected = false;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _checking = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Sync Status')),

      body: ListView(
        padding: const EdgeInsets.all(20),

        children: [
          Container(
            padding: const EdgeInsets.all(22),

            decoration: BoxDecoration(
              color: _connected
                  ? colors.primaryContainer
                  : colors.errorContainer,

              borderRadius: BorderRadius.circular(20),
            ),

            child: Column(
              children: [
                Icon(
                  _connected
                      ? Icons.cloud_done_outlined
                      : Icons.cloud_off_outlined,

                  size: 50,

                  color: _connected ? colors.primary : colors.error,
                ),

                const SizedBox(height: 12),

                Text(
                  _checking
                      ? 'Checking connection...'
                      : _connected
                      ? 'Connected'
                      : 'Connection unavailable',

                  style: const TextStyle(
                    fontSize: 20,

                    fontWeight: FontWeight.w800,
                  ),
                ),

                const SizedBox(height: 6),

                Text(
                  _connected
                      ? 'Your business data can be synchronized with the server.'
                      : 'Please check your internet connection.',

                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          SizedBox(
            height: 50,

            child: FilledButton.icon(
              onPressed: _checking ? null : _checkConnection,

              icon: _checking
                  ? const SizedBox(
                      width: 18,

                      height: 18,

                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),

              label: const Text('Check Again'),
            ),
          ),
        ],
      ),
    );
  }
}
