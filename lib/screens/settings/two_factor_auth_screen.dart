import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr/qr.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Authenticator-app TOTP management. Secrets are held only while setup is open.
class TwoFactorAuthScreen extends StatefulWidget {
  const TwoFactorAuthScreen({super.key});

  @override
  State<TwoFactorAuthScreen> createState() => _TwoFactorAuthScreenState();
}

class _TwoFactorAuthScreenState extends State<TwoFactorAuthScreen> {
  final _code = TextEditingController();
  bool _loading = true;
  bool _working = false;
  String? _error;
  List<Factor> _factors = const [];
  String? _pendingFactorId;
  String? _pendingUri;
  String? _pendingSecret;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final factors = await Supabase.instance.client.auth.mfa.listFactors();
      if (mounted) {
        setState(() {
          _factors = factors.totp;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not load two-factor authentication.';
          _loading = false;
        });
      }
    }
  }

  Future<void> _startSetup() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final enrollment = await Supabase.instance.client.auth.mfa.enroll(
        factorType: FactorType.totp,
        issuer: 'Sydex',
        friendlyName: 'Authenticator app',
      );
      if (!mounted) return;
      setState(() {
        _pendingFactorId = enrollment.id;
        _pendingUri = enrollment.totp?.uri;
        _pendingSecret = enrollment.totp?.secret;
      });
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not start setup. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _verify() async {
    final factorId = _pendingFactorId;
    final code = _code.text.replaceAll(RegExp(r'\s+'), '');
    if (factorId == null || code.length != 6) {
      setState(
        () => _error = 'Enter the 6-digit code from your authenticator app.',
      );
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.auth.mfa.challengeAndVerify(
        factorId: factorId,
        code: code,
      );
      if (!mounted) return;
      setState(() {
        _pendingFactorId = null;
        _pendingUri = null;
        _pendingSecret = null;
        _code.clear();
      });
      await _load();
    } on AuthException catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'That code could not be verified. Check the code and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Two-factor authentication')),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                'Protect your account',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Use an authenticator app to generate a time-based verification code when you sign in.',
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 24),
              if (_pendingFactorId == null) ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    _factors.isEmpty
                        ? Icons.shield_outlined
                        : Icons.verified_user_outlined,
                  ),
                  title: Text(
                    _factors.isEmpty
                        ? 'Two-factor authentication is off'
                        : 'Authenticator app is active',
                  ),
                  subtitle: Text(
                    _factors.isEmpty
                        ? 'Add an authenticator app for stronger sign-in security.'
                        : '${_factors.length} authenticator app${_factors.length == 1 ? '' : 's'} enrolled.',
                  ),
                ),
                FilledButton.icon(
                  onPressed: _working ? null : _startSetup,
                  icon: const Icon(Icons.add_moderator_outlined),
                  label: const Text('Set up authenticator app'),
                ),
              ] else ...[
                const Text('1. Scan this QR code with your authenticator app.'),
                const SizedBox(height: 16),
                Center(
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(16),
                    child: CustomPaint(
                      size: const Size.square(220),
                      painter: _TotpQrPainter(_pendingUri!),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                TextButton.icon(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: _pendingSecret!)),
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('Copy setup key instead'),
                ),
                const SizedBox(height: 12),
                const Text('2. Enter the 6-digit code generated by the app.'),
                const SizedBox(height: 8),
                TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Authenticator code',
                    border: OutlineInputBorder(),
                  ),
                ),
                FilledButton(
                  onPressed: _working ? null : _verify,
                  child: const Text('Verify and enable'),
                ),
              ],
            ],
          ),
  );
}

class _TotpQrPainter extends CustomPainter {
  const _TotpQrPainter(this.data);
  final String data;
  @override
  void paint(Canvas canvas, Size size) {
    final image = QrImage(
      QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M),
    );
    final cell = size.shortestSide / image.moduleCount;
    final paint = Paint()..color = Colors.black;
    for (var row = 0; row < image.moduleCount; row++) {
      for (var col = 0; col < image.moduleCount; col++) {
        if (image.isDark(row, col)) {
          canvas.drawRect(
            Rect.fromLTWH(col * cell, row * cell, cell + .2, cell + .2),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_TotpQrPainter old) => old.data != data;
}
