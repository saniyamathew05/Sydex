import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Whether the page that owns [context] was opened on top of another page.
///
/// Unlike `Navigator.canPop`, this stays false for a main tab even while some
/// other page happens to be open above it.
bool sydexCanGoBack(BuildContext context) =>
    ModalRoute.of(context)?.canPop ?? false;

/// Wraps the signed-in home so the back button never leaves the account.
///
/// On any other tab, back returns to the home tab. On the home tab it asks
/// first, because closing the app signs the user out.
class RootBackGuard extends StatefulWidget {
  const RootBackGuard({
    super.key,
    required this.atHome,
    required this.onGoHome,
    required this.child,
  });

  final bool Function() atHome;
  final VoidCallback onGoHome;
  final Widget child;

  @override
  State<RootBackGuard> createState() => _RootBackGuardState();
}

class _RootBackGuardState extends State<RootBackGuard> {
  bool _asking = false;

  Future<void> _onBack() async {
    if (!widget.atHome()) {
      widget.onGoHome();
      return;
    }
    if (_asking) return;
    _asking = true;
    final close = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Close Sydex?'),
        content: const Text('You will be signed out when the app closes.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Stay'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Close app'),
          ),
        ],
      ),
    );
    _asking = false;
    if (close == true) await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) => PopScope<Object?>(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _onBack();
    },
    child: widget.child,
  );
}
