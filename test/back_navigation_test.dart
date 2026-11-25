// These packages are only needed here to fake the backend and location.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sydex/main.dart';
import 'package:sydex/screens/owner/owner_main_screen.dart';
import 'package:sydex/screens/salesman/salesman_home.dart';
import 'package:sydex/services/session_policy.dart';
import 'package:sydex/theme/sydex_theme.dart';
import 'package:sydex/theme/workspace_theme.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const _uid = '00000000-0000-4000-8000-000000000001';
String _role = 'owner';

/// A live-updates connection that never opens, so no test uses the network.
class _OfflineSocket extends Fake implements WebSocketChannel {
  @override
  Future<void> get ready => Completer<void>().future;

  @override
  Stream<dynamic> get stream => const Stream<dynamic>.empty();

  @override
  WebSocketSink get sink => _OfflineSink();

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;
}

class _OfflineSink extends Fake implements WebSocketSink {
  @override
  void add(Object? data) {}

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}
}

/// Location is off, so no test depends on the computer's location service.
class _NoLocation extends GeolocatorPlatform {
  @override
  Future<bool> isLocationServiceEnabled() async => false;
}

Future<http.Response> _backend(http.Request request) async {
  http.Response reply(Object? body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
    request: request,
  );
  String part(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  final path = request.url.path;
  if (path.endsWith('/token')) {
    final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 360000;
    return reply({
      'access_token':
          '${part({'alg': 'HS256', 'typ': 'JWT'})}.'
          '${part({'sub': _uid, 'exp': exp, 'role': 'authenticated'})}.x',
      'token_type': 'bearer',
      'refresh_token': 'r',
      'expires_in': 360000,
      'expires_at': exp,
      'user': {
        'id': _uid,
        'aud': 'authenticated',
        'role': 'authenticated',
        'email': 'person@example.test',
        'app_metadata': <String, Object>{},
        'user_metadata': <String, Object>{},
        'created_at': DateTime.now().toIso8601String(),
      },
    });
  }
  if (path.endsWith('/profiles')) {
    final row = {
      'id': _uid,
      'name': 'Test Person',
      'role': _role,
      'company_id': 'c',
      'is_active': true,
    };
    final accept = request.headers['Accept'] ?? request.headers['accept'] ?? '';
    return reply(accept.contains('pgrst.object') ? row : [row]);
  }
  return reply(<Object>[]);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 8)),
    );
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// Waits for something that depends on the (fake) backend, however slow the
/// computer is. A fixed wait failed now and then on GitHub's machines.
Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 400 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsOneWidget);
  await _settle(tester);
}

/// Signs in through the real Welcome and Login screens.
Future<void> _signIn(WidgetTester tester, String role, Type home) async {
  _role = role;
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: workspaceTheme(
        buildSydexTheme(Brightness.light, SydexColors.ink),
      ),
      home: const WelcomeScreen(),
    ),
  );
  await _settle(tester);
  await tester.tap(find.text('Sign in'));
  await _settle(tester);
  await tester.enterText(find.byType(TextField).at(0), 'person@example.test');
  await tester.enterText(find.byType(TextField).at(1), 'test-password');
  final button = find.widgetWithText(FilledButton, 'Sign In');
  await tester.ensureVisible(button);
  await tester.tap(button);
  await _waitFor(tester, find.byType(home));
  if (home == SalesmanHome) {
    await _waitFor(tester, find.byType(IndexedStack));
  }
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 70));
}

void main() {
  late List<MethodCall> platformCalls;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://127.0.0.1:9',
      publishableKey: 'test-only-placeholder',
      httpClient: MockClient(_backend),
      realtimeClientOptions: RealtimeClientOptions(
        transport: (_, _) => _OfflineSocket(),
      ),
    );
  });

  setUp(() {
    GeolocatorPlatform.instance = _NoLocation();
    platformCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          platformCalls.add(call);
          return null;
        });
  });

  bool closedTheApp() =>
      platformCalls.any((call) => call.method == 'SystemNavigator.pop');

  for (final (role, screen, tabs) in [
    ('owner', OwnerMainScreen, ['Customers', 'Payments', 'Routes', 'More']),
    ('salesman', SalesmanHome, ['Route', 'Payments', 'Map']),
  ]) {
    testWidgets('$role: back never returns to the sign-in pages', (
      tester,
    ) async {
      await _signIn(tester, role, screen);
      expect(find.byType(WelcomeScreen, skipOffstage: false), findsNothing);

      for (final tab in tabs) {
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text(tab),
          ),
        );
        await _settle(tester);
        // A main tab has nothing behind it, so it must not offer a way back
        // out of the account.
        expect(find.byTooltip('Back'), findsNothing, reason: tab);
        await tester.binding.handlePopRoute();
        await _settle(tester);
        expect(SessionPolicy.signsOutWhenIdle, role == 'owner');
        expect(find.byType(screen), findsOneWidget, reason: tab);
        expect(find.byType(WelcomeScreen), findsNothing, reason: tab);
        expect(closedTheApp(), isFalse, reason: tab);
        final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
        expect(bar.selectedIndex, 0, reason: tab);
      }
      await _close(tester);
    });
  }

  testWidgets('back on the home tab asks before closing the app', (
    tester,
  ) async {
    await _signIn(tester, 'owner', OwnerMainScreen);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.text('Close Sydex?'), findsOneWidget);
    expect(closedTheApp(), isFalse);

    await tester.tap(find.text('Stay'));
    await _settle(tester);
    expect(find.text('Close Sydex?'), findsNothing);
    expect(closedTheApp(), isFalse);

    await tester.binding.handlePopRoute();
    await _settle(tester);
    await tester.tap(find.text('Close app'));
    await _settle(tester);
    expect(closedTheApp(), isTrue);
    await _close(tester);
  });

  testWidgets('a page opened on top still goes back to where it was', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await _signIn(tester, 'owner', OwnerMainScreen);
    final context = tester.element(find.byType(OwnerMainScreen));
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Opened page')),
      ),
    );
    await _settle(tester);
    expect(find.text('Opened page'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await _settle(tester);
    expect(find.text('Opened page'), findsNothing);
    expect(find.byType(OwnerMainScreen), findsOneWidget);
    expect(find.text('Close Sydex?'), findsNothing);
    await _close(tester);
    debugDefaultTargetPlatformOverride = null;
  });
}
