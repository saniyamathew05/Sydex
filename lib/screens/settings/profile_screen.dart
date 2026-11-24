import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/profile_store.dart';
import '../../services/theme_controller.dart';
import '../../widgets/profile_avatar.dart';
import '../../widgets/sydex_ui.dart';
import 'display_settings_screen.dart';
import 'two_factor_auth_screen.dart';

class ProfileScreen extends StatefulWidget {
  final String userName;

  final String role;

  const ProfileScreen({super.key, required this.userName, required this.role});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _saving = false;

  bool get _isOwner => widget.role == 'owner';
  String get _roleLabel => _isOwner ? 'Owner' : 'Marketing Executive';

  @override
  void initState() {
    super.initState();
    ProfileStore.loadUser();
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _pickImage() async {
    const group = XTypeGroup(
      label: 'Images',
      extensions: ['jpg', 'jpeg', 'png', 'webp'],
      mimeTypes: ['image/jpeg', 'image/png', 'image/webp'],
      uniformTypeIdentifiers: ['public.image'],
    );
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null) return;
    try {
      await ProfileStore.setPhoto(await file.readAsBytes());
    } catch (error) {
      debugPrint('Could not read the profile picture: $error');
      _message('That file could not be opened as a picture.');
    }
  }

  Future<void> _editName(String current) async {
    var typed = current;
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit your name'),
        content: TextFormField(
          initialValue: current,
          autofocus: true,
          maxLength: 120,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Name'),
          onChanged: (text) => typed = text,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, typed.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (value == null || value.isEmpty || value == current) return;
    setState(() => _saving = true);
    try {
      await ProfileStore.setName(value);
    } catch (_) {
      _message('Could not update your name.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _section(String title, List<Widget> children) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
          child: SydexEyebrow(title),
        ),
        SydexCard(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (index, child) in children.indexed) ...[
                if (index > 0) Divider(height: 1, color: colors.outlineVariant),
                child,
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _choice({
    required String title,
    required String hint,
    required Widget child,
  }) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text(
          hint,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        child,
      ],
    ),
  );

  Widget _swatches({
    required Map<String, Color?> colors,
    required String selected,
    required ValueChanged<String> onSelected,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final MapEntry(key: label, value: color) in colors.entries)
          Tooltip(
            message: label,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => onSelected(label),
              child: Container(
                width: 40,
                height: 40,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    width: 2,
                    color: label == selected
                        ? scheme.onSurface
                        : scheme.outlineVariant,
                  ),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color ?? scheme.surfaceContainerHighest,
                  ),
                  child: label == selected
                      ? Icon(
                          Icons.check_rounded,
                          size: 18,
                          color: color == null
                              ? scheme.onSurface
                              : Colors.white,
                        )
                      : const SizedBox.expand(),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _chips(
    List<String> options,
    String selected,
    ValueChanged<String> onSelected,
  ) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final option in options)
        ChoiceChip(
          label: Text(option),
          selected: option == selected,
          onSelected: (_) => onSelected(option),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser;
    final colors = Theme.of(context).colorScheme;
    final startPages = _isOwner
        ? ProfileStore.ownerStartPages
        : ProfileStore.salesmanStartPages;

    return Scaffold(
      appBar: AppBar(title: const Text('My profile')),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          ProfileStore.changes,
          ProfileStore.startPage,
          ProfileStore.textSize,
          ThemeController.themeMode,
          ThemeController.accentColor,
        ]),
        builder: (context, _) {
          final name = ProfileStore.name.value ?? widget.userName;
          final hasPhoto = ProfileStore.photo.value != null;
          const modes = {
            'Light': ThemeMode.light,
            'Dark': ThemeMode.dark,
            'Match device': ThemeMode.system,
          };
          return ListView(
            padding: sydexPageInsets(
              MediaQuery.sizeOf(context).width,
              maxWidth: 760,
            ),
            children: [
              SydexCard(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _pickImage,
                      child: ProfileAvatar(widget.userName, size: 96),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      name,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _roleLabel,
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      alignment: WrapAlignment.center,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _pickImage,
                          icon: const Icon(
                            Icons.add_a_photo_outlined,
                            size: 18,
                          ),
                          label: Text(hasPhoto ? 'Change photo' : 'Add photo'),
                        ),
                        if (hasPhoto)
                          OutlinedButton.icon(
                            onPressed: ProfileStore.removePhoto,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: colors.error,
                            ),
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 18,
                            ),
                            label: const Text('Remove photo'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              _section('Account', [
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: const Text('Name'),
                  subtitle: Text(name),
                  trailing: TextButton(
                    onPressed: _saving ? null : () => _editName(name),
                    child: Text(_saving ? 'Saving…' : 'Edit'),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.email_outlined),
                  title: const Text('Email'),
                  subtitle: Text(user?.email ?? 'Not available'),
                ),
                ListTile(
                  leading: const Icon(Icons.badge_outlined),
                  title: const Text('Role'),
                  subtitle: Text(_roleLabel),
                ),
                ListTile(
                  leading: const Icon(Icons.security_outlined),
                  title: const Text('Two-factor authentication'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const TwoFactorAuthScreen(),
                    ),
                  ),
                ),
              ]),
              _section('Appearance', [
                _choice(
                  title: 'Light or dark',
                  hint: 'How the whole app looks on this device.',
                  child: _chips(
                    modes.keys.toList(),
                    modes.entries
                        .firstWhere(
                          (e) => e.value == ThemeController.themeMode.value,
                        )
                        .key,
                    (label) => ThemeController.setThemeMode(modes[label]!),
                  ),
                ),
                _choice(
                  title: 'Accent colour',
                  hint: 'Used for buttons and selected items.',
                  child: _swatches(
                    colors: ThemeController.accentChoices,
                    selected: ThemeController.accentName,
                    onSelected: ThemeController.setAccent,
                  ),
                ),
                _choice(
                  title: 'Text size',
                  hint: 'Makes text smaller or larger on this device.',
                  child: _chips(
                    ProfileStore.textSizes.keys.toList(),
                    ProfileStore.textSize.value,
                    ProfileStore.setTextSize,
                  ),
                ),
                if (!hasPhoto)
                  _choice(
                    title: 'Initials colour',
                    hint: 'Behind your initials when you have no photo.',
                    child: _swatches(
                      colors: ProfileStore.avatarColors,
                      selected: ProfileStore.avatarColor.value,
                      onSelected: ProfileStore.setAvatarColor,
                    ),
                  ),
              ]),
              _section('Preferences', [
                _choice(
                  title: 'Start page',
                  hint: 'The page that opens after you sign in.',
                  child: _chips(
                    startPages,
                    startPages[ProfileStore.startPage.value.clamp(
                      0,
                      startPages.length - 1,
                    )],
                    (label) =>
                        ProfileStore.setStartPage(startPages.indexOf(label)),
                  ),
                ),
                if (_isOwner)
                  ListTile(
                    leading: const Icon(Icons.visibility_outlined),
                    title: const Text('Display options'),
                    subtitle: const Text('What you and your salesmen see'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const DisplaySettingsScreen(),
                      ),
                    ),
                  ),
              ]),
            ],
          );
        },
      ),
    );
  }
}
