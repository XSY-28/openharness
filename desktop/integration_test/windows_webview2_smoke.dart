// Disposable fork proof. The Windows adapter and WebView2 run without mocks.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:harness/core/models.dart';
import 'package:harness/core/native_webview_runtime.dart';
import 'package:harness/core/test_run.dart';
import 'package:harness/state/terminal_pane.dart';
import 'package:harness/widgets/web_pane_panel.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_win_floating/webview_win_floating.dart';

import '../test/swarm_state_test.dart' show createApp;

const _marker = 'harness-native-webview2-4344';
const _startPath = '/viewer/start';
const _endPath = '/viewer/landed';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real WebView2 renders loopback and follows native navigation', (
    tester,
  ) async {
    expect(kUnderTest, isTrue, reason: 'Use the disposable runner test mode.');
    await NativeWebViewRuntime.initialize();
    expect(
      NativeWebViewRuntime.available,
      isTrue,
      reason: 'WebView2 runtime probe failed.',
    );
    expect(WebViewPlatform.instance, isA<WindowsWebViewPlatform>());
    debugPrint('WEBVIEW2_PROOF_NATIVE_ADAPTER_READY');
    // kUnderTest disables background app actions and normally hides native views.
    // Re-enable this viewer only after confirming its actual registered runtime.
    WebPanePanel.webviewAvailableForTest = true;
    addTearDown(() => WebPanePanel.webviewAvailableForTest = null);

    final visits = <String>{};
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final origin = 'http://127.0.0.1:${server.port}';
    final landing = '$origin$_endPath?via=redirect';
    server.listen((request) async {
      visits.add(request.uri.path);
      if (request.uri.path == _startPath) {
        await request.response.redirect(Uri.parse(landing));
      } else if (request.uri.path == _endPath) {
        request.response.headers.contentType = ContentType.html;
        request.response.write('''<!doctype html>
<html><body data-harness-proof="$_marker" style="margin:0;background:#37bd6a">
<main style="font:24px sans-serif;padding:24px">WebView2 proof</main>
</body></html>''');
        await request.response.close();
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    });

    final app = createApp();
    addTearDown(app.dispose);
    app.stateOf('m')!.agents = [
      Agent(
        id: 'a0',
        name: 'Fixture',
        engine: 'claude',
        dsh: 'autonomous/web-studio',
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WebPanePanel(
            notifier: app,
            pane: TerminalPane(
              id: 1,
              machineId: 'm',
              kind: PaneKind.web,
              ownerAgentId: 'a0',
              url: '$origin$_startPath',
            ),
            ownerName: 'Fixture',
            ownerEngine: 'claude',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(WinWebViewWidget), findsOneWidget);
    final address = find.byKey(const ValueKey('web-pane-address'));
    String shownAddress() => tester.widget<TextField>(address).controller!.text;
    final clock = Stopwatch()..start();
    while ((!visits.contains(_endPath) || shownAddress() != landing) &&
        clock.elapsed < const Duration(seconds: 20)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(visits, containsAll([_startPath, _endPath]));
    expect(shownAddress(), landing);
    final view = tester.widget<WinWebViewWidget>(find.byType(WinWebViewWidget));
    final result = await view.controller
        .runJavaScriptReturningResult('document.body.dataset.harnessProof')
        .timeout(const Duration(seconds: 10));
    expect(result, anyOf(equals(_marker), equals(jsonEncode(_marker))));
    debugPrint('WEBVIEW2_PROOF_NATIVE_LOAD_ADDRESS_AND_DOM_OK');

    final capture = Platform.environment['HARNESS_WEBVIEW2_PROOF_CAPTURE'];
    final screenshot =
        Platform.environment['HARNESS_WEBVIEW2_PROOF_SCREENSHOT'];
    if (capture != null && screenshot != null) {
      final outcome = await Process.run('pwsh.exe', [
        '-NoProfile',
        '-File',
        capture,
        '-TargetPid',
        '$pid',
        '-OutputPath',
        screenshot,
      ]).timeout(const Duration(seconds: 15));
      debugPrint('${outcome.stdout}'.trim());
      if (outcome.exitCode == 0) {
        expect(await File(screenshot).exists(), isTrue);
      } else {
        expect(outcome.exitCode, 20, reason: '${outcome.stderr}');
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await view.controller.dispose();
  }, skip: !Platform.isWindows);
}
