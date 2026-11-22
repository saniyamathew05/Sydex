import 'package:flutter/material.dart';

import '../theme/sydex_theme.dart';

/// Shared building blocks for the Sydex minimal layout.
///
/// These are presentation-only widgets: they never call services, so screens
/// keep their existing data loading and actions unchanged.

/// Lays [child] out at its natural height, scaling it down (never clipping or
/// overflowing) when a grid cell is shorter than the content.
class _FitHeight extends StatelessWidget {
  const _FitHeight({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (!constraints.hasBoundedHeight || !constraints.hasBoundedWidth) {
        return child;
      }
      return FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.topLeft,
        child: SizedBox(width: constraints.maxWidth, child: child),
      );
    },
  );
}

/// Small uppercase label used above values and sections.
class SydexEyebrow extends StatelessWidget {
  const SydexEyebrow(this.text, {super.key, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w500,
      letterSpacing: .8,
      color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}

/// Page header: optional leading widget, eyebrow + title, trailing actions.
class SydexScreenHeader extends StatelessWidget {
  const SydexScreenHeader({
    super.key,
    required this.title,
    this.eyebrow,
    this.leading,
    this.actions = const [],
    this.large = true,
  });

  final String title;
  final String? eyebrow;
  final Widget? leading;
  final List<Widget> actions;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: 12)],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (eyebrow != null) ...[
                SydexEyebrow(eyebrow!),
                const SizedBox(height: 3),
              ],
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: large ? 26 : 17,
                  fontWeight: FontWeight.w600,
                  letterSpacing: large ? -.8 : -.3,
                  color: colors.onSurface,
                  height: 1.15,
                ),
              ),
            ],
          ),
        ),
        for (final action in actions) ...[const SizedBox(width: 8), action],
      ],
    );
  }
}

/// Square outlined icon button used in headers.
class SydexIconButton extends StatelessWidget {
  const SydexIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.badgeCount = 0,
    this.filled = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final int badgeCount;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final background = filled ? SydexColors.hero(context) : colors.surface;
    final foreground = filled ? Colors.white : colors.onSurface;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Tooltip(
          message: tooltip,
          child: Material(
            color: background,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: filled
                  ? BorderSide.none
                  : BorderSide(color: colors.outlineVariant),
            ),
            child: InkWell(
              onTap: onPressed,
              customBorder: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: SizedBox(
                width: 44,
                height: 44,
                child: Icon(icon, size: 20, color: foreground),
              ),
            ),
          ),
        ),
        if (badgeCount > 0)
          Positioned(
            right: 4,
            top: 4,
            child: Container(
              constraints: const BoxConstraints(minWidth: 16),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: colors.error,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                badgeCount > 99 ? '99+' : '$badgeCount',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.onError,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// White card with a hairline border.
class SydexCard extends StatelessWidget {
  const SydexCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: BorderSide(color: colors.outlineVariant),
    );
    return Material(
      color: color ?? colors.surface,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Card with a title row and optional trailing link.
class SydexSection extends StatelessWidget {
  const SydexSection({
    super.key,
    required this.title,
    required this.child,
    this.actionLabel,
    this.onAction,
    this.subtitle,
    this.padding = const EdgeInsets.fromLTRB(16, 14, 16, 14),
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final String? actionLabel;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SydexCard(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurface,
                      ),
                    ),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (actionLabel != null)
                TextButton(
                  onPressed: onAction,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(44, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    textStyle: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  child: Text(actionLabel!),
                ),
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// Dark summary card (the "hero") with white text.
class SydexHeroCard extends StatelessWidget {
  const SydexHeroCard({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: SydexColors.hero(context),
      borderRadius: BorderRadius.circular(20),
    ),
    child: DefaultTextStyle.merge(
      style: const TextStyle(color: Colors.white),
      child: IconTheme.merge(
        data: const IconThemeData(color: Colors.white),
        child: child,
      ),
    ),
  );
}

/// Outlined box used inside the hero for sub-totals.
class SydexHeroTile extends StatelessWidget {
  const SydexHeroTile({super.key, required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.white.withValues(alpha: .14)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            color: Colors.white.withValues(alpha: .62),
          ),
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.white,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    ),
  );
}

/// Simple animated bar chart for the hero card (values 0..1).
class SydexMiniBars extends StatelessWidget {
  const SydexMiniBars({
    super.key,
    required this.values,
    this.height = 72,
    this.highlightLast = true,
    this.onDark = true,
  });

  final List<double> values;
  final double height;
  final bool highlightLast;
  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final strong = onDark ? Colors.white : colors.onSurface;
    final weak = onDark
        ? Colors.white.withValues(alpha: .22)
        : colors.outlineVariant;
    final reduced = MediaQuery.disableAnimationsOf(context);
    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < values.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: values[i].clamp(.04, 1)),
                duration: reduced
                    ? Duration.zero
                    : Duration(milliseconds: 500 + i * 50),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) => FractionallySizedBox(
                  heightFactor: value,
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    decoration: BoxDecoration(
                      color: highlightLast && i == values.length - 1
                          ? strong
                          : (highlightLast ? weak : strong),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// White stat tile: small icon, label and value.
class SydexStatTile extends StatelessWidget {
  const SydexStatTile({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.footnote,
    this.onTap,
  });

  final String label;
  final String value;
  final IconData? icon;
  final String? footnote;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SydexCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: _FitHeight(
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: colors.surfaceContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 17, color: colors.onSurface),
            ),
            const SizedBox(height: 12),
          ],
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w600,
                letterSpacing: -.4,
                color: colors.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          if (footnote != null) ...[
            const SizedBox(height: 2),
            Text(
              footnote!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
            ),
          ],
        ],
        ),
      ),
    );
  }
}

/// Icon tile with a label underneath (quick actions grid).
class SydexQuickAction extends StatelessWidget {
  const SydexQuickAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _FitHeight(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: colors.surfaceContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, size: 22, color: colors.onSurface),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: colors.onSurface,
                  height: 1.2,
                ),
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }
}

/// Horizontal row of single-select pills.
class SydexChoiceChips extends StatelessWidget {
  const SydexChoiceChips({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
  });

  final List<String> options;
  final String selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: options.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final option = options[index];
          final on = option == selected;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              color: on ? colors.onSurface : colors.surface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: on ? colors.onSurface : colors.outlineVariant,
              ),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () => onSelected(option),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Center(
                  child: Text(
                    option,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: on ? colors.surface : colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

enum SydexTone { neutral, positive, pending, negative, info }

/// Small rounded status label.
class SydexBadge extends StatelessWidget {
  const SydexBadge(this.text, {super.key, this.tone = SydexTone.neutral});
  final String text;
  final SydexTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (bg, fg) = switch (tone) {
      SydexTone.positive => (
        colors.secondaryContainer,
        colors.onSecondaryContainer,
      ),
      SydexTone.pending => (
        colors.tertiaryContainer,
        colors.onTertiaryContainer,
      ),
      SydexTone.negative => (colors.errorContainer, colors.onErrorContainer),
      SydexTone.info => (colors.surfaceContainerHigh, colors.onSurface),
      SydexTone.neutral => (colors.surfaceContainer, colors.onSurface),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        maxLines: 1,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }
}

/// Initials in a neutral rounded square.
class SydexAvatar extends StatelessWidget {
  const SydexAvatar(this.name, {super.key, this.size = 40});
  final String name;
  final double size;

  static String initials(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .take(2)
        .map((part) => part[0].toUpperCase())
        .join();
    return parts.isEmpty ? '?' : parts;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(size * .3),
      ),
      child: Text(
        initials(name),
        style: TextStyle(
          fontSize: size * .32,
          fontWeight: FontWeight.w600,
          color: colors.onSurface,
        ),
      ),
    );
  }
}

/// Fades and lifts its child in when first shown.
class SydexReveal extends StatelessWidget {
  const SydexReveal({super.key, required this.child, this.index = 0});
  final Widget child;
  final int index;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final delay = (index * 40).clamp(0, 320);
    final total = 420 + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      curve: Interval(delay / total, 1, curve: Curves.easeOutCubic),
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - value)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}
