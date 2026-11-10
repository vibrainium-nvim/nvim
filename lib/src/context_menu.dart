import 'nvim_client.dart';

/// Base item model for [NvimContextMenu].
class NvimContextMenuItem {
  final String label;
  final String shortcut;
  final bool isSubmenu;
  final Future<void> Function() onSelect;

  const NvimContextMenuItem({
    required this.label,
    this.shortcut = '',
    this.isSubmenu = false,
    required this.onSelect,
  });
}

/// Shared floating context menu widget for Neovim sidebars, panels, and winbars.
///
/// Coordinates with [Nvim.activateOverlay] so at most one context menu or modal
/// overlay is open at any time across an [Nvim] session, registers optional
/// right-click pass-through on its floating buffer via
/// [Nvim.registerRightClickBuffer], and scopes `WinLeave`/`BufLeave`
/// auto-dismissal to the exact menu buffer ID so delayed notifications from a
/// closed menu never dismiss a newly opened menu.
class NvimContextMenu<T extends NvimContextMenuItem> {
  final Nvim nvim;
  final String actionPrefix;
  final String filetype;
  final String augroupName;
  final String actionModule;
  final String? rightClickAction;
  final bool cancelOnOutsideClick;

  int? _buf;
  int? _win;
  List<T> _items = const [];
  Future<void> Function()? _onBack;
  Future<void> Function()? _onCancel;
  int _lastRow = 1;
  int _lastCol = 2;

  NvimContextMenu({
    required this.nvim,
    required this.actionPrefix,
    required this.filetype,
    required this.augroupName,
    this.actionModule = 'vibrainium',
    this.rightClickAction,
    this.cancelOnOutsideClick = false,
  });

  bool get isOpen => _win != null;
  int? get windowId => _win;
  int? get bufferId => _buf;
  List<T> get items => List.unmodifiable(_items);
  int get lastRow => _lastRow;
  int get lastCol => _lastCol;

  Future<void> openMenu({
    required List<T> items,
    String title = 'Actions',
    int? anchorWin,
    int? row,
    int? col,
    int minWidth = 22,
    int maxWidth = 48,
    int padding = 4,
    bool clampToEditor = false,
    bool bindRightArrowSubmenu = false,
    Map<String, int> extraMnemonics = const {},
    Future<void> Function()? onBack,
    Future<void> Function()? onCancel,
  }) async {
    await nvim.activateOverlay(close);
    await close();
    if (items.isEmpty) return;

    nvim.setOverlayCloser(close);
    _items = items;
    _onBack = onBack;
    _onCancel = onCancel;

    final buf = await nvim.createBuf(listed: false, scratch: true);
    _buf = buf;

    var maxLabelLen = 0;
    var maxShortcutLen = 0;
    for (final item in items) {
      final labelLen = item.label.runes.length;
      final shortcutLen = item.shortcut.runes.length;
      if (labelLen > maxLabelLen) {
        maxLabelLen = labelLen;
      }
      if (shortcutLen > maxShortcutLen) {
        maxShortcutLen = shortcutLen;
      }
    }

    final innerWidth =
        (maxLabelLen + maxShortcutLen + padding).clamp(minWidth, maxWidth);
    final lines = <String>[];
    for (final item in items) {
      final labelLen = item.label.runes.length;
      final shortcutLen = item.shortcut.runes.length;
      if (shortcutLen == 0) {
        final padCount = (innerWidth - 2 - labelLen).clamp(0, innerWidth);
        lines.add(' ${item.label}${' ' * padCount} ');
      } else {
        final padCount =
            (innerWidth - 2 - labelLen - shortcutLen).clamp(1, innerWidth);
        lines.add(' ${item.label}${' ' * padCount}${item.shortcut} ');
      }
    }

    await nvim.bufSetOption(buf, 'modifiable', true);
    await nvim.bufSetLines(buf, lines: lines);
    await nvim.bufSetOption(buf, 'modifiable', false);
    await nvim.bufSetOption(buf, 'buftype', 'nofile');
    await nvim.bufSetOption(buf, 'bufhidden', 'wipe');
    await nvim.bufSetOption(buf, 'filetype', filetype);

    if (rightClickAction != null && rightClickAction!.isNotEmpty) {
      await nvim.registerRightClickBuffer(buf, rightClickAction!);
    } else {
      await nvim.ensureRightMouseRouter();
    }

    var resolvedRow = row ?? 1;
    var resolvedCol = col ?? 2;
    if (anchorWin == null && clampToEditor) {
      var editorWidth = 120;
      var editorHeight = 40;
      try {
        editorWidth = await nvim.getEditorWidth();
        editorHeight = await nvim.getEditorHeight();
      } catch (_) {}
      resolvedRow = resolvedRow.clamp(
        1,
        (editorHeight - lines.length - 2).clamp(1, editorHeight),
      );
      resolvedCol = resolvedCol.clamp(
        0,
        (editorWidth - innerWidth - 2).clamp(0, editorWidth),
      );
    }
    _lastRow = resolvedRow;
    _lastCol = resolvedCol;

    final config = <String, Object?>{
      if (anchorWin != null) ...{
        'relative': 'win',
        'win': anchorWin,
        'row': resolvedRow,
        'col': resolvedCol,
      } else ...{
        'relative': 'editor',
        'row': resolvedRow,
        'col': resolvedCol,
      },
      'width': innerWidth,
      'height': lines.length,
      'style': 'minimal',
      'border': 'rounded',
      'title': ' $title ',
      'title_pos': 'center',
    };

    final win = await nvim.openWin(buf, true, config);
    _win = win;

    await nvim.winSetOption(win, 'cursorline', true);
    await nvim.winSetOption(win, 'wrap', false);
    await nvim.winSetCursor(win, 1, 0);
    await nvim.command('stopinsert');

    for (final mode in const ['n', 'i']) {
      await nvim.bufSetKeymap(
        buf,
        mode,
        '<LeftMouse>',
        "<LeftMouse><Cmd>lua require('$actionModule').action('$actionPrefix.menu_click')<CR>",
      );
      await nvim.bufSetKeymap(
        buf,
        mode,
        '<2-LeftMouse>',
        "<LeftMouse><Cmd>lua require('$actionModule').action('$actionPrefix.menu_click')<CR>",
      );
      await nvim.bufSetKeymap(
        buf,
        mode,
        '<CR>',
        "<Cmd>lua require('$actionModule').action('$actionPrefix.menu_confirm')<CR>",
      );
      if (bindRightArrowSubmenu) {
        await nvim.bufSetKeymap(
          buf,
          mode,
          '<Right>',
          "<Cmd>lua require('$actionModule').action('$actionPrefix.menu_right')<CR>",
        );
      }
      for (final key in const ['<Esc>', '<C-c>']) {
        await nvim.bufSetKeymap(
          buf,
          mode,
          key,
          "<Cmd>lua require('$actionModule').action('$actionPrefix.menu_close')<CR>",
        );
      }
    }
    await nvim.bufSetKeymap(
      buf,
      'n',
      'q',
      "<Cmd>lua require('$actionModule').action('$actionPrefix.menu_close')<CR>",
    );

    if (onBack != null) {
      for (final backKey in const ['<BS>', '<Left>']) {
        await nvim.bufSetKeymap(
          buf,
          'n',
          backKey,
          "<Cmd>lua require('$actionModule').action('$actionPrefix.menu_back')<CR>",
        );
      }
    }

    for (var i = 0; i < items.length; i++) {
      final key = items[i].shortcut;
      if (key.isEmpty ||
          key == '▸' ||
          key == '<CR>' ||
          key == 'q' ||
          key == '<Esc>' ||
          key == '<C-c>') {
        continue;
      }
      await nvim.bufSetKeymap(
        buf,
        'n',
        key,
        "<Cmd>lua require('$actionModule').action('$actionPrefix.menu_select:$i')<CR>",
      );
    }

    for (final entry in extraMnemonics.entries) {
      await nvim.bufSetKeymap(
        buf,
        'n',
        entry.key,
        "<Cmd>lua require('$actionModule').action('$actionPrefix.menu_select:${entry.value}')<CR>",
      );
    }

    if (bindRightArrowSubmenu && !extraMnemonics.containsKey('l') && onBack == null) {
      final hasLShortcut = items.any((it) => it.shortcut == 'l');
      if (!hasLShortcut) {
        await nvim.bufSetKeymap(
          buf,
          'n',
          'l',
          "<Cmd>lua require('$actionModule').action('$actionPrefix.menu_right')<CR>",
        );
      }
    }

    try {
      await nvim.execLua(
        '''
local buf = ...
local grp = vim.api.nvim_create_augroup('$augroupName', { clear = true })
vim.api.nvim_create_autocmd({ 'WinLeave', 'BufLeave' }, {
  group = grp,
  buffer = buf,
  once = true,
  callback = function()
    vim.schedule(function()
      require('$actionModule').action('$actionPrefix.menu_close', buf)
    end)
  end,
})
''',
        [buf],
      );
    } catch (_) {}
  }

  Future<void> handleClick({MousePosition? mousePos}) async {
    final win = _win;
    if (win == null || !await nvim.winIsValid(win)) {
      await close();
      return;
    }
    final resolvedMouse = mousePos ?? await nvim.getMousePos();
    if (resolvedMouse != null) {
      if (resolvedMouse.winId != win) {
        if (cancelOnOutsideClick) {
          await cancel();
        } else {
          await close();
        }
        return;
      }
      if (resolvedMouse.line >= 1 && resolvedMouse.line <= _items.length) {
        await selectIndex(resolvedMouse.line - 1);
        return;
      }
    }
    await confirm();
  }

  Future<void> handleRightKey() async {
    final win = _win;
    if (win == null || !await nvim.winIsValid(win)) return;
    final (row, _) = await nvim.winGetCursor(win);
    final idx = row - 1;
    if (idx >= 0 && idx < _items.length && _items[idx].isSubmenu) {
      await selectIndex(idx);
    }
  }

  Future<void> handleBack() async {
    final callback = _onBack;
    if (callback != null) {
      await close();
      await callback();
    } else {
      await cancel();
    }
  }

  Future<void> confirm() async {
    final win = _win;
    if (win == null || !await nvim.winIsValid(win)) {
      await close();
      return;
    }
    final (row, _) = await nvim.winGetCursor(win);
    await selectIndex(row - 1);
  }

  Future<void> selectIndex(int index) async {
    final items = _items;
    await close();
    if (index >= 0 && index < items.length) {
      await items[index].onSelect();
    }
  }

  /// Dismisses the context menu, optionally guarding against stale
  /// `WinLeave`/`BufLeave` notifications via [expectedBufId].
  Future<void> cancel({int? expectedBufId}) async {
    if (expectedBufId != null && _buf != expectedBufId) {
      return;
    }
    final win = _win;
    if (win == null) return;
    final callback = _onCancel;
    var wasFocused = false;
    try {
      wasFocused = (await nvim.getCurrentWin()) == win;
    } catch (_) {}
    await close();
    if (wasFocused && callback != null) {
      await callback();
    }
  }

  Future<void> close() async {
    nvim.clearOverlayCloser(close);
    final win = _win;
    final buf = _buf;
    _win = null;
    _buf = null;
    _items = const [];
    _onBack = null;
    _onCancel = null;
    if (buf != null) {
      try {
        await nvim.execLua(
          "pcall(vim.api.nvim_del_augroup_by_name, '$augroupName')",
        );
      } catch (_) {}
    }
    if (win != null) {
      try {
        if (await nvim.winIsValid(win)) {
          await nvim.winClose(win, force: true);
        }
      } catch (_) {}
    }
  }
}
