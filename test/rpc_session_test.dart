import 'dart:async';
import 'dart:typed_data';
import 'package:nvim/nvim.dart';
import 'package:test/test.dart';

void main() {
  group('RpcSession', () {
    test('handles bidirectional requests and notifications', () async {
      final aToB = StreamController<List<int>>();
      final bToA = StreamController<List<int>>();

      final sessionA = RpcSession(
        input: bToA.stream,
        output: (Uint8List bytes) => aToB.add(bytes),
      );
      final sessionB = RpcSession(
        input: aToB.stream,
        output: (Uint8List bytes) => bToA.add(bytes),
      );

      final notifications = <(String, List<Object?>)>[];
      sessionB.onRequest = (method, params) async {
        if (method == 'sum') {
          return (params[0] as int) + (params[1] as int);
        }
        throw StateError('Unknown method');
      };
      sessionB.onNotification = (method, params) {
        notifications.add((method, params));
      };

      final sum = await sessionA.request('sum', [10, 32]);
      expect(sum, 42);

      sessionA.notify('ping', ['hello']);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(notifications, hasLength(1));
      expect(notifications.first.$1, 'ping');
      expect(notifications.first.$2, ['hello']);

      await expectLater(
        sessionA.request('unknown'),
        throwsA(isA<RpcException>()),
      );

      await sessionA.close();
      await sessionB.close();
      await aToB.close();
      await bToA.close();
    });

    test('Nvim.winSetBuf sends nvim_win_set_buf RPC request', () async {
      final aToB = StreamController<List<int>>();
      final bToA = StreamController<List<int>>();

      final sessionA = RpcSession(
        input: bToA.stream,
        output: (Uint8List bytes) => aToB.add(bytes),
      );
      final sessionB = RpcSession(
        input: aToB.stream,
        output: (Uint8List bytes) => bToA.add(bytes),
      );

      List<Object?>? capturedParams;
      sessionB.onRequest = (method, params) async {
        if (method == 'nvim_win_set_buf') {
          capturedParams = params;
          return null;
        }
        throw StateError('Unexpected method: $method');
      };

      final nvim = Nvim(sessionA);
      await nvim.winSetBuf(100, 2);
      expect(capturedParams, [100, 2]);

      await sessionA.close();
      await sessionB.close();
      await aToB.close();
      await bToA.close();
    });
  });
}
