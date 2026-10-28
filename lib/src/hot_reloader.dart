import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate';

/// In-process Dart VM hot reloader using `dart:developer` and the VM Service protocol.
class HotReloader {
  static Uri? _wsUri;
  static Future<bool>? _inFlight;

  /// Triggers `reloadSources` on the current isolate without printing to `stdout`.
  /// Returns `true` if the reload succeeded.
  static Future<bool> reload() {
    final existing = _inFlight;
    if (existing != null) return existing;
    final future = _doReload();
    _inFlight = future.whenComplete(() {
      _inFlight = null;
    });
    return _inFlight!;
  }

  static Future<bool> _doReload() async {
    for (var attempt = 0; attempt < 5; attempt++) {
      final ok = await _tryReloadOnce();
      if (ok) return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  static Future<bool> _tryReloadOnce() async {
    try {
      final wsUri = await _ensureVmServiceWsUri();
      final isolateId = Service.getIsolateId(Isolate.current);
      if (wsUri == null || isolateId == null) {
        return false;
      }

      final ws = await WebSocket.connect(wsUri.toString());
      try {
        final completer = Completer<bool>();
        ws.listen(
          (data) {
            if (completer.isCompleted) return;
            final decoded = jsonDecode(data.toString());
            if (decoded is Map && decoded['id'] == '1') {
              final result = decoded['result'];
              final success = result is Map && result['success'] == true;
              completer.complete(success);
            }
          },
          onError: (_) {
            if (!completer.isCompleted) completer.complete(false);
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete(false);
          },
        );

        ws.add(jsonEncode({
          'jsonrpc': '2.0',
          'id': '1',
          'method': 'reloadSources',
          'params': {
            'isolateId': isolateId,
          },
        }));

        return await completer.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () => false,
        );
      } finally {
        await ws.close();
      }
    } catch (_) {
      return false;
    }
  }

  /// Watches [directories] for `.dart` file modifications, hot-reloads the isolate,
  /// and invokes [onReloaded] whenever a reload succeeds.
  static List<StreamSubscription<FileSystemEvent>> watchDirs(
    List<String> directories, {
    required Future<void> Function() onReloaded,
    Duration debounce = const Duration(milliseconds: 150),
  }) {
    Timer? timer;
    final subscriptions = <StreamSubscription<FileSystemEvent>>[];

    for (final path in directories) {
      final dir = Directory(path);
      if (!dir.existsSync()) continue;
      try {
        final sub = dir.watch(recursive: true).listen((event) {
          if (!event.path.endsWith('.dart')) return;
          timer?.cancel();
          timer = Timer(debounce, () async {
            final ok = await reload();
            if (ok) {
              await onReloaded();
            }
          });
        });
        subscriptions.add(sub);
      } catch (_) {
        // Ignore if directory watching is unsupported on the current platform/filesystem.
      }
    }

    return subscriptions;
  }

  static Future<Uri?> _ensureVmServiceWsUri() async {
    if (_wsUri != null) return _wsUri;

    var info = await Service.getInfo();
    if (info.serverUri == null) {
      info = await Service.controlWebServer(enable: true, silenceOutput: true);
    }
    final serverUri = info.serverUri;
    if (serverUri == null) return null;

    final scheme = serverUri.scheme == 'https' ? 'wss' : 'ws';
    final basePath = serverUri.path.endsWith('/')
        ? '${serverUri.path}ws'
        : '${serverUri.path}/ws';
    _wsUri = serverUri.replace(scheme: scheme, path: basePath);
    return _wsUri;
  }
}
