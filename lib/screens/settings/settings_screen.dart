import 'package:flutter/material.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../main.dart';

import '../../services/theme_controller.dart';
import '../../services/history_display_settings.dart';
import '../../services/profile_store.dart';
import '../../widgets/profile_avatar.dart';
import 'display_settings_screen.dart';

import 'business_information_screen.dart';

import 'payment_settings_screen.dart';

import 'export_data_screen.dart';

import 'profile_screen.dart';

import 'signature_settings_screen.dart';

import 'sync_status_screen.dart';
import 'two_factor_auth_screen.dart';

import 'user_management_screen.dart';
import 'subscription_billing_screen.dart';
import '../onboarding/onboarding_screen.dart';
import '../../widgets/sydex_ui.dart';

class SettingsScreen extends StatelessWidget {
  final String role;

  final String userName;

  const SettingsScreen({super.key, required this.role, required this.userName});

  bool get isOwner => role == 'owner';

  Future<void> _logout(BuildContext context) async {
    final shouldLogout = await showDialog<bool>(
      context: context,

      builder: (context) {
        return AlertDialog(
          title: const Text('Log out?'),

          content: const Text(
            'Are you sure you want to log out of this account?',
          ),

          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context, false);
              },

              child: const Text('Cancel'),
            ),

            FilledButton(
              onPressed: () {
                Navigator.pop(context, true);
              },

              child: const Text('Log out'),
            ),
          ],
        );
      },
    );

    if (shouldLogout != true) return;

    await Supabase.instance.client.auth.signOut();

    if (!context.mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => LoginScreen()),

      (route) => false,
    );
  }

  Future<void> _deleteMyAccount(BuildContext context) async {
    if (isOwner) {
      _showInfo(
        context,
        'Account deletion',
        'Owner accounts cannot be self-deleted because the workspace must first be transferred or closed.',
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete my account?'),
        content: const Text(
          'Your login and profile will be permanently removed. Historical payments, ledger entries and visit records will remain for the business, but your user identity will be anonymised. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete account'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await Supabase.instance.client.functions.invoke('delete-my-account');
      await Supabase.instance.client.auth.signOut();
      if (context.mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => LoginScreen()),
          (_) => false,
        );
      }
    } catch (error) {
      if (context.mounted) {
        _showInfo(context, 'Could not delete account', error.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = Supabase.instance.client.auth.currentUser?.email ?? 'Unknown';

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),

      body: _SettingsWorkspace(
        children: [
          const _SettingsSectionTitle(title: 'ACCOUNT'),

          ListenableBuilder(
            listenable: ProfileStore.changes,
            builder: (context, _) => ListTile(
              leading: ProfileAvatar(userName, size: 44),
              title: Text(
                ProfileStore.name.value ?? userName,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                '$email\n${isOwner ? 'Owner' : 'Marketing Executive'}',
              ),
              isThreeLine: true,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => ProfileScreen(userName: userName, role: role),
                ),
              ),
            ),
          ),

          const Divider(),

          const _SettingsSectionTitle(title: 'APPEARANCE'),

          ValueListenableBuilder<ThemeMode>(
            valueListenable: ThemeController.themeMode,

            builder: (context, mode, _) {
              return RadioGroup<ThemeMode>(
                groupValue: mode,
                onChanged: (value) {
                  if (value != null) {
                    ThemeController.setTheme(value);
                  }
                },
                child: Column(
                  children: [
                    RadioListTile<ThemeMode>(
                      value: ThemeMode.light,
                      secondary: const Icon(Icons.light_mode_outlined),
                      title: const Text('Light mode'),
                    ),
                    RadioListTile<ThemeMode>(
                      value: ThemeMode.dark,
                      secondary: const Icon(Icons.dark_mode_outlined),
                      title: const Text('Dark mode'),
                    ),
                    RadioListTile<ThemeMode>(
                      value: ThemeMode.system,
                      secondary: const Icon(Icons.brightness_auto_outlined),
                      title: const Text('Use device setting'),
                    ),
                  ],
                ),
              );
            },
          ),

          ValueListenableBuilder<Color>(
            valueListenable: ThemeController.accentColor,
            builder: (context, selected, _) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Brand accent',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Choose the primary color used across this device.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: ThemeController.accentChoices.entries.map((
                      entry,
                    ) {
                      final isSelected =
                          entry.value.toARGB32() == selected.toARGB32();
                      return Tooltip(
                        message: entry.key,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: () => ThemeController.setAccent(entry.key),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: entry.value,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isSelected
                                    ? Theme.of(context).colorScheme.onSurface
                                    : Colors.transparent,
                                width: 2,
                              ),
                            ),
                            child: isSelected
                                ? const Icon(
                                    Icons.check_rounded,
                                    color: Colors.white,
                                    size: 18,
                                  )
                                : null,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ),

          if (isOwner) const _SettingsSectionTitle(title: 'DISPLAY'),

          if (isOwner)
            ListTile(
              leading: const Icon(Icons.visibility_outlined),
              title: const Text('Display options'),
              subtitle: const Text('What owners and salesmen see in the app'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const DisplaySettingsScreen(),
                ),
              ),
            ),

          if (isOwner)
            ValueListenableBuilder<int>(
              valueListenable: HistoryDisplaySettings.limit,
              builder: (context, limit, _) => ListTile(
                leading: const Icon(Icons.history_outlined),
                title: const Text('Recent payment history'),
                subtitle: Text(
                  limit == 0
                      ? 'Show all transactions'
                      : 'Show the latest $limit payments',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final controller = TextEditingController(
                    text: limit == 0 ? '' : limit.toString(),
                  );
                  final value = await showDialog<int>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: const Text('Recent payment history'),
                      content: TextField(
                        controller: controller,
                        autofocus: true,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Number of payments (blank = all)',
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(
                            dialogContext,
                            int.tryParse(controller.text.trim()) ?? 0,
                          ),
                          child: const Text('Save'),
                        ),
                      ],
                    ),
                  );
                  controller.dispose();
                  if (value != null) {
                    await HistoryDisplaySettings.setLimit(value);
                  }
                },
              ),
            ),

          const Divider(),

          const _SettingsSectionTitle(title: 'SECURITY'),

          ListTile(
            leading: const Icon(Icons.security_outlined),
            title: const Text('Two-factor authentication'),
            subtitle: const Text(
              'Use an authenticator app for a second sign-in check',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TwoFactorAuthScreen()),
            ),
          ),

          if (isOwner) ...[
            const _SettingsSectionTitle(title: 'BUSINESS'),

            ListTile(
              leading: const Icon(Icons.workspace_premium_outlined),
              title: const Text('Subscription & billing'),
              subtitle: const Text(
                'View workspace plan and subscription status',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const SubscriptionBillingScreen(),
                ),
              ),
            ),

            ListTile(
              leading: const Icon(Icons.business_outlined),

              title: const Text('Business information'),

              subtitle: const Text(
                'Business name, address and contact details',
              ),

              trailing: const Icon(Icons.chevron_right),

              onTap: () {
                Navigator.push(
                  context,

                  MaterialPageRoute(
                    builder: (_) => const BusinessInformationScreen(),
                  ),
                );
              },
            ),

            ListTile(
              leading: const Icon(Icons.people_outline),

              title: const Text('User management'),

              subtitle: const Text('Manage owners and salesmen'),

              trailing: const Icon(Icons.chevron_right),

              onTap: () {
                Navigator.push(
                  context,

                  MaterialPageRoute(builder: (_) => UserManagementScreen()),
                );
              },
            ),

            ListTile(
              leading: const Icon(Icons.download_outlined),

              title: const Text('Export data'),

              subtitle: const Text('Export customers and payment records'),

              trailing: const Icon(Icons.chevron_right),

              onTap: () {
                Navigator.push(
                  context,

                  MaterialPageRoute(builder: (_) => const ExportDataScreen()),
                );
              },
            ),

            ListTile(
              leading: const Icon(Icons.tune_outlined),

              title: const Text('Payment settings'),

              subtitle: const Text('Configure payment and collection options'),

              trailing: const Icon(Icons.chevron_right),

              onTap: () {
                Navigator.push(
                  context,

                  MaterialPageRoute(
                    builder: (_) => const PaymentSettingsScreen(),
                  ),
                );
              },
            ),

            const Divider(),
          ],

          if (!isOwner) ...[
            const _SettingsSectionTitle(title: 'SALESMAN'),

            ListTile(
              leading: const Icon(Icons.workspace_premium_outlined),
              title: const Text('Subscription & billing'),
              subtitle: const Text('View your workspace subscription status'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const SubscriptionBillingScreen(),
                ),
              ),
            ),

            ListTile(
              leading: const Icon(Icons.edit_outlined),

              title: const Text('My profile'),

              subtitle: const Text('View your account information'),

              trailing: const Icon(Icons.chevron_right),

              onTap: () {
                Navigator.push(
                  context,

                  MaterialPageRoute(
                    builder: (_) =>
                        ProfileScreen(userName: userName, role: role),
                  ),
                );
              },
            ),

            ListTile(
              leading: const Icon(Icons.draw_outlined),

              title: const Text('Signature settings'),

              subtitle: const Text('Signature options'),

              trailing: const Icon(Icons.chevron_right),

              onTap: () {
                Navigator.push(
                  context,

                  MaterialPageRoute(
                    builder: (_) => const SignatureSettingsScreen(),
                  ),
                );
              },
            ),

            ListTile(
              leading: const Icon(Icons.sync_outlined),

              title: const Text('Sync status'),

              subtitle: const Text('Check connection and data synchronization'),

              trailing: const Icon(Icons.chevron_right),

              onTap: () {
                Navigator.push(
                  context,

                  MaterialPageRoute(builder: (_) => const SyncStatusScreen()),
                );
              },
            ),

            const Divider(),
          ],

          const _SettingsSectionTitle(title: 'APP'),

          ListTile(
            leading: const Icon(Icons.notifications_outlined),

            title: const Text('Notifications'),

            subtitle: const Text('Payment and account notifications'),

            trailing: const Icon(Icons.chevron_right),

            onTap: () {
              _showInfo(
                context,

                'Notifications',

                'Notification controls will be available here.',
              );
            },
          ),

          ListTile(
            leading: const Icon(Icons.auto_stories_outlined),
            title: const Text('Replay app tour'),
            subtitle: const Text('See the welcome walkthrough again'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (routeContext) => OnboardingScreen(
                    onFinished: () => Navigator.of(routeContext).pop(),
                  ),
                ),
              );
            },
          ),

          ListTile(
            leading: const Icon(Icons.info_outline),

            title: const Text('About'),

            subtitle: const Text('Sydex'),

            trailing: const Icon(Icons.chevron_right),

            onTap: () {
              showAboutDialog(
                context: context,

                applicationName: 'Sydex',

                applicationVersion: '1.0.0',

                applicationLegalese:
                    'Business payment and collection management.',
              );
            },
          ),

          const SizedBox(height: 12),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                leading: Icon(
                  Icons.person_remove_outlined,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  'Delete my account',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: Text(
                  isOwner
                      ? 'Owner accounts require workspace transfer first'
                      : 'Remove your login and anonymise your historical activity',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
                onTap: () => _deleteMyAccount(context),
              ),
            ),
          ),

          const SizedBox(height: 8),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),

            child: Card(
              child: ListTile(
                leading: Icon(
                  Icons.logout,
                  color: Theme.of(context).colorScheme.error,
                ),

                title: Text(
                  'Log out',

                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,

                    fontWeight: FontWeight.w700,
                  ),
                ),

                subtitle: const Text('Sign out of this account'),

                onTap: () {
                  _logout(context);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  static void _showInfo(BuildContext context, String title, String message) {
    showDialog<void>(
      context: context,

      builder: (context) {
        return AlertDialog(
          title: Text(title),

          content: Text(message),

          actions: [
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
              },

              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }
}

class _SettingsSectionTitle extends StatelessWidget {
  final String title;

  const _SettingsSectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),

      child: Text(
        title,

        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,

          fontSize: 11,

          fontWeight: FontWeight.w500,

          letterSpacing: .8,
        ),
      ),
    );
  }
}

/// The existing role-filtered settings remain the source of truth. Wide windows
/// organize those same controls into categories without duplicating permissions.
class _SettingsWorkspace extends StatefulWidget {
  final List<Widget> children;
  const _SettingsWorkspace({required this.children});

  @override
  State<_SettingsWorkspace> createState() => _SettingsWorkspaceState();
}

class _SettingsWorkspaceState extends State<_SettingsWorkspace> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 760) {
          // Phone: each section becomes a captioned card, as in the Sydex
          // design. The same role-filtered controls are used unchanged.
          final groups = <(String, List<Widget>)>[];
          for (final child in widget.children) {
            if (child is _SettingsSectionTitle) {
              groups.add((child.title, <Widget>[]));
            } else if (child is Divider) {
              continue;
            } else {
              if (groups.isEmpty) groups.add(('', <Widget>[]));
              groups.last.$2.add(child);
            }
          }
          final colors = Theme.of(context).colorScheme;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 30),
            children: [
              for (final (index, group) in groups.indexed)
                if (group.$2.isNotEmpty)
                  SydexReveal(
                    index: index,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (group.$1.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
                              child: SydexEyebrow(group.$1),
                            ),
                          Container(
                            clipBehavior: Clip.antiAlias,
                            decoration: BoxDecoration(
                              color: colors.surface,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(color: colors.outlineVariant),
                            ),
                            child: Material(
                              type: MaterialType.transparency,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (final (i, item) in group.$2.indexed) ...[
                                    if (i > 0)
                                      Divider(
                                        height: 1,
                                        indent: 16,
                                        endIndent: 16,
                                        color: colors.outlineVariant,
                                      ),
                                    item,
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
            ],
          );
        }
        final sections = <String, List<Widget>>{};
        var name = 'ACCOUNT';
        for (final child in widget.children) {
          if (child is _SettingsSectionTitle) {
            name = child.title;
            sections.putIfAbsent(name, () => []);
          } else {
            sections.putIfAbsent(name, () => []).add(child);
          }
        }
        final selected = sections.containsKey(_selected)
            ? _selected!
            : sections.keys.first;
        final colors = Theme.of(context).colorScheme;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 200,
              decoration: BoxDecoration(
                border: Border(right: BorderSide(color: colors.outlineVariant)),
              ),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 12, 12, 20),
                    child: Text(
                      'PREFERENCES',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.4,
                      ),
                    ),
                  ),
                  for (final name in sections.keys)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: ListTile(
                        selected: name == selected,
                        selectedTileColor: colors.primary.withValues(
                          alpha: .09,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        title: Text(
                          name[0] + name.substring(1).toLowerCase(),
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        onTap: () => setState(() => _selected = name),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                key: PageStorageKey('settings-$selected'),
                padding: const EdgeInsets.all(28),
                children: [
                  Text(
                    selected[0] + selected.substring(1).toLowerCase(),
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Manage your ${selected.toLowerCase()} preferences.',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: sections[selected]!,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
