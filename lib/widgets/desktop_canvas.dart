import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Gives every Windows PC the same layout.
///
/// Windows display scaling and small screens leave an app with fewer units to
/// lay out in, which used to rearrange pages on some computers. Instead, pages
/// are laid out at [designWidth] and the whole picture is scaled to fit.
class DesktopCanvas extends StatelessWidget {
  const DesktopCanvas({super.key, required this.child});

  final Widget child;

  /// Wide enough for every page to take its full desktop arrangement.
  static const designWidth = 1536.0;

  /// Text is never drawn smaller than this share of its normal pixel size.
  static const smallest = .7;

  /// A window dragged narrower than this many pixels uses the phone layout.
  static const narrowPixels = 900.0;

  static double scaleFor(Size size, double pixelRatio) {
    if (size.width <= 0 || size.width >= designWidth) return 1;
    if (size.width * pixelRatio < narrowPixels) return 1;
    return math.min(1, math.max(size.width / designWidth, smallest / pixelRatio));
  }

  @override
  Widget build(BuildContext context) {
    final desktop =
        !kIsWeb &&
        switch (defaultTargetPlatform) {
          TargetPlatform.windows ||
          TargetPlatform.macOS ||
          TargetPlatform.linux => true,
          _ => false,
        };
    if (!desktop) return child;
    final media = MediaQuery.of(context);
    final scale = scaleFor(media.size, media.devicePixelRatio);
    final size = media.size / scale;
    // The same widgets are used at every scale, so resizing the window never
    // resets a page or a half-filled form.
    return FittedBox(
      fit: BoxFit.fill,
      alignment: Alignment.topLeft,
      child: SizedBox.fromSize(
        size: size,
        child: MediaQuery(
          data: media.copyWith(
            size: size,
            devicePixelRatio: media.devicePixelRatio * scale,
            padding: media.padding / scale,
            viewPadding: media.viewPadding / scale,
            viewInsets: media.viewInsets / scale,
          ),
          child: child,
        ),
      ),
    );
  }
}
