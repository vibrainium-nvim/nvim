import 'dart:async';
import 'dart:typed_data';

import 'msgpack.dart';

typedef RpcRequestHandler = FutureOr<Object?> Function(
  String method,
  List<Object?> params,
);

typedef RpcNotificationHandler = FutureOr<void> Function(
  String method,
  List<Object?> params,
);

class RpcException implements Exception {
  final Object? error;
  const RpcException(this.error);

  @override
  String toString() => 'RpcException($error)';
}

/// Bidirectional MessagePack-RPC session over arbitrary byte streams (e.g. stdin/stdout).
class RpcSession {
  final Stream<List<int>> _input;
  final void Function(Uint8List bytes) _output;
  final MsgpackStreamDecoder _decoder = MsgpackStreamDecoder();
  final Map<int, Completer<Object?>> _pending = {};
  int _nextMsgId = 1;
  StreamSubscription<List<int>>? _sub;

  RpcRequestHandler? onRequest;
  RpcNotificationHandler? onNotification;

  RpcSession({
    required Stream<List<int>> input,
    required void Function(Uint8List bytes) output,
  })  : _input = input,
        _output = output {
    _sub = _input.listen(_onData, onDone: _onDone);
  }

  Future<Object?> request(String method, [List<Object?> params = const []]) {
    final msgId = _nextMsgId++;
    final completer = Completer<Object?>();
    _pending[msgId] = completer;
    final payload = MsgpackCodec.encode([0, msgId, method, params]);
    _output(payload);
    return completer.future;
  }

  void notify(String method, [List<Object?> params = const []]) {
    final payload = MsgpackCodec.encode([2, method, params]);
    _output(payload);
  }

  Future<void> close() async {
    await _sub?.cancel();
    _onDone();
  }

  void _onData(List<int> chunk) {
    final messages = _decoder.addChunk(chunk);
    for (final msg in messages) {
      if (msg is! List || msg.isEmpty) continue;
      final type = msg[0];
      if (type == 0 && msg.length >= 4) {
        final msgId = msg[1] as int;
        final method = msg[2] as String;
        final params = (msg[3] as List?)?.cast<Object?>() ?? const <Object?>[];
        _handleRequest(msgId, method, params);
      } else if (type == 1 && msg.length >= 4) {
        final msgId = msg[1] as int;
        final error = msg[2];
        final result = msg[3];
        final completer = _pending.remove(msgId);
        if (completer != null) {
          if (error != null) {
            completer.completeError(RpcException(error));
          } else {
            completer.complete(result);
          }
        }
      } else if (type == 2 && msg.length >= 3) {
        final method = msg[1] as String;
        final params = (msg[2] as List?)?.cast<Object?>() ?? const <Object?>[];
        final handler = onNotification;
        if (handler != null) {
          Future.sync(() => handler(method, params));
        }
      }
    }
  }

  Future<void> _handleRequest(
    int msgId,
    String method,
    List<Object?> params,
  ) async {
    final handler = onRequest;
    if (handler == null) {
      _sendResponse(msgId, 'Unhandled method: $method', null);
      return;
    }
    try {
      final result = await handler(method, params);
      _sendResponse(msgId, null, result);
    } catch (e) {
      _sendResponse(msgId, e.toString(), null);
    }
  }

  void _sendResponse(int msgId, Object? error, Object? result) {
    final payload = MsgpackCodec.encode([1, msgId, error, result]);
    _output(payload);
  }

  void _onDone() {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(const RpcException('RPC session closed'));
      }
    }
    _pending.clear();
  }
}
