import 'dart:async';

import 'package:flutter/material.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

class UserManagementScreen extends StatefulWidget {
  const UserManagementScreen({super.key});

  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends State<UserManagementScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;

  bool _isLoading = true;

  String? _busyUserId;

  List<Map<String, dynamic>> _users = [];

  Timer? _presenceTimer;

  @override
  void initState() {
    super.initState();

    _loadUsers();

    _refreshPresence();

    _presenceTimer = Timer.periodic(
      const Duration(seconds: 15),

      (_) => _refreshPresence(),
    );
  }

  @override
  void dispose() {
    _presenceTimer?.cancel();

    super.dispose();
  }

  Future<void> _loadUsers() async {
    if (mounted) {
      setState(() {
        _isLoading = true;
      });
    }

    try {
      final response = await _supabase
          .from('profiles')
          .select('id, name, role, created_at, last_seen, force_logout_at')
          .order('created_at', ascending: true);

      if (!mounted) return;

      setState(() {
        _users = List<Map<String, dynamic>>.from(response);

        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _isLoading = false;
      });

      _showMessage('Could not load users:\n$error', isError: true);
    }
  }

  Future<void> _refreshPresence() async {
    try {
      final response = await _supabase
          .from('profiles')
          .select('id, role, last_seen, force_logout_at')
          .eq('role', 'salesman');

      if (!mounted) return;

      final presenceById = {
        for (final row in List<Map<String, dynamic>>.from(response))
          row['id'].toString(): row,
      };

      setState(() {
        for (var i = 0; i < _users.length; i++) {
          final id = _users[i]['id']?.toString();

          final presence = presenceById[id];

          if (presence != null) {
            _users[i]['last_seen'] = presence['last_seen'];

            _users[i]['force_logout_at'] = presence['force_logout_at'];
          }
        }
      });
    } catch (_) {
      // Presence refresh must not affect existing user-management features.
    }
  }

  bool _isSalesmanActive(String? value) {
    if (value == null || value.isEmpty) return false;

    final lastSeen = DateTime.tryParse(value);

    if (lastSeen == null) return false;

    final seconds = DateTime.now()
        .toUtc()
        .difference(lastSeen.toUtc())
        .inSeconds;

    return seconds <= 45;
  }

  String _formatLastSeen(String? value) {
    if (value == null || value.isEmpty) return 'Never';

    final lastSeen = DateTime.tryParse(value);

    if (lastSeen == null) return 'Unknown';

    final seconds = DateTime.now()
        .toUtc()
        .difference(lastSeen.toUtc())
        .inSeconds;

    if (seconds <= 10) return 'Just now';

    if (seconds < 60) return '${seconds}s ago';

    final minutes = seconds ~/ 60;

    if (minutes < 60) return '${minutes}m ago';

    final hours = minutes ~/ 60;

    if (hours < 24) return '${hours}h ago';

    return _formatDate(value);
  }

  Future<void> _forceLogoutUser(Map<String, dynamic> user) async {
    final userId = user['id']?.toString();

    final name = user['name']?.toString() ?? 'this salesman';

    if (userId == null || userId.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,

      builder: (dialogContext) => AlertDialog(
        title: const Text('Force Logout?'),

        content: Text('Force $name to log out of the app?'),

        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),

            child: const Text('Cancel'),
          ),

          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),

            child: const Text('Force Logout'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _busyUserId = userId);

    try {
      await _supabase.rpc(
        'force_logout_salesman',

        params: {'target_user_id': userId},
      );

      await _refreshPresence();

      if (mounted) _showMessage('$name has been marked for force logout.');
    } catch (error) {
      if (mounted) {
        _showMessage('Could not force logout $name:\n$error', isError: true);
      }
    } finally {
      if (mounted) setState(() => _busyUserId = null);
    }
  }

  Future<void> _showAddUserDialog() async {
    final nameController = TextEditingController();

    final emailController = TextEditingController();

    final passwordController = TextEditingController();

    String selectedRole = 'salesman';

    bool obscurePassword = true;

    await showDialog<void>(
      context: context,

      builder: (dialogContext) {
        bool creating = false;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Add User'),

              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,

                  children: [
                    TextField(
                      controller: nameController,

                      enabled: !creating,

                      textCapitalization: TextCapitalization.words,

                      decoration: const InputDecoration(
                        labelText: 'Name',

                        prefixIcon: Icon(Icons.person_outline),

                        border: OutlineInputBorder(),
                      ),
                    ),

                    const SizedBox(height: 16),

                    TextField(
                      controller: emailController,

                      enabled: !creating,

                      keyboardType: TextInputType.emailAddress,

                      decoration: const InputDecoration(
                        labelText: 'Email',

                        prefixIcon: Icon(Icons.email_outlined),

                        border: OutlineInputBorder(),
                      ),
                    ),

                    const SizedBox(height: 16),

                    TextField(
                      controller: passwordController,

                      enabled: !creating,

                      obscureText: obscurePassword,

                      decoration: InputDecoration(
                        labelText: 'Password',

                        prefixIcon: const Icon(Icons.lock_outline),

                        border: const OutlineInputBorder(),

                        suffixIcon: IconButton(
                          onPressed: creating
                              ? null
                              : () {
                                  setDialogState(() {
                                    obscurePassword = !obscurePassword;
                                  });
                                },

                          icon: Icon(
                            obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 16),

                    DropdownButtonFormField<String>(
                      initialValue: selectedRole,

                      decoration: const InputDecoration(
                        labelText: 'Role',

                        prefixIcon: Icon(Icons.badge_outlined),

                        border: OutlineInputBorder(),
                      ),

                      items: const [
                        DropdownMenuItem(
                          value: 'salesman',

                          child: Text('Marketing Executive'),
                        ),

                        DropdownMenuItem(value: 'owner', child: Text('Owner')),
                      ],

                      onChanged: creating
                          ? null
                          : (value) {
                              if (value == null) return;

                              setDialogState(() {
                                selectedRole = value;
                              });
                            },
                    ),
                  ],
                ),
              ),

              actions: [
                TextButton(
                  onPressed: creating
                      ? null
                      : () {
                          Navigator.pop(dialogContext);
                        },

                  child: const Text('Cancel'),
                ),

                FilledButton(
                  onPressed: creating
                      ? null
                      : () async {
                          final name = nameController.text.trim();

                          final email = emailController.text.trim();

                          final password = passwordController.text;

                          if (name.isEmpty ||
                              email.isEmpty ||
                              password.isEmpty) {
                            _showMessage(
                              'Please fill in all fields.',

                              isError: true,
                            );

                            return;
                          }

                          if (!email.contains('@')) {
                            _showMessage(
                              'Please enter a valid email.',

                              isError: true,
                            );

                            return;
                          }

                          if (password.length < 6) {
                            _showMessage(
                              'Password must contain at least 6 characters.',

                              isError: true,
                            );

                            return;
                          }

                          setDialogState(() {
                            creating = true;
                          });

                          final success = await _createUser(
                            name: name,

                            email: email,

                            password: password,

                            role: selectedRole,
                          );

                          if (!dialogContext.mounted) return;

                          if (success) {
                            Navigator.pop(dialogContext);
                          } else {
                            setDialogState(() {
                              creating = false;
                            });
                          }
                        },

                  child: creating
                      ? const SizedBox(
                          width: 20,

                          height: 20,

                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Create User'),
                ),
              ],
            );
          },
        );
      },
    );

    nameController.dispose();

    emailController.dispose();

    passwordController.dispose();
  }

  Future<bool> _createUser({
    required String name,

    required String email,

    required String password,

    required String role,
  }) async {
    try {
      final response = await _supabase.functions.invoke(
        'create-user',

        body: {
          'action': 'create',

          'name': name,

          'email': email,

          'password': password,

          'role': role,
        },
      );

      if (response.status != 201) {
        _showResponseError(response, 'Could not create the user.');

        return false;
      }

      await _loadUsers();

      if (!mounted) return true;

      _showMessage('$name was created successfully.');

      return true;
    } on FunctionException catch (error) {
      _showFunctionError(error, 'Could not create the user.');

      return false;
    } catch (error) {
      _showMessage('Could not create the user:\n$error', isError: true);

      return false;
    }
  }

  Future<void> _showEditUserDialog(Map<String, dynamic> user) async {
    final userId = user['id']?.toString() ?? '';

    final originalName = user['name']?.toString() ?? '';

    final originalRole = user['role']?.toString() ?? 'salesman';

    if (userId.isEmpty) {
      _showMessage('User ID is missing.', isError: true);

      return;
    }

    final currentUserId = _supabase.auth.currentUser?.id;

    final isCurrentUser = userId == currentUserId;

    final nameController = TextEditingController(text: originalName);

    final passwordController = TextEditingController();

    String selectedRole = originalRole;

    bool obscurePassword = true;

    await showDialog<void>(
      context: context,

      builder: (dialogContext) {
        bool saving = false;

        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(isCurrentUser ? 'Edit My Profile' : 'Edit User'),

              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,

                  children: [
                    TextField(
                      controller: nameController,

                      enabled: !saving,

                      textCapitalization: TextCapitalization.words,

                      decoration: const InputDecoration(
                        labelText: 'Name',

                        prefixIcon: Icon(Icons.person_outline),

                        border: OutlineInputBorder(),
                      ),
                    ),

                    const SizedBox(height: 16),

                    DropdownButtonFormField<String>(
                      initialValue: selectedRole,

                      decoration: const InputDecoration(
                        labelText: 'Role',

                        prefixIcon: Icon(Icons.badge_outlined),

                        border: OutlineInputBorder(),
                      ),

                      items: const [
                        DropdownMenuItem(
                          value: 'salesman',

                          child: Text('Marketing Executive'),
                        ),

                        DropdownMenuItem(value: 'owner', child: Text('Owner')),
                      ],

                      onChanged: saving || isCurrentUser
                          ? null
                          : (value) {
                              if (value == null) {
                                return;
                              }

                              setDialogState(() {
                                selectedRole = value;
                              });
                            },
                    ),

                    const SizedBox(height: 16),

                    TextField(
                      controller: passwordController,

                      enabled: !saving && !isCurrentUser,

                      obscureText: obscurePassword,

                      decoration: InputDecoration(
                        labelText: 'New Password (optional)',

                        prefixIcon: const Icon(Icons.lock_outline),

                        border: const OutlineInputBorder(),

                        suffixIcon: IconButton(
                          onPressed: saving || isCurrentUser
                              ? null
                              : () {
                                  setDialogState(() {
                                    obscurePassword = !obscurePassword;
                                  });
                                },

                          icon: Icon(
                            obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                    ),

                    if (isCurrentUser) ...[
                      const SizedBox(height: 10),

                      const Align(
                        alignment: Alignment.centerLeft,

                        child: Text(
                          'Your owner role and password cannot be changed here.',

                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              actions: [
                TextButton(
                  onPressed: saving
                      ? null
                      : () {
                          Navigator.pop(dialogContext);
                        },

                  child: const Text('Cancel'),
                ),

                FilledButton(
                  onPressed: saving
                      ? null
                      : () async {
                          final name = nameController.text.trim();

                          final password = passwordController.text;

                          if (name.isEmpty) {
                            _showMessage(
                              'Name cannot be empty.',

                              isError: true,
                            );

                            return;
                          }

                          if (password.isNotEmpty && password.length < 6) {
                            _showMessage(
                              'Password must contain at least 6 characters.',

                              isError: true,
                            );

                            return;
                          }

                          if (isCurrentUser) {
                            selectedRole = 'owner';
                          }

                          setDialogState(() {
                            saving = true;
                          });

                          final success = await _updateUser(
                            userId: userId,

                            name: name,

                            role: selectedRole,

                            password: password,
                          );

                          if (!dialogContext.mounted) return;

                          if (success) {
                            Navigator.pop(dialogContext);
                          } else {
                            setDialogState(() {
                              saving = false;
                            });
                          }
                        },

                  child: saving
                      ? const SizedBox(
                          width: 20,

                          height: 20,

                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save Changes'),
                ),
              ],
            );
          },
        );
      },
    );

    nameController.dispose();

    passwordController.dispose();
  }

  Future<bool> _updateUser({
    required String userId,

    required String name,

    required String role,

    required String password,
  }) async {
    setState(() {
      _busyUserId = userId;
    });

    try {
      final response = await _supabase.functions.invoke(
        'create-user',

        body: {
          'action': 'update',

          'userId': userId,

          'name': name,

          'role': role,

          'password': password,
        },
      );

      if (response.status != 200) {
        _showResponseError(response, 'Could not update the user.');

        return false;
      }

      await _loadUsers();

      if (!mounted) return true;

      _showMessage('$name was updated successfully.');

      return true;
    } on FunctionException catch (error) {
      _showFunctionError(error, 'Could not update the user.');

      return false;
    } catch (error) {
      _showMessage('Could not update the user:\n$error', isError: true);

      return false;
    } finally {
      if (mounted) {
        setState(() {
          _busyUserId = null;
        });
      }
    }
  }

  Future<void> _confirmDeleteUser(Map<String, dynamic> user) async {
    final userId = user['id']?.toString() ?? '';

    final name = user['name']?.toString() ?? 'this user';

    final role = user['role']?.toString() ?? 'unknown';

    final currentUserId = _supabase.auth.currentUser?.id;

    if (userId.isEmpty) {
      _showMessage('User ID is missing.', isError: true);

      return;
    }

    if (userId == currentUserId) {
      _showMessage('You cannot delete your own account.', isError: true);

      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,

      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Delete User?'),

          content: Text(
            'Are you sure you want to permanently '
            'delete $name (${_roleLabel(role)})?\n\n'
            'Their login account and profile will be removed.',
          ),

          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext, false);
              },

              child: const Text('Cancel'),
            ),

            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,

                foregroundColor: Theme.of(context).colorScheme.onError,
              ),

              onPressed: () {
                Navigator.pop(dialogContext, true);
              },

              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    await _deleteUser(userId, name);
  }

  Future<void> _deleteUser(String userId, String name) async {
    setState(() {
      _busyUserId = userId;
    });

    try {
      final response = await _supabase.functions.invoke(
        'create-user',

        body: {'action': 'delete', 'userId': userId},
      );

      if (response.status != 200) {
        _showResponseError(response, 'Could not delete the user.');

        return;
      }

      if (!mounted) return;

      setState(() {
        _users.removeWhere((user) => user['id']?.toString() == userId);
      });

      _showMessage('$name was deleted successfully.');
    } on FunctionException catch (error) {
      _showFunctionError(error, 'Could not delete the user.');
    } catch (error) {
      _showMessage('Could not delete the user:\n$error', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _busyUserId = null;
        });
      }
    }
  }

  void _showResponseError(FunctionResponse response, String fallback) {
    String message = fallback;

    final data = response.data;

    if (data is Map && data['error'] != null) {
      message = data['error'].toString();
    }

    _showMessage(message, isError: true);
  }

  void _showFunctionError(FunctionException error, String fallback) {
    String message = fallback;

    final details = error.details;

    if (details is Map && details['error'] != null) {
      message = details['error'].toString();
    } else if (details != null) {
      message = details.toString();
    } else if (error.reasonPhrase != null) {
      message = error.reasonPhrase!;
    }

    _showMessage(message, isError: true);
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),

          behavior: SnackBarBehavior.floating,

          duration: const Duration(seconds: 4),
        ),
      );
  }

  String _roleLabel(String role) {
    switch (role) {
      case 'owner':
        return 'Owner';

      case 'salesman':
        return 'Marketing Executive';

      default:
        return role;
    }
  }

  IconData _roleIcon(String role) {
    if (role == 'owner') {
      return Icons.admin_panel_settings_outlined;
    }

    return Icons.point_of_sale_outlined;
  }

  String _formatDate(String? value) {
    if (value == null || value.isEmpty) {
      return '';
    }

    final date = DateTime.tryParse(value);

    if (date == null) {
      return '';
    }

    return '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/'
        '${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('User Management')),

      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddUserDialog,

        icon: const Icon(Icons.person_add),

        label: const Text('Add User'),
      ),

      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadUsers,

              child: _users.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),

                      children: const [
                        SizedBox(height: 180),

                        Center(child: Text('No users found.')),
                      ],
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),

                      itemCount: _users.length,

                      itemBuilder: (context, index) {
                        final user = _users[index];

                        final id = user['id']?.toString() ?? '';

                        final name = user['name']?.toString() ?? 'Unnamed User';

                        final role = user['role']?.toString() ?? 'unknown';

                        final createdAt = user['created_at']?.toString();

                        final currentUserId = _supabase.auth.currentUser?.id;

                        final isCurrentUser = id == currentUserId;

                        final isBusy = _busyUserId == id;

                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),

                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,

                              vertical: 8,
                            ),

                            leading: CircleAvatar(child: Icon(_roleIcon(role))),

                            title: Text(
                              name,

                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),

                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,

                              children: [
                                const SizedBox(height: 4),

                                Text(_roleLabel(role)),

                                if (role == 'salesman') ...[
                                  const SizedBox(height: 4),

                                  Row(
                                    mainAxisSize: MainAxisSize.min,

                                    children: [
                                      Container(
                                        width: 8,

                                        height: 8,

                                        decoration: BoxDecoration(
                                          color:
                                              _isSalesmanActive(
                                                user['last_seen']?.toString(),
                                              )
                                              ? Colors.green
                                              : Colors.grey,

                                          shape: BoxShape.circle,
                                        ),
                                      ),

                                      const SizedBox(width: 6),

                                      Text(
                                        _isSalesmanActive(
                                              user['last_seen']?.toString(),
                                            )
                                            ? 'Active'
                                            : 'Offline',

                                        style: TextStyle(
                                          color:
                                              _isSalesmanActive(
                                                user['last_seen']?.toString(),
                                              )
                                              ? Colors.green
                                              : Colors.grey,

                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),

                                  Text(
                                    'Last seen: ${_formatLastSeen(user['last_seen']?.toString())}',
                                  ),
                                ],

                                if (_formatDate(createdAt).isNotEmpty)
                                  Text('Created: ${_formatDate(createdAt)}'),
                              ],
                            ),

                            trailing: isBusy
                                ? const SizedBox(
                                    width: 24,

                                    height: 24,

                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Row(
                                    mainAxisSize: MainAxisSize.min,

                                    children: [
                                      IconButton(
                                        tooltip: 'Edit User',

                                        icon: const Icon(Icons.edit_outlined),

                                        onPressed: () =>
                                            _showEditUserDialog(user),
                                      ),

                                      if (role == 'salesman' && !isCurrentUser)
                                        IconButton(
                                          tooltip: 'Force Logout',

                                          icon: const Icon(
                                            Icons.logout_outlined,
                                          ),

                                          onPressed: isBusy
                                              ? null
                                              : () => _forceLogoutUser(user),
                                        ),

                                      if (!isCurrentUser)
                                        IconButton(
                                          tooltip: 'Delete User',

                                          icon: Icon(
                                            Icons.delete_outline,

                                            color: Theme.of(
                                              context,
                                            ).colorScheme.error,
                                          ),

                                          onPressed: () =>
                                              _confirmDeleteUser(user),
                                        ),
                                    ],
                                  ),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}
