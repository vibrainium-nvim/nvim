import 'mouse_router.dart';
import 'msgpack.dart';
import 'rpc_session.dart';

/// Mouse position returned by Neovim's `getmousepos()`.
class MousePosition {
  final int winId;
  final int winRow;
  final int winCol;
  final int line;
  final int column;
  final int screenRow;
  final int screenCol;

  const MousePosition({
    required this.winId,
    required this.winRow,
    required this.winCol,
    required this.line,
    required this.column,
    required this.screenRow,
    required this.screenCol,
  });
}

/// Typed Neovim API wrapper over [RpcSession].
class Nvim {
  final RpcSession rpc;
  bool _rightMouseRouterInstalled = false;
  Future<void> Function()? _activeOverlayCloser;

  Nvim(this.rpc);

  /// Closes any currently active floating overlay/context menu owned by another
  /// component on this [Nvim] session before opening a new one.
  Future<void> activateOverlay(Future<void> Function() closer) async {
    final prev = _activeOverlayCloser;
    if (prev != null && prev != closer) {
      _activeOverlayCloser = null;
      await prev();
    }
    _activeOverlayCloser = closer;
  }

  /// Registers [closer] as the active floating overlay closer for this [Nvim].
  void setOverlayCloser(Future<void> Function() closer) {
    _activeOverlayCloser = closer;
  }

  /// Clears [closer] if it is still the active floating overlay closer.
  void clearOverlayCloser(Future<void> Function() closer) {
    if (_activeOverlayCloser == closer) {
      _activeOverlayCloser = null;
    }
  }

  /// Marks the global `<RightMouse>` router for re-installation (e.g. on hot reload).
  void resetRightMouseRouterForHotReload() {
    _rightMouseRouterInstalled = false;
  }

  /// Ensures the shared target-window `<RightMouse>` router is installed once
  /// in the connected Neovim instance.
  Future<void> ensureRightMouseRouter() async {
    if (_rightMouseRouterInstalled) return;
    _rightMouseRouterInstalled = true;
    try {
      await execLua(NvimMouseRouter.buildGlobalRightMouseLua());
    } catch (_) {}
  }

  /// Declaratively registers [action] as the right-click target handler on
  /// buffer [buf] (`b:vibrainium_right_mouse_action`) and ensures the global
  /// target-window `<RightMouse>` router is installed.
  Future<void> registerRightClickBuffer(int buf, String action) async {
    await ensureRightMouseRouter();
    await bufSetVar(buf, NvimMouseRouter.rightMouseActionBufVar, action);
  }

  static int _asHandle(Object? raw) {
    if (raw == null) return 0;
    if (raw is int) return raw;
    if (raw is MsgpackExt) return raw.toHandle();
    throw ArgumentError('Expected Neovim handle (int or MsgpackExt), got: $raw');
  }

  Future<int> createNamespace(String name) async {
    final res = await rpc.request('nvim_create_namespace', [name]);
    return res as int;
  }

  Future<int> createBuf({required bool listed, required bool scratch}) async {
    final res = await rpc.request('nvim_create_buf', [listed, scratch]);
    return _asHandle(res);
  }

  Future<bool> bufIsValid(int buf) async {
    final res = await rpc.request('nvim_buf_is_valid', [buf]);
    return res == true;
  }

  Future<void> bufSetLines(
    int buf, {
    int start = 0,
    int end = -1,
    bool strictIndexing = false,
    required List<String> lines,
  }) async {
    await rpc.request('nvim_buf_set_lines', [
      buf,
      start,
      end,
      strictIndexing,
      lines,
    ]);
  }

  Future<List<String>> bufGetLines(
    int buf, {
    int start = 0,
    int end = -1,
    bool strictIndexing = false,
  }) async {
    final res = await rpc.request('nvim_buf_get_lines', [
      buf,
      start,
      end,
      strictIndexing,
    ]);
    return (res as List).map((e) => e.toString()).toList();
  }

  Future<void> bufSetOption(int buf, String name, Object? value) async {
    await rpc.request(
      'nvim_set_option_value',
      [
        name,
        value,
        {'buf': buf},
      ],
    );
  }

  Future<Object?> bufGetOption(int buf, String name) async {
    return rpc.request(
      'nvim_get_option_value',
      [
        name,
        {'buf': buf},
      ],
    );
  }

  Future<void> bufSetName(int buf, String name) async {
    await rpc.request('nvim_buf_set_name', [buf, name]);
  }

  Future<String> bufGetName(int buf) async {
    final res = await rpc.request('nvim_buf_get_name', [buf]);
    return res?.toString() ?? '';
  }

  Future<void> bufSetVar(int buf, String name, Object? value) async {
    await rpc.request('nvim_buf_set_var', [buf, name, value]);
  }

  Future<int> getCurrentBuf() async {
    final res = await rpc.request('nvim_get_current_buf');
    return _asHandle(res);
  }

  Future<void> bufSetKeymap(
    int buf,
    String mode,
    String lhs,
    String rhs, {
    bool noremap = true,
    bool silent = true,
    bool nowait = true,
  }) async {
    await rpc.request('nvim_buf_set_keymap', [
      buf,
      mode,
      lhs,
      rhs,
      {
        'noremap': noremap,
        'silent': silent,
        'nowait': nowait,
      },
    ]);
  }

  Future<void> bufClearNamespace(
    int buf,
    int nsId, {
    int lineStart = 0,
    int lineEnd = -1,
  }) async {
    await rpc.request('nvim_buf_clear_namespace', [
      buf,
      nsId,
      lineStart,
      lineEnd,
    ]);
  }

  Future<int> bufSetExtmark(
    int buf,
    int nsId,
    int line,
    int col,
    Map<String, Object?> opts,
  ) async {
    final res = await rpc.request('nvim_buf_set_extmark', [
      buf,
      nsId,
      line,
      col,
      opts,
    ]);
    return res as int;
  }

  Future<int> openWin(
    int buf,
    bool enter,
    Map<String, Object?> config,
  ) async {
    final res = await rpc.request('nvim_open_win', [buf, enter, config]);
    return _asHandle(res);
  }

  Future<void> winSetConfig(int win, Map<String, Object?> config) async {
    await rpc.request('nvim_win_set_config', [win, config]);
  }

  Future<Map<String, Object?>> winGetConfig(int win) async {
    final res = await rpc.request('nvim_win_get_config', [win]);
    if (res is Map) {
      return res.map((k, v) => MapEntry(k.toString(), v));
    }
    return const {};
  }

  Future<bool> winIsValid(int win) async {
    final res = await rpc.request('nvim_win_is_valid', [win]);
    return res == true;
  }

  Future<void> winClose(int win, {bool force = true}) async {
    await rpc.request('nvim_win_close', [win, force]);
  }

  Future<void> winSetOption(int win, String name, Object? value) async {
    await rpc.request(
      'nvim_set_option_value',
      [
        name,
        value,
        {'win': win},
      ],
    );
  }

  Future<void> setOption(String name, Object? value) async {
    await rpc.request(
      'nvim_set_option_value',
      [
        name,
        value,
        const <String, Object?>{},
      ],
    );
  }

  Future<int> winGetWidth(int win) async {
    final res = await rpc.request('nvim_win_get_width', [win]);
    return (res is int && res > 0) ? res : 80;
  }

  Future<int> winGetHeight(int win) async {
    final res = await rpc.request('nvim_win_get_height', [win]);
    return (res is int && res > 0) ? res : 24;
  }

  /// Returns `(row1Based, col0Based)`.
  Future<(int, int)> winGetCursor(int win) async {
    final res = (await rpc.request('nvim_win_get_cursor', [win])) as List;
    return (res[0] as int, res[1] as int);
  }

  Future<void> winSetCursor(int win, int row1Based, int col0Based) async {
    await rpc.request('nvim_win_set_cursor', [
      win,
      [row1Based, col0Based],
    ]);
  }

  Future<int> getCurrentWin() async {
    final res = await rpc.request('nvim_get_current_win');
    return _asHandle(res);
  }

  /// Returns the window ID of Neovim's alternate (previous) window (`winnr('#')`),
  /// or `null` if unavailable.
  Future<int?> getAlternateWin() async {
    final prevNr = await rpc.request('nvim_call_function', ['winnr', ['#']]);
    if (prevNr is! int || prevNr <= 0) return null;
    final winId = await rpc.request('nvim_call_function', ['win_getid', [prevNr]]);
    final handle = _asHandle(winId);
    return handle > 0 ? handle : null;
  }

  Future<void> setCurrentWin(int win) async {
    await rpc.request('nvim_set_current_win', [win]);
  }

  Future<List<int>> listWins() async {
    final res = (await rpc.request('nvim_list_wins')) as List;
    return res.map(_asHandle).toList();
  }

  Future<int> winGetBuf(int win) async {
    final res = await rpc.request('nvim_win_get_buf', [win]);
    return _asHandle(res);
  }

  Future<void> winSetBuf(int win, int buf) async {
    await rpc.request('nvim_win_set_buf', [win, buf]);
  }

  Future<void> setHl(int nsId, String name, Map<String, Object?> val) async {
    await rpc.request('nvim_set_hl', [nsId, name, val]);
  }

  Future<void> command(String cmd) async {
    await rpc.request('nvim_command', [cmd]);
  }

  Future<Object?> execLua(String code, [List<Object?> args = const []]) async {
    return rpc.request('nvim_exec_lua', [code, args]);
  }

  /// Sends [data] to Neovim channel/terminal job [chan] via `nvim_chan_send`.
  Future<void> chanSend(int chan, String data) async {
    await rpc.request('nvim_chan_send', [chan, data]);
  }

  Future<String> getCwd() async {
    final res = await rpc.request('nvim_call_function', ['getcwd', const <Object?>[]]);
    return res.toString();
  }

  Future<int> getEditorWidth() async {
    final res = await rpc.request('nvim_get_option_value', ['columns', const <String, Object?>{}]);
    return res as int;
  }

  Future<int> getEditorHeight() async {
    final res = await rpc.request('nvim_get_option_value', ['lines', const <String, Object?>{}]);
    return res as int;
  }

  Future<void> notify(String message, {int level = 2}) async {
    await rpc.request('nvim_notify', [
      message,
      level,
      const <String, Object?>{},
    ]);
  }

  /// Sets Neovim register [register] to [value] via `setreg(register, value)`.
  Future<void> setReg(String register, String value) async {
    await rpc.request('nvim_call_function', [
      'setreg',
      [register, value],
    ]);
  }

  /// Copies [text] to the unnamed register (`"`) and system clipboard registers (`+`, `*`).
  Future<void> copyToClipboard(String text) async {
    await setReg('"', text);
    for (final reg in const ['+', '*']) {
      try {
        await setReg(reg, text);
      } catch (_) {}
    }
  }

  /// Calls `getmousepos()` and returns a [MousePosition], or `null` if unavailable.
  Future<MousePosition?> getMousePos() async {
    final res = await rpc.request(
      'nvim_call_function',
      ['getmousepos', const <Object?>[]],
    );
    if (res is! Map) return null;
    final winIdRaw = res['winid'];
    final winId = winIdRaw == null ? 0 : _asHandle(winIdRaw);
    final winRow = (res['winrow'] as int?) ?? 0;
    final winCol = (res['wincol'] as int?) ?? 0;
    final line = (res['line'] as int?) ?? 0;
    final column = (res['column'] as int?) ?? 0;
    final screenRow = (res['screenrow'] as int?) ?? 0;
    final screenCol = (res['screencol'] as int?) ?? 0;
    if (winId == 0 && screenRow == 0 && screenCol == 0) {
      return null;
    }
    return MousePosition(
      winId: winId,
      winRow: winRow,
      winCol: winCol,
      line: line,
      column: column,
      screenRow: screenRow,
      screenCol: screenCol,
    );
  }

  /// Returns 0-based `(row, col)` screen position of [win].
  Future<(int, int)> winGetPosition(int win) async {
    final res = await rpc.request('nvim_win_get_position', [win]);
    if (res is List && res.length >= 2) {
      return (res[0] as int, res[1] as int);
    }
    return (0, 0);
  }

  /// Returns 1-based first visible buffer line (`w0`) in [win].
  Future<int> winGetTopLine(int win) async {
    final res = await rpc.request(
      'nvim_call_function',
      ['line', ['w0', win]],
    );
    return (res is int && res > 0) ? res : 1;
  }
}
