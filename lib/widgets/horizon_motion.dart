import 'package:flutter/material.dart';

class HorizonMotion {
  static const quick = Duration(milliseconds: 110);
  static const standard = Duration(milliseconds: 180);
  static const navigation = Duration(milliseconds: 260);
  static const emphasis = Duration(milliseconds: 360);

  static const curve = Curves.easeOutCubic;
  static const emphasizedCurve = Curves.easeInOutCubic;
}

class HorizonFadeSlide extends StatelessWidget {
  const HorizonFadeSlide({
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
    duration: HorizonMotion.navigation + delay,
    curve: HorizonMotion.curve,
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

class HorizonPressable extends StatefulWidget {
  const HorizonPressable({
    super.key,
    required this.child,
    required this.onTap,
    this.borderRadius = BorderRadius.zero,
  });

  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius borderRadius;

  @override
  State<HorizonPressable> createState() => _HorizonPressableState();
}

class _HorizonPressableState extends State<HorizonPressable> {
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
      duration: HorizonMotion.quick,
      curve: HorizonMotion.curve,
      child: ClipRRect(borderRadius: widget.borderRadius, child: widget.child),
    ),
  );
}
