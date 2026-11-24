import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The signed-in person's own look and preferences, kept on this device and
/// separately for each account.
class ProfileStore {
  ProfileStore._();

  /// 'Default' follows the theme.
  static const avatarColors = <String, Color?>{
    'Default': null,
    'Graphite': Color(0xFF3D4148),
    'Ocean': Color(0xFF1D4E89),
    'Plum': Color(0xFF5B3A64),
    'Brick': Color(0xFF8A3B2E),
    'Amber': Color(0xFF8A5300),
  };

  static const textSizes = <String, double>{
    'Small': .92,
    'Default': 1,
    'Large': 1.15,
  };

  static const ownerStartPages = ['Home', 'Customers', 'Payments', 'Routes'];
  static const salesmanStartPages = ['Today', 'Route', 'Payments', 'Map'];

  static const _photoSize = 256;
  static const _legacyPhotoPath = 'sydex_profile_image_path';

  static final name = ValueNotifier<String?>(null);
  static final photo = ValueNotifier<Uint8List?>(null);
  static final avatarColor = ValueNotifier<String>('Default');
  static final startPage = ValueNotifier<int>(0);

  /// Device-wide, so it also applies before signing in.
  static final textSize = ValueNotifier<String>('Default');

  static final Listenable changes = Listenable.merge([
    name,
    photo,
    avatarColor,
  ]);

  static String? _userId;

  static String _key(String what) => 'sydex_profile.$_userId.$what';

  static Future<void> loadDevice() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('sydex_text_size');
    textSize.value = textSizes.containsKey(saved) ? saved! : 'Default';
  }

  static double get textScale => textSizes[textSize.value] ?? 1;

  static Future<void> setTextSize(String value) async {
    textSize.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sydex_text_size', value);
  }

  /// Loads the choices of the account that just signed in, so one person's
  /// photo never shows on another person's account.
  static Future<void> loadUser() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;
    if (userId != _userId) {
      _userId = userId;
      name.value = null;
      photo.value = null;
      avatarColor.value = 'Default';
      startPage.value = 0;
    }
    final prefs = await SharedPreferences.getInstance();
    if (userId != _userId) return;
    avatarColor.value = prefs.getString(_key('avatar_color')) ?? 'Default';
    startPage.value = prefs.getInt(_key('start_page')) ?? 0;
    final encoded = prefs.getString(_key('photo'));
    if (encoded != null) {
      try {
        photo.value = base64Decode(encoded);
      } catch (_) {
        await prefs.remove(_key('photo'));
      }
    } else if (!kIsWeb) {
      await _adoptLegacyPhoto(prefs);
    }
    try {
      final row = await Supabase.instance.client
          .from('profiles')
          .select('name')
          .eq('id', userId)
          .maybeSingle();
      final saved = row?['name']?.toString().trim() ?? '';
      if (saved.isNotEmpty && userId == _userId) name.value = saved;
    } catch (error) {
      debugPrint('Could not load the profile name: $error');
    }
  }

  // Earlier versions stored only a file path, shared by every account.
  static Future<void> _adoptLegacyPhoto(SharedPreferences prefs) async {
    final path = prefs.getString(_legacyPhotoPath);
    if (path == null) return;
    try {
      await setPhoto(await File(path).readAsBytes());
    } catch (_) {
      // The original picture has been moved or deleted.
    }
    await prefs.remove(_legacyPhotoPath);
  }

  /// Saves a small square copy of the picture. Throws if it is not an image.
  static Future<void> setPhoto(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final source = (await codec.getNextFrame()).image;
    final side = source.width < source.height ? source.width : source.height;
    final recorder = ui.PictureRecorder();
    final target = Rect.fromLTWH(
      0,
      0,
      _photoSize.toDouble(),
      _photoSize.toDouble(),
    );
    final canvas = Canvas(recorder);
    // A see-through picture would otherwise turn black.
    canvas.drawRect(target, Paint()..color = Colors.white);
    canvas.drawImageRect(
      source,
      Rect.fromLTWH(
        (source.width - side) / 2,
        (source.height - side) / 2,
        side.toDouble(),
        side.toDouble(),
      ),
      target,
      Paint()..filterQuality = FilterQuality.high,
    );
    final square = await recorder.endRecording().toImage(
      _photoSize,
      _photoSize,
    );
    final data = await square.toByteData(format: ui.ImageByteFormat.png);
    source.dispose();
    square.dispose();
    codec.dispose();
    if (data == null) throw const FormatException('Not an image');
    final png = data.buffer.asUint8List();
    photo.value = png;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key('photo'), base64Encode(png));
  }

  static Future<void> removePhoto() async {
    photo.value = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key('photo'));
  }

  static Future<void> setAvatarColor(String value) async {
    avatarColor.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key('avatar_color'), value);
  }

  static Future<void> setStartPage(int value) async {
    startPage.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_key('start_page'), value);
  }

  static Future<void> setName(String value) async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) throw Exception('You are not signed in.');
    await Supabase.instance.client
        .from('profiles')
        .update({'name': value})
        .eq('id', userId);
    name.value = value;
  }
}
