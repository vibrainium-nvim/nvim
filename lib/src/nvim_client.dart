import 'msgpack.dart';
import 'rpc_session.dart';

/// Typed Neovim API wrapper over [RpcSession].
class Nvim {
  final RpcSession rpc;

  Nvim(this.rpc);

  static int _asHandle(Object? raw) {
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

  Future<void> bufSetName(int buf, String name) async {
    await rpc.request('nvim_buf_set_name', [buf, name]);
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
}
