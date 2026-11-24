import 'package:flutter/material.dart';

import '../services/profile_store.dart';
import '../services/theme_controller.dart';
import 'sydex_ui.dart';

/// The signed-in person's photo, or their initials on the colour they chose.
class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar(this.fallbackName, {super.key, this.size = 40});

  final String fallbackName;
  final double size;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ProfileStore.changes,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      final photo = ProfileStore.photo.value;
      final picked = ProfileStore.avatarColors[ProfileStore.avatarColor.value];
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: picked ?? colors.surfaceContainerHigh,
          shape: BoxShape.circle,
          border: Border.all(color: colors.outlineVariant),
        ),
        child: photo != null
            ? Image.memory(
                photo,
                width: size,
                height: size,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              )
            : Text(
                SydexAvatar.initials(ProfileStore.name.value ?? fallbackName),
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  fontSize: size * .34,
                  fontWeight: FontWeight.w600,
                  color: picked != null ? Colors.white : colors.onSurface,
                ),
              ),
      );
    },
  );
}

/// Switches between light and dark for the whole app.
class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SydexIconButton(
      icon: dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
      tooltip: dark ? 'Switch to light mode' : 'Switch to dark mode',
      onPressed: () => ThemeController.setThemeMode(
        dark ? ThemeMode.light : ThemeMode.dark,
      ),
    );
  }
}
