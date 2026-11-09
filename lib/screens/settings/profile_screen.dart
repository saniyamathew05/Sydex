import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ProfileScreen extends StatefulWidget {
  final String userName;

  final String role;

  const ProfileScreen({super.key, required this.userName, required this.role});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late String _name;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _name = widget.userName;
  }

  Future<void> _editName() async {
    final controller = TextEditingController(text: _name);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit your name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.isEmpty || value == _name) return;
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    setState(() => _saving = true);
    try {
      await Supabase.instance.client
          .from('profiles')
          .update({'name': value})
          .eq('id', userId);
      if (mounted) setState(() => _name = value);
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update your profile.')),
        );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser;

    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('My Profile')),

      body: ListView(
        padding: const EdgeInsets.all(20),

        children: [
          CircleAvatar(
            radius: 42,

            backgroundColor: colors.primaryContainer,

            child: Text(
              _initials(_name),

              style: TextStyle(
                color: colors.primary,

                fontSize: 24,

                fontWeight: FontWeight.w800,
              ),
            ),
          ),

          const SizedBox(height: 18),

          Center(
            child: Text(
              _name,

              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
          ),

          const SizedBox(height: 6),

          Center(
            child: Text(
              widget.role == 'owner' ? 'Owner' : 'Marketing Executive',

              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ),

          const SizedBox(height: 30),

          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.email_outlined),

                  title: const Text('Email'),

                  subtitle: Text(user?.email ?? 'Not available'),
                ),

                const Divider(height: 1),

                ListTile(
                  leading: const Icon(Icons.badge_outlined),

                  title: const Text('Role'),

                  subtitle: Text(
                    widget.role == 'owner' ? 'Owner' : 'Marketing Executive',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _saving ? null : _editName,
            icon: const Icon(Icons.edit_outlined),
            label: Text(_saving ? 'Saving...' : 'Edit profile'),
          ),
        ],
      ),
    );
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));

    if (parts.isEmpty || parts.first.isEmpty) {
      return 'U';
    }

    if (parts.length == 1) {
      return parts.first[0].toUpperCase();
    }

    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }
}
