import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class BusinessInformationScreen extends StatefulWidget {
  const BusinessInformationScreen({super.key});

  @override
  State<BusinessInformationScreen> createState() =>
      _BusinessInformationScreenState();
}

class _BusinessInformationScreenState extends State<BusinessInformationScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;

  final TextEditingController _businessNameController = TextEditingController();

  final TextEditingController _addressController = TextEditingController();

  final TextEditingController _phoneController = TextEditingController();

  final TextEditingController _emailController = TextEditingController();

  bool _isLoading = true;

  bool _isSaving = false;

  @override
  void initState() {
    super.initState();

    _loadBusinessInformation();
  }

  Future<void> _loadBusinessInformation() async {
    try {
      final response = await _supabase
          .from('business_settings')
          .select()
          .eq('id', 1)
          .maybeSingle();

      if (response != null) {
        _businessNameController.text = response['business_name'] ?? '';

        _addressController.text = response['address'] ?? '';

        _phoneController.text = response['phone'] ?? '';

        _emailController.text = response['email'] ?? '';
      }
    } catch (error) {
      if (mounted) {
        _showSnackBar('Could not load business information.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _saveBusinessInformation() async {
    if (_businessNameController.text.trim().isEmpty) {
      _showSnackBar('Please enter a business name.');

      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      await _supabase.from('business_settings').upsert({
        'id': 1,

        'business_name': _businessNameController.text.trim(),

        'address': _addressController.text.trim(),

        'phone': _phoneController.text.trim(),

        'email': _emailController.text.trim(),

        'updated_at': DateTime.now().toIso8601String(),
      });

      if (!mounted) return;

      _showSnackBar('Business information saved.');

      Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        _showSnackBar('Could not save business information.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _businessNameController.dispose();

    _addressController.dispose();

    _phoneController.dispose();

    _emailController.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Business Information')),

      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: colors.primary))
          : ListView(
              padding: const EdgeInsets.all(20),

              children: [
                Container(
                  padding: const EdgeInsets.all(18),

                  decoration: BoxDecoration(
                    color: colors.primaryContainer,

                    borderRadius: BorderRadius.circular(18),
                  ),

                  child: Row(
                    children: [
                      Icon(
                        Icons.business_outlined,

                        color: colors.primary,

                        size: 30,
                      ),

                      const SizedBox(width: 14),

                      Expanded(
                        child: Text(
                          'This information is used throughout your business app.',

                          style: TextStyle(
                            color: colors.onPrimaryContainer,

                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                TextField(
                  controller: _businessNameController,

                  textInputAction: TextInputAction.next,

                  decoration: const InputDecoration(
                    labelText: 'Business name',

                    hintText: 'Enter your business name',

                    prefixIcon: Icon(Icons.business),
                  ),
                ),

                const SizedBox(height: 16),

                TextField(
                  controller: _addressController,

                  textInputAction: TextInputAction.next,

                  maxLines: 3,

                  decoration: const InputDecoration(
                    labelText: 'Address',

                    hintText: 'Enter business address',

                    prefixIcon: Icon(Icons.location_on_outlined),

                    alignLabelWithHint: true,
                  ),
                ),

                const SizedBox(height: 16),

                TextField(
                  controller: _phoneController,

                  keyboardType: TextInputType.phone,

                  textInputAction: TextInputAction.next,

                  decoration: const InputDecoration(
                    labelText: 'Phone',

                    hintText: 'Enter business phone',

                    prefixIcon: Icon(Icons.phone_outlined),
                  ),
                ),

                const SizedBox(height: 16),

                TextField(
                  controller: _emailController,

                  keyboardType: TextInputType.emailAddress,

                  decoration: const InputDecoration(
                    labelText: 'Email',

                    hintText: 'Enter business email',

                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                ),

                const SizedBox(height: 28),

                SizedBox(
                  height: 52,

                  child: FilledButton.icon(
                    onPressed: _isSaving ? null : _saveBusinessInformation,

                    icon: _isSaving
                        ? const SizedBox(
                            width: 19,

                            height: 19,

                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),

                    label: Text(_isSaving ? 'Saving...' : 'Save Changes'),
                  ),
                ),
              ],
            ),
    );
  }
}
