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

    test('Nvim.winGetWidth and Nvim.setOption send expected RPC requests', () async {
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

      final calls = <(String, List<Object?>)>[];
      sessionB.onRequest = (method, params) async {
        calls.add((method, params));
        if (method == 'nvim_win_get_width') {
          return 96;
        }
        return null;
      };

      final nvim = Nvim(sessionA);
      await nvim.setOption('showtabline', 0);
      final width = await nvim.winGetWidth(101);
      expect(width, 96);
      expect(calls[0].$1, 'nvim_set_option_value');
      expect(calls[0].$2, ['showtabline', 0, const <String, Object?>{}]);
      expect(calls[1].$1, 'nvim_win_get_width');
      expect(calls[1].$2, [101]);

      await sessionA.close();
      await sessionB.close();
      await aToB.close();
      await bToA.close();
    });

    test('catches exceptions thrown in onNotification without crashing session', () async {
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

      final received = <String>[];
      sessionB.onNotification = (method, params) async {
        received.add(method);
        if (method == 'boom') {
          await Future<void>.delayed(Duration.zero);
          throw const RpcException('Invalid window id: 1005');
        }
      };

      sessionA.notify('boom');
      sessionA.notify('after_boom');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(received, ['boom', 'after_boom']);

      await sessionA.close();
      await sessionB.close();
      await aToB.close();
      await bToA.close();
    });

    test('serializes concurrent async onNotification callbacks in strict FIFO order', () async {
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

      final log = <String>[];
      sessionB.onNotification = (method, params) async {
        log.add('start:$method');
        if (method == 'first') {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        log.add('end:$method');
      };

      sessionA.notify('first');
      sessionA.notify('second');
      sessionA.notify('third');

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(log, [
        'start:first',
        'end:first',
        'start:second',
        'end:second',
        'start:third',
        'end:third',
      ]);

      await sessionA.close();
      await sessionB.close();
      await aToB.close();
      await bToA.close();
    });
  });

  group('NvimMouseRouter and NvimContextMenu', () {
    test('parseActionParams and buildGlobalRightMouseLua cover all multi-clicks and modes', () {
      final lua = NvimMouseRouter.buildGlobalRightMouseLua();
      for (final key in NvimMouseRouter.rightMouseKeys) {
        expect(lua, contains("'$key'"));
      }
      expect(lua, contains("vim.keymap.set({ 'n', 'v', 'i', 't' }, key"));
      expect(lua, contains(NvimMouseRouter.rightMouseActionBufVar));
      expect(lua, contains('editor_tab.right_click'));
      expect(lua, contains(r"return vim.fn.mode(1) == 'n' and '' or '<C-\\><C-n>'"));

      final pos = NvimMouseRouter.parseActionParams([
        'workspace.context_menu',
        100,
        3,
        4,
        8,
        14,
        18,
      ]);
      expect(pos, isNotNull);
      expect(pos!.winId, 100);
      expect(pos.line, 3);
      expect(pos.winRow, 4);
      expect(pos.winCol, 8);
      expect(pos.screenRow, 14);
      expect(pos.screenCol, 18);

      expect(NvimMouseRouter.parseActionParams(['workspace.context_menu']), isNull);
    });

    test('coordinates single active overlay across menus and ignores stale menu_close buffer IDs', () async {
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

      var nextBuf = 10;
      var nextWin = 200;
      final validBufs = <int>{};
      final validWins = <int>{1};
      final bufVars = <int, Map<String, Object?>>{};
      var currentWin = 1;

      sessionB.onRequest = (method, params) async {
        switch (method) {
          case 'nvim_create_buf':
            final b = nextBuf++;
            validBufs.add(b);
            return b;
          case 'nvim_buf_is_valid':
            return validBufs.contains(params[0] as int);
          case 'nvim_buf_set_var':
            final b = params[0] as int;
            bufVars.putIfAbsent(b, () => {})[params[1].toString()] = params[2];
            return null;
          case 'nvim_open_win':
            final w = nextWin++;
            validWins.add(w);
            if (params[1] == true) currentWin = w;
            return w;
          case 'nvim_win_is_valid':
            return validWins.contains(params[0] as int);
          case 'nvim_win_close':
            validWins.remove(params[0] as int);
            return null;
          case 'nvim_get_current_win':
            return currentWin;
          case 'nvim_win_get_cursor':
            return [1, 0];
          default:
            return null;
        }
      };

      final nvim = Nvim(sessionA);
      final menuA = NvimContextMenu<NvimContextMenuItem>(
        nvim: nvim,
        actionPrefix: 'workspace',
        filetype: 'vibrainium-workspace-menu',
        augroupName: 'TestMenuA',
        rightClickAction: 'workspace.context_menu',
      );
      final menuB = NvimContextMenu<NvimContextMenuItem>(
        nvim: nvim,
        actionPrefix: 'vcs',
        filetype: 'vibrainium-vcs-menu',
        augroupName: 'TestMenuB',
        rightClickAction: 'vcs.context_menu',
      );

      await menuA.openMenu(
        items: [
          NvimContextMenuItem(label: 'New File', shortcut: 'n', onSelect: () async {}),
        ],
      );
      expect(menuA.isOpen, isTrue);
      final firstBufA = menuA.bufferId!;
      final firstWinA = menuA.windowId!;
      expect(
        bufVars[firstBufA]![NvimMouseRouter.rightMouseActionBufVar],
        'workspace.context_menu',
      );

      // Opening menuB on the same Nvim automatically closes menuA
      await menuB.openMenu(
        items: [
          NvimContextMenuItem(label: 'Stage File', shortcut: 's', onSelect: () async {}),
        ],
      );
      expect(menuA.isOpen, isFalse);
      expect(validWins.contains(firstWinA), isFalse);
      expect(menuB.isOpen, isTrue);

      // Reopening menuA closes menuB, and a stale menu_close from firstBufA does NOT close the new menuA
      await menuA.openMenu(
        items: [
          NvimContextMenuItem(label: 'Rename', shortcut: 'r', onSelect: () async {}),
        ],
      );
      expect(menuB.isOpen, isFalse);
      expect(menuA.isOpen, isTrue);
      final secondBufA = menuA.bufferId!;
      expect(secondBufA, isNot(firstBufA));

      await menuA.cancel(expectedBufId: firstBufA);
      expect(menuA.isOpen, isTrue);

      await menuA.cancel(expectedBufId: secondBufA);
      expect(menuA.isOpen, isFalse);

      await sessionA.close();
      await sessionB.close();
      await aToB.close();
      await bToA.close();
    });
  });
}
