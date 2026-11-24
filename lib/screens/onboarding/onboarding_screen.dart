import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembers whether this device has seen the welcome tour.
class OnboardingStore {
  OnboardingStore._();

  static const _key = 'sydex_onboarding_seen_v1';
  static final ValueNotifier<bool> seen = ValueNotifier<bool>(true);

  static Future<void> load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      seen.value = preferences.getBool(_key) ?? false;
    } catch (_) {
      // Never block the app on a preferences failure.
      seen.value = true;
    }
  }

  static Future<void> markSeen() async {
    seen.value = true;
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(_key, true);
    } catch (_) {}
  }
}

class _Step {
  const _Step(this.tag, this.title, this.body);
  final String tag;
  final String title;
  final String body;
}

const _steps = <_Step>[
  _Step(
    '01 · Overview',
    'Your whole ledger in one place.',
    'Sales, payments, returns and balances update together, so every customer’s amount due is always right.',
  ),
  _Step(
    '02 · Collections',
    'Collect on the move.',
    'Cash, cheque, NEFT or GPay — even several in one payment. Capture a signature, share a receipt, or show your UPI QR.',
  ),
  _Step(
    '03 · Routes',
    'Routes, in order.',
    'Plan numbered stops, assign them to salesmen and queue the next route. It appears only after the current one is finished.',
  ),
  _Step(
    '04 · Insight',
    'Every rupee accounted for.',
    'Reports, a payment ledger split by method, a customer map and customer statements you can export in seconds.',
  ),
  _Step(
    '05 · Security',
    'Private by design.',
    'Each business sees only its own data, and Sydex signs out when it closes or sits idle for five minutes.',
  ),
];

/// Five-step welcome tour shown on first launch (and from Settings).
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.onFinished});

  final VoidCallback onFinished;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _step = 0;

  void _go(int step) => setState(() => _step = step.clamp(0, _steps.length - 1));

  Future<void> _finish() async {
    await OnboardingStore.markSeen();
    widget.onFinished();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final step = _steps[_step];
    final last = _step == _steps.length - 1;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: colors.onSurface,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Icon(
                          Icons.show_chart_rounded,
                          size: 18,
                          color: colors.surface,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text('Sydex', style: theme.textTheme.titleMedium),
                      const Spacer(),
                      OutlinedButton(
                        onPressed: _finish,
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 38),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                        ),
                        child: const Text('Skip'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  Row(
                    children: [
                      for (var i = 0; i < _steps.length; i++) ...[
                        if (i > 0) const SizedBox(width: 6),
                        Expanded(
                          child: Semantics(
                            button: true,
                            label: 'Go to step ${i + 1}',
                            child: GestureDetector(
                              onTap: () => _go(i),
                              child: Container(
                                height: 14,
                                alignment: Alignment.center,
                                color: Colors.transparent,
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(3),
                                  child: Stack(
                                    children: [
                                      Container(
                                        height: 3,
                                        color: colors.outlineVariant,
                                      ),
                                      AnimatedFractionallySizedBox(
                                        duration: reduced
                                            ? Duration.zero
                                            : const Duration(milliseconds: 450),
                                        curve: Curves.easeOutCubic,
                                        widthFactor: i <= _step ? 1 : 0,
                                        child: Container(
                                          height: 3,
                                          color: colors.onSurface,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: reduced
                          ? Duration.zero
                          : const Duration(milliseconds: 420),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(.04, 0),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      ),
                      child: Column(
                        key: ValueKey(_step),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SizedBox(height: 20),
                          Expanded(child: _Illustration(step: _step)),
                          const SizedBox(height: 20),
                          Text(
                            step.tag.toUpperCase(),
                            style: theme.textTheme.labelSmall,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            step.title,
                            style: theme.textTheme.displaySmall?.copyWith(
                              fontSize: 30,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            step.body,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 26),
                  Row(
                    children: [
                      if (_step > 0) ...[
                        SizedBox(
                          width: 52,
                          child: OutlinedButton(
                            onPressed: () => _go(_step - 1),
                            style: OutlinedButton.styleFrom(
                              padding: EdgeInsets.zero,
                            ),
                            child: const Icon(Icons.chevron_left, size: 22),
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        child: FilledButton(
                          onPressed: last ? _finish : () => _go(_step + 1),
                          child: Text(last ? 'Get started' : 'Continue'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small, flat illustrations made from the same cards used in the app.
class _Illustration extends StatelessWidget {
  const _Illustration({required this.step});
  final int step;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final child = switch (step) {
          0 => const _OverviewArt(),
          1 => const _CollectionsArt(),
          2 => const _RoutesArt(),
          3 => const _InsightArt(),
          _ => const _SecurityArt(),
        };
        return Align(
          alignment: Alignment.topCenter,
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            child: child,
          ),
        );
      },
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.dashed = false});
  final Widget child;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: dashed ? colors.surfaceContainerLow : colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: child,
    );
  }
}

class _Rise extends StatelessWidget {
  const _Rise({required this.child, this.delay = 0});
  final Widget child;
  final int delay;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 500 + delay),
      curve: Interval(delay / (500 + delay), 1, curve: Curves.easeOutCubic),
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 10 * (1 - value)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

TextStyle? _label(BuildContext context) =>
    Theme.of(context).textTheme.labelSmall?.copyWith(letterSpacing: .8);

TextStyle? _big(BuildContext context) => Theme.of(context)
    .textTheme
    .headlineSmall
    ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

class _OverviewArt extends StatelessWidget {
  const _OverviewArt();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const heights = [.40, .62, .48, .80, .66, .92, .58];
    return Column(
      children: [
        _Rise(
          child: _Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('TOTAL OUTSTANDING', style: _label(context)),
                const SizedBox(height: 4),
                Text('₹18,42,560', style: _big(context)),
                const SizedBox(height: 14),
                SizedBox(
                  height: 72,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var i = 0; i < heights.length; i++) ...[
                        if (i > 0) const SizedBox(width: 8),
                        Expanded(
                          child: TweenAnimationBuilder<double>(
                            tween: Tween(begin: 0, end: heights[i]),
                            duration: Duration(milliseconds: 600 + i * 70),
                            curve: Curves.easeOutCubic,
                            builder: (context, value, _) =>
                                FractionallySizedBox(
                                  heightFactor: value,
                                  alignment: Alignment.bottomCenter,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: i == 5
                                          ? colors.onSurface
                                          : colors.outlineVariant,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
                                ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _Rise(
                delay: 120,
                child: _Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('COLLECTED TODAY', style: _label(context)),
                      const SizedBox(height: 4),
                      Text('₹1,24,300', style: _big(context)?.copyWith(fontSize: 19)),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _Rise(
                delay: 200,
                child: _Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('CUSTOMERS', style: _label(context)),
                      const SizedBox(height: 4),
                      Text('506', style: _big(context)?.copyWith(fontSize: 19)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.left, this.right, {this.trailing});
  final String left;
  final String right;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: Row(
        children: trailing != null
            ? [trailing!]
            : [
                Expanded(child: Text(left)),
                Text(
                  right,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, this.background, this.foreground);
  final String text;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: foreground,
        fontSize: 11,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _CollectionsArt extends StatelessWidget {
  const _CollectionsArt();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        _Rise(
          child: _Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('RECEIVE PAYMENT', style: _label(context)),
                const SizedBox(height: 4),
                Text('₹44,034', style: _big(context)),
                const SizedBox(height: 6),
                const _Line('Cash', '₹24,500'),
                const _Line('Cheque', '₹19,534'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _Rise(
          delay: 160,
          child: _Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('CUSTOMER SIGNATURE', style: _label(context)),
                const SizedBox(height: 6),
                SizedBox(
                  height: 56,
                  width: double.infinity,
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: const Duration(milliseconds: 1800),
                    curve: Curves.easeInOut,
                    builder: (context, value, _) => CustomPaint(
                      painter: _SignaturePainter(value, colors.onSurface),
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
}

class _SignaturePainter extends CustomPainter {
  _SignaturePainter(this.progress, this.color);
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()..moveTo(w * .02, h * .75);
    path.cubicTo(w * .1, h * .05, w * .16, h * .05, w * .18, h * .6);
    path.cubicTo(w * .22, h * .95, w * .3, h * .2, w * .36, h * .45);
    path.cubicTo(w * .42, h * .7, w * .46, h * .1, w * .55, h * .4);
    path.cubicTo(w * .63, h * .7, w * .7, h * .15, w * .8, h * .45);
    path.cubicTo(w * .88, h * .7, w * .92, h * .3, w * .98, h * .35);
    final metric = path.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * progress),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_SignaturePainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}

class _RoutesArt extends StatelessWidget {
  const _RoutesArt();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget stop(int n, String name, bool visited) => _Line(
      '',
      '',
      trailing: Expanded(
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Text(
                '$n.',
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: colors.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(name)),
            visited
                ? _Badge('Visited', colors.secondaryContainer, colors.onSecondaryContainer)
                : _Badge('Pending', colors.tertiaryContainer, colors.onTertiaryContainer),
          ],
        ),
      ),
    );
    return Column(
      children: [
        _Rise(
          child: _Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('TODAY · PUNALUR23', style: _label(context)),
                const SizedBox(height: 4),
                stop(1, 'Amba Stores', true),
                stop(2, 'Plywood Emporium', true),
                stop(3, 'Sree Traders', false),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _Rise(
          delay: 160,
          child: _Panel(
            dashed: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('NEXT IN QUEUE', style: _label(context)),
                const SizedBox(height: 6),
                const Text(
                  'ALAPPUZHA20 · 53 stops',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  'Opens after “Finish route”',
                  style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _InsightArt extends StatelessWidget {
  const _InsightArt();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        _Rise(
          child: _Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('THIS MONTH · BY METHOD', style: _label(context)),
                const SizedBox(height: 4),
                Text('₹9,60,000', style: _big(context)),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: SizedBox(
                    height: 8,
                    child: Row(
                      children: [
                        Expanded(flex: 62, child: Container(color: colors.onSurface)),
                        const SizedBox(width: 3),
                        Expanded(flex: 22, child: Container(color: colors.onSurfaceVariant)),
                        const SizedBox(width: 3),
                        Expanded(flex: 16, child: Container(color: colors.outline)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Cash 62%   ·   Cheque 22%   ·   Online 16%',
                  style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _Rise(
                delay: 140,
                child: _Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('VISIT AUDIT', style: _label(context)),
                      const SizedBox(height: 6),
                      const Text('42 GPS-checked visits'),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _Rise(
                delay: 220,
                child: _Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('STATEMENT', style: _label(context)),
                      const SizedBox(height: 6),
                      const Text('PDF ready to share'),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SecurityArt extends StatelessWidget {
  const _SecurityArt();

  @override
  Widget build(BuildContext context) {
    const items = [
      (Icons.shield_outlined, 'Private workspace per business'),
      (Icons.people_outline, 'Owner and salesman roles'),
      (Icons.timer_outlined, 'Signs out after 5 idle minutes'),
      (Icons.lock_outline, 'Signs out when the app closes'),
    ];
    return _Rise(
      child: _Panel(
        child: Column(
          children: [
            for (final (icon, text) in items)
              _Line(
                '',
                '',
                trailing: Expanded(
                  child: Row(
                    children: [
                      Icon(icon, size: 19),
                      const SizedBox(width: 12),
                      Expanded(child: Text(text)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
