import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sydex/widgets/horizon_motion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sydex/theme/workspace_theme.dart';
import 'package:sydex/widgets/desktop_workspace.dart';

void main() {
  testWidgets('sidebar collapses and every destination remains reachable', (
    tester,
  ) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              DesktopWorkspaceSidebar(
                userName: 'A long business owner name',
                role: 'Owner',
                onProfile: () {},
                destinations: [
                  WorkspaceDestination(
                    label: 'Overview',
                    icon: Icons.home,
                    selected: true,
                    onTap: () {},
                  ),
                  WorkspaceDestination(
                    label: 'Import old cards',
                    icon: Icons.document_scanner_outlined,
                    onTap: () => opened = true,
                  ),
                ],
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Collapse navigation'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Expand navigation'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.document_scanner_outlined));
    expect(opened, isTrue);
    await tester.tap(find.byTooltip('Expand navigation'));
    await tester.pumpAndSettle();
    expect(find.text('Import old cards'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'page animation preserves form state and respects reduced motion',
    (tester) async {
      var identity = false;
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  rebuild = setState;
                  return WorkspacePageTransition(
                    identity: identity,
                    child: const TextField(),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'Unsaved payment note');
      rebuild(() => identity = true);
      await tester.pump();
      expect(find.text('Unsaved payment note'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(WorkspacePageTransition),
          matching: find.byType(FadeTransition),
        ),
        findsNothing,
      );
    },
  );

  testWidgets('loading layout fits a narrow window with reduced motion', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: const Scaffold(
            body: SizedBox(width: 320, child: WorkspaceLoadingView()),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('dashboard action controls support keyboard activation', (
    tester,
  ) async {
    var activations = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HorizonPressable(
            onTap: () => activations++,
            child: const Padding(
              padding: EdgeInsets.all(20),
              child: Text('Open customers'),
            ),
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(activations, 1);
  });

  test('workspace themes retain accent and readable surfaces', () {
    for (final brightness in Brightness.values) {
      final base = ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: brightness,
        ),
      );
      final theme = workspaceTheme(base);
      expect(theme.colorScheme.primary, base.colorScheme.primary);
      final surface = theme.colorScheme.surface.computeLuminance();
      final foreground = theme.colorScheme.onSurface.computeLuminance();
      final ratio = (foreground > surface)
          ? (foreground + .05) / (surface + .05)
          : (surface + .05) / (foreground + .05);
      expect(ratio, greaterThan(4.5));
    }
  });
}
