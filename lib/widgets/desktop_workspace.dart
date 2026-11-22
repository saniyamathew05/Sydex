import 'package:flutter/material.dart';

/// A destination can open a retained workspace page or a focused action.
class WorkspaceDestination {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool selected;
  final bool secondary;

  const WorkspaceDestination({
    required this.label,
    required this.icon,
    required this.onTap,
    this.selected = false,
    this.secondary = false,
  });
}

/// Layout-shaped loading feedback avoids presenting temporary zero balances.
class WorkspaceLoadingView extends StatelessWidget {
  const WorkspaceLoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget block(double height, {double? width}) => Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
    );
    return Semantics(
      label: 'Loading business overview',
      child: ExcludeSemantics(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (!MediaQuery.disableAnimationsOf(context))
              const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: 28),
            Align(
              alignment: Alignment.centerLeft,
              child: block(26, width: 220),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: block(14, width: 160),
            ),
            const SizedBox(height: 28),
            LayoutBuilder(
              builder: (context, constraints) => Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  for (var i = 0; i < 3; i++)
                    SizedBox(
                      width: constraints.maxWidth < 600
                          ? constraints.maxWidth
                          : (constraints.maxWidth - 32) / 3,
                      child: block(120),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            block(220),
            const SizedBox(height: 24),
            for (var i = 0; i < 5; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: block(44),
              ),
          ],
        ),
      ),
    );
  }
}

class DesktopWorkspaceSidebar extends StatefulWidget {
  final String userName;
  final String role;
  final List<WorkspaceDestination> destinations;
  final VoidCallback onProfile;
  final Widget? action;

  const DesktopWorkspaceSidebar({
    super.key,
    required this.userName,
    required this.role,
    required this.destinations,
    required this.onProfile,
    this.action,
  });

  @override
  State<DesktopWorkspaceSidebar> createState() =>
      _DesktopWorkspaceSidebarState();
}

class _DesktopWorkspaceSidebarState extends State<DesktopWorkspaceSidebar> {
  bool _collapsed = false;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final scheme = Theme.of(context).colorScheme;
    final foreground = scheme.onSurface;
    final mutedText = scheme.onSurfaceVariant;
    final tile = scheme.surfaceContainer;
    return AnimatedContainer(
      duration: reduced ? Duration.zero : const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      width: _collapsed ? 80 : 244,
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(right: BorderSide(color: scheme.outlineVariant)),
      ),
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: _collapsed ? 80 : 244,
          maxWidth: _collapsed ? 80 : 244,
          child: Theme(
            data: Theme.of(context).copyWith(
              iconTheme: IconThemeData(color: foreground),
              focusColor: foreground.withValues(alpha: .08),
              hoverColor: foreground.withValues(alpha: .04),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 24, 16, 20),
                      child: Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            padding: const EdgeInsets.all(7),
                            decoration: BoxDecoration(
                              color: tile,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Image.asset(
                              'assets/sydex_logo_transparent.png',
                            ),
                          ),
                          if (!_collapsed) ...[
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Sydex',
                                    style: TextStyle(
                                      color: foreground,
                                      fontSize: 19,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: -.5,
                                    ),
                                  ),
                                  Text(
                                    'BUSINESS WORKSPACE',
                                    style: TextStyle(
                                      color: mutedText,
                                      fontSize: 9,
                                      letterSpacing: 1.3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (widget.action != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: widget.action!,
                      ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        children: [
                          for (final destination in widget.destinations)
                            Padding(
                              padding: EdgeInsets.only(
                                top: destination.secondary ? 12 : 3,
                                bottom: 3,
                              ),
                              child: Tooltip(
                                message: destination.label,
                                child: AnimatedContainer(
                                  duration: reduced
                                      ? Duration.zero
                                      : const Duration(milliseconds: 140),
                                  decoration: BoxDecoration(
                                    color: destination.selected
                                        ? tile
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      onTap: destination.onTap,
                                      borderRadius: BorderRadius.circular(10),
                                      child: SizedBox(
                                        height: 44,
                                        child: Row(
                                          children: [
                                            const SizedBox(width: 15),
                                            Icon(
                                              destination.icon,
                                              size: 20,
                                              color: destination.selected
                                                  ? foreground
                                                  : mutedText,
                                            ),
                                            if (!_collapsed) ...[
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Text(
                                                  destination.label,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    color: destination.selected
                                                        ? foreground
                                                        : mutedText,
                                                    fontSize: 13,
                                                    fontWeight:
                                                        destination.selected
                                                        ? FontWeight.w600
                                                        : FontWeight.w400,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Divider(
                      color: scheme.outlineVariant,
                      indent: 16,
                      endIndent: 16,
                    ),
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 19,
                      ),
                      onTap: widget.onProfile,
                      leading: CircleAvatar(
                        radius: 18,
                        backgroundColor: tile,
                        child: Text(
                          widget.userName.isEmpty
                              ? 'S'
                              : widget.userName[0].toUpperCase(),
                          style: TextStyle(color: foreground),
                        ),
                      ),
                      title: _collapsed
                          ? null
                          : Text(
                              widget.userName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: foreground,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                      subtitle: _collapsed
                          ? null
                          : Text(
                              widget.role,
                              style: TextStyle(
                                color: mutedText,
                                fontSize: 11,
                              ),
                            ),
                    ),
                    Align(
                      alignment: _collapsed
                          ? Alignment.center
                          : Alignment.centerRight,
                      child: IconButton(
                        tooltip: _collapsed
                            ? 'Expand navigation'
                            : 'Collapse navigation',
                        onPressed: () =>
                            setState(() => _collapsed = !_collapsed),
                        icon: Icon(
                          _collapsed
                              ? Icons.keyboard_double_arrow_right
                              : Icons.keyboard_double_arrow_left,
                          color: mutedText,
                          size: 19,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Animate the retained page as a whole, without mounting inactive pages or
/// discarding searches, scroll positions, or forms when switching destinations.
class WorkspacePageTransition extends StatefulWidget {
  final Object identity;
  final Widget child;
  const WorkspacePageTransition({
    super.key,
    required this.identity,
    required this.child,
  });

  @override
  State<WorkspacePageTransition> createState() =>
      _WorkspacePageTransitionState();
}

class _WorkspacePageTransitionState extends State<WorkspacePageTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(WorkspacePageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity &&
        !MediaQuery.disableAnimationsOf(context)) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    return FadeTransition(
      opacity: _curve,
      child: AnimatedBuilder(
        animation: _curve,
        child: widget.child,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, 8 * (1 - _curve.value)),
          child: child,
        ),
      ),
    );
  }
}
