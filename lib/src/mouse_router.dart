import 'msgpack.dart';
import 'nvim_client.dart';

/// Shared target-window `<RightMouse>` router for Neovim UI panels and winbars.
///
/// Neovim resolves buffer-local mouse keymaps against the *currently focused*
/// buffer and mode rather than the window underneath the mouse cursor.
/// [NvimMouseRouter] installs a single idempotent global `expr` handler across
/// Normal, Visual/Select, Insert, and Terminal modes (`{'n', 'v', 'i', 't'}`)
/// and all click counts (`<RightMouse>` through `<4-RightMouse>`), routing by
/// target window (`getmousepos().winid`) and declarative buffer metadata
/// (`vim.b[buf].vibrainium_right_mouse_action`) while capturing mouse
/// coordinates synchronously at click time.
class NvimMouseRouter {
  /// Buffer-scoped variable name (`b:vibrainium_right_mouse_action`) declaring
  /// the RPC action to invoke when a window displaying that buffer is
  /// right-clicked from any window or mode.
  static const String rightMouseActionBufVar = 'vibrainium_right_mouse_action';

  /// All right-click key sequences (single through quadruple click within
  /// Neovim's `'mousetime'`) handled by the router.
  static const List<String> rightMouseKeys = <String>[
    '<RightMouse>',
    '<2-RightMouse>',
    '<3-RightMouse>',
    '<4-RightMouse>',
  ];

  const NvimMouseRouter._();

  /// Generates the idempotent Lua snippet that installs the global
  /// target-window `<RightMouse>` router.
  static String buildGlobalRightMouseLua({
    String actionModule = 'vibrainium',
    String winbarAction = 'editor_tab.right_click',
  }) {
    return '''
do
  local function make_right_mouse_handler(fallback_key)
    return function()
      local ok_pos, pos = pcall(vim.fn.getmousepos)
      if ok_pos and pos and pos.winid and pos.winid > 0 and vim.api.nvim_win_is_valid(pos.winid) then
        local w = pos.winid
        local line = pos.line or 0
        local wrow = pos.winrow or 0
        local wcol = pos.wincol or 0
        local srow = pos.screenrow or 0
        local scol = pos.screencol or 0
        local ok_buf, buf = pcall(vim.api.nvim_win_get_buf, w)
        local action = (ok_buf and buf and buf > 0) and vim.b[buf].$rightMouseActionBufVar or nil
        if line == 0 and wrow <= 1 and (type(action) ~= 'string' or action == '') then
          local col1 = wcol > 0 and wcol or 1
          local sr1 = srow > 0 and srow or 1
          local sc1 = scol > 0 and scol or 1
          vim.schedule(function()
            require('$actionModule').action('$winbarAction', w, col1, sr1, sc1)
          end)
          return vim.fn.mode(1) == 'n' and '' or '<C-\\\\><C-n>'
        end
        if type(action) == 'string' and action ~= '' then
          vim.schedule(function()
            require('$actionModule').action(action, w, line, wrow, wcol, srow, scol)
          end)
          return vim.fn.mode(1) == 'n' and '' or '<C-\\\\><C-n>'
        end
      end
      return fallback_key
    end
  end
  for _, key in ipairs({ '<RightMouse>', '<2-RightMouse>', '<3-RightMouse>', '<4-RightMouse>' }) do
    vim.keymap.set({ 'n', 'v', 'i', 't' }, key, make_right_mouse_handler(key), {
      expr = true,
      silent = true,
      desc = 'Vibrainium: Target-Window Context Menu Router',
    })
  end
end
''';
  }

  static int? _parseInt(Object? raw) {
    if (raw == null) return null;
    if (raw is int) return raw;
    if (raw is MsgpackExt) return raw.toHandle();
    return int.tryParse(raw.toString());
  }

  /// Parses synchronous click coordinates `(winId, line, winRow, winCol,
  /// screenRow, screenCol)` appended to RPC action [params] starting at
  /// [offset], or returns `null` when [params] does not carry mouse coordinates.
  static MousePosition? parseActionParams(
    List<Object?> params, {
    int offset = 1,
  }) {
    if (params.length < offset + 6) return null;
    final winId = _parseInt(params[offset]) ?? 0;
    final line = _parseInt(params[offset + 1]) ?? 0;
    final winRow = _parseInt(params[offset + 2]) ?? 0;
    final winCol = _parseInt(params[offset + 3]) ?? 0;
    final screenRow = _parseInt(params[offset + 4]) ?? 0;
    final screenCol = _parseInt(params[offset + 5]) ?? 0;
    if (winId <= 0 && screenRow <= 0 && screenCol <= 0) {
      return null;
    }
    return MousePosition(
      winId: winId,
      winRow: winRow,
      winCol: winCol,
      line: line,
      column: winCol,
      screenRow: screenRow,
      screenCol: screenCol,
    );
  }
}
