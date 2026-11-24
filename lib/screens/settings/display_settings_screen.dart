import 'package:flutter/material.dart';

import '../../services/owner_display_settings.dart';
import '../../widgets/sydex_ui.dart';

/// Owner-only choices about what owners and salesmen see in the app.
class DisplaySettingsScreen extends StatefulWidget {
  const DisplaySettingsScreen({super.key});

  @override
  State<DisplaySettingsScreen> createState() => _DisplaySettingsScreenState();
}

class _DisplaySettingsScreenState extends State<DisplaySettingsScreen> {
  static const _tabs = ['Owner view', 'Salesman view'];
  String _tab = _tabs.first;
  bool _saving = false;

  bool get _salesman => _tab == _tabs.last;

  @override
  void initState() {
    super.initState();
    SalesmanDisplaySettings.load();
  }

  Future<void> _run(Future<void> Function() save) async {
    setState(() => _saving = true);
    try {
      await save();
    } catch (error) {
      debugPrint('Could not save display options: $error');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save this change. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final groups = <String, List<DisplayOption>>{};
    for (final option
        in _salesman
            ? SalesmanDisplaySettings.options
            : OwnerDisplaySettings.options) {
      groups.putIfAbsent(option.group, () => []).add(option);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Display options')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          OwnerDisplaySettings.values,
          SalesmanDisplaySettings.values,
        ]),
        builder: (context, _) => ListView(
          padding: sydexPageInsets(
            MediaQuery.sizeOf(context).width,
            maxWidth: 760,
          ),
          children: [
            SydexChoiceChips(
              options: _tabs,
              selected: _tab,
              onSelected: (tab) => setState(() => _tab = tab),
            ),
            const SizedBox(height: 12),
            Text(
              _salesman
                  ? 'Applies to every salesman in your company the next time their app refreshes. It hides things on screen; it does not change what a salesman is allowed to do.'
                  : 'Applies to the owner account on this device.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: colors.onSurfaceVariant,
              ),
            ),
            for (final group in groups.entries) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
                child: SydexEyebrow(group.key),
              ),
              SydexCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (final (index, option) in group.value.indexed) ...[
                      if (index > 0)
                        Divider(height: 1, color: colors.outlineVariant),
                      SwitchListTile(
                        title: Text(option.title),
                        subtitle: Text(option.subtitle),
                        value: _salesman
                            ? SalesmanDisplaySettings.show(option.key)
                            : OwnerDisplaySettings.show(option.key),
                        onChanged: _saving
                            ? null
                            : (value) => _run(
                                () => _salesman
                                    ? SalesmanDisplaySettings.set(
                                        option.key,
                                        value,
                                      )
                                    : OwnerDisplaySettings.set(
                                        option.key,
                                        value,
                                      ),
                              ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: _saving
                  ? null
                  : () => _run(
                      _salesman
                          ? SalesmanDisplaySettings.reset
                          : OwnerDisplaySettings.reset,
                    ),
              icon: const Icon(Icons.restart_alt_rounded, size: 18),
              label: const Text('Show everything'),
            ),
          ],
        ),
      ),
    );
  }
}
