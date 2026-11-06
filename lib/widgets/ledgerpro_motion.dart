import 'package:flutter/material.dart';

class LedgerProMotion {
  static const quick = Duration(milliseconds: 110);
  static const standard = Duration(milliseconds: 180);
  static const navigation = Duration(milliseconds: 260);
  static const emphasis = Duration(milliseconds: 360);

  static const curve = Curves.easeOutCubic;
  static const emphasizedCurve = Curves.easeInOutCubic;
}

class LedgerProFadeSlide extends StatelessWidget {
  const LedgerProFadeSlide({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.offset = const Offset(0, .025),
  });

  final Widget child;
  final Duration delay;
  final Offset offset;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: LedgerProMotion.navigation + delay,
    curve: LedgerProMotion.curve,
    builder: (context, value, child) => Opacity(
      opacity: value,
      child: Transform.translate(
        offset: Offset(
          offset.dx * (1 - value) * 120,
          offset.dy * (1 - value) * 120,
        ),
        child: child,
      ),
    ),
    child: child,
  );
}

class LedgerProPressable extends StatefulWidget {
  const LedgerProPressable({
    super.key,
    required this.child,
    required this.onTap,
    this.borderRadius = BorderRadius.zero,
  });

  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius borderRadius;

  @override
  State<LedgerProPressable> createState() => _LedgerProPressableState();
}

class _LedgerProPressableState extends State<LedgerProPressable> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) => GestureDetector(
    // Some pressable controls deliberately ignore their visual child so that
    // this wrapper owns the interaction. Opaque hit testing keeps the entire
    // control tappable in that case.
    behavior: HitTestBehavior.opaque,
    onTapDown: widget.onTap == null
        ? null
        : (_) => setState(() => _pressed = true),
    onTapCancel: widget.onTap == null
        ? null
        : () => setState(() => _pressed = false),
    onTapUp: widget.onTap == null
        ? null
        : (_) {
            setState(() => _pressed = false);
            widget.onTap?.call();
          },
    child: AnimatedScale(
      scale: _pressed ? .985 : 1,
      duration: LedgerProMotion.quick,
      curve: LedgerProMotion.curve,
      child: ClipRRect(borderRadius: widget.borderRadius, child: widget.child),
    ),
  );
}
