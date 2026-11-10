import 'nvim_client.dart';

/// Base item model for [NvimContextMenu].
class NvimContextMenuItem {
  final String label;
  final String? displayLabel;
  final String shortcut;
  final bool isSubmenu;
  final Future<void> Function() onSelect;

  const NvimContextMenuItem({
    required this.label,
    this.displayLabel,
    this.shortcut = '',
    this.isSubmenu = false,
    required this.onSelect,
  });

  String get effectiveDisplayLabel => displayLabel ?? label;
}

/// Represents a row in [NvimContextMenu] containing one or more [NvimContextMenuItem]s.
class NvimContextMenuRow<T extends NvimContextMenuItem> {
  final List<T> items;
  final String? prefix;

  const NvimContextMenuRow(this.items, {this.prefix});

  factory NvimContextMenuRow.single(T item) => NvimContextMenuRow([item]);
}

class _ItemSpan<T extends NvimContextMenuItem> {
  final T item;
  final int itemIndex;
  final int startCol;
  final int endCol;
  final int focusCol;

  const _ItemSpan({
    required this.item,
    required this.itemIndex,
    required this.startCol,
    required this.endCol,
    required this.focusCol,
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
  List<NvimContextMenuRow<T>> _rows = const [];
  List<T> _items = const [];
  final List<List<_ItemSpan<T>>> _rowSpans = [];
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
  List<NvimContextMenuRow<T>> get rows => List.unmodifiable(_rows);
  List<T> get items => List.unmodifiable(_items);
  int get lastRow => _lastRow;
  int get lastCol => _lastCol;

  int rowIndexWhere(bool Function(T item) test) {
    for (var r = 0; r < _rows.length; r++) {
      if (_rows[r].items.any(test)) {
        return r;
      }
    }
    return -1;
  }

  int rowIndexOf(T item) =>
      rowIndexWhere((it) => identical(it, item) || it == item);

  Future<void> openMenu({
    List<T>? items,
    List<NvimContextMenuRow<T>>? rows,
    String title = 'Actions',
    int? anchorWin,
    int? row,
    int? col,
    int minWidth = 22,
    int maxWidth = 64,
    int padding = 4,
    bool clampToEditor = false,
    bool bindRightArrowSubmenu = false,
    Map<String, int> extraMnemonics = const {},
    Future<void> Function()? onBack,
    Future<void> Function()? onCancel,
  }) async {
    await nvim.activateOverlay(close);
    await close();

    final resolvedRows = rows ??
        (items != null
            ? items.map((it) => NvimContextMenuRow.single(it)).toList()
            : <NvimContextMenuRow<T>>[]);
    if (resolvedRows.isEmpty || resolvedRows.every((r) => r.items.isEmpty)) {
      return;
    }

    nvim.setOverlayCloser(close);
    _rows = resolvedRows;
    _items = resolvedRows.expand((r) => r.items).toList();
    _onBack = onBack;
    _onCancel = onCancel;
    _rowSpans.clear();

    final buf = await nvim.createBuf(listed: false, scratch: true);
    _buf = buf;

    var maxContentLen = 0;
    final rowRenderData = <({
      String content,
      List<({T item, int itemIndex, int focusCol, int textLen})> items,
    })>[];

    var globalItemIndex = 0;
    for (final rowEntry in resolvedRows) {
      final prefix = rowEntry.prefix ?? '';
      if (rowEntry.items.length == 1) {
        final item = rowEntry.items.first;
        final labelLen = item.label.runes.length;
        final shortcutLen = item.shortcut.runes.length;
        final totalLen = labelLen +
            (shortcutLen > 0 ? shortcutLen + 2 : 0) +
            prefix.runes.length;
        if (totalLen > maxContentLen) {
          maxContentLen = totalLen;
        }
        rowRenderData.add((
          content: '',
          items: [
            (
              item: item,
              itemIndex: globalItemIndex++,
              focusCol: 1 + prefix.runes.length,
              textLen: labelLen,
            )
          ],
        ));
      } else {
        final itemInfos = <({T item, int itemIndex, int focusCol, int textLen})>[];
        final parts = <String>[];
        var colTracker = 1 + prefix.runes.length;
        for (var i = 0; i < rowEntry.items.length; i++) {
          final item = rowEntry.items[i];
          final text = item.shortcut.isNotEmpty
              ? '${item.effectiveDisplayLabel} (${item.shortcut})'
              : item.effectiveDisplayLabel;
          itemInfos.add((
            item: item,
            itemIndex: globalItemIndex++,
            focusCol: colTracker,
            textLen: text.runes.length,
          ));
          parts.add(text);
          colTracker += text.runes.length + 3;
        }
        final rowContent = '$prefix${parts.join(' │ ')}';
        if (rowContent.runes.length > maxContentLen) {
          maxContentLen = rowContent.runes.length;
        }
        rowRenderData.add((
          content: rowContent,
          items: itemInfos,
        ));
      }
    }

    final innerWidth =
        (maxContentLen + padding).clamp(minWidth, maxWidth);
    final lines = <String>[];

    for (var r = 0; r < resolvedRows.length; r++) {
      final rowEntry = resolvedRows[r];
      final renderData = rowRenderData[r];
      final prefix = rowEntry.prefix ?? '';
      final spans = <_ItemSpan<T>>[];

      if (rowEntry.items.length == 1) {
        final itemInfo = renderData.items.first;
        final item = itemInfo.item;
        final label = '$prefix${item.label}';
        final labelLen = label.runes.length;
        final shortcutLen = item.shortcut.runes.length;
        if (shortcutLen == 0) {
          final padCount = (innerWidth - 2 - labelLen).clamp(0, innerWidth);
          lines.add(' $label${' ' * padCount} ');
        } else {
          final padCount =
              (innerWidth - 2 - labelLen - shortcutLen).clamp(1, innerWidth);
          lines.add(' $label${' ' * padCount}${item.shortcut} ');
        }
        spans.add(_ItemSpan(
          item: item,
          itemIndex: itemInfo.itemIndex,
          startCol: 0,
          endCol: innerWidth,
          focusCol: 1 + prefix.runes.length,
        ));
      } else {
        final rowContent = renderData.content;
        final padCount =
            (innerWidth - 2 - rowContent.runes.length).clamp(0, innerWidth);
        lines.add(' $rowContent${' ' * padCount} ');

        final count = renderData.items.length;
        for (var i = 0; i < count; i++) {
          final info = renderData.items[i];
          final startCol = i == 0 ? 0 : spans[i - 1].endCol;
          final endCol =
              i == count - 1 ? innerWidth : info.focusCol + info.textLen + 1;
          spans.add(_ItemSpan(
            item: info.item,
            itemIndex: info.itemIndex,
            startCol: startCol,
            endCol: endCol,
            focusCol: info.focusCol,
          ));
        }
      }
      _rowSpans.add(spans);
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
      await nvim.bufSetKeymap(
        buf,
        mode,
        '<Tab>',
        "<Cmd>lua require('$actionModule').action('$actionPrefix.menu_tab')<CR>",
      );
      await nvim.bufSetKeymap(
        buf,
        mode,
        '<S-Tab>',
        "<Cmd>lua require('$actionModule').action('$actionPrefix.menu_stab')<CR>",
      );
      await nvim.bufSetKeymap(
        buf,
        mode,
        '<Left>',
        "<Cmd>lua require('$actionModule').action('$actionPrefix.menu_left')<CR>",
      );
      if (bindRightArrowSubmenu) {
        await nvim.bufSetKeymap(
          buf,
          mode,
          '<Right>',
          "<Cmd>lua require('$actionModule').action('$actionPrefix.menu_right')<CR>",
        );
      } else {
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

    for (var i = 0; i < _items.length; i++) {
      final key = _items[i].shortcut;
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

    final hasHShortcut = _items.any((it) => it.shortcut == 'h');
    if (!hasHShortcut && onBack == null) {
      await nvim.bufSetKeymap(
        buf,
        'n',
        'h',
        "<Cmd>lua require('$actionModule').action('$actionPrefix.menu_left')<CR>",
      );
    }

    final hasLShortcut = _items.any((it) => it.shortcut == 'l');
    if (!extraMnemonics.containsKey('l') && onBack == null && !hasLShortcut) {
      await nvim.bufSetKeymap(
        buf,
        'n',
        'l',
        "<Cmd>lua require('$actionModule').action('$actionPrefix.menu_right')<CR>",
      );
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
      final rowIndex = resolvedMouse.line - 1;
      if (rowIndex >= 0 && rowIndex < _rowSpans.length) {
        final spans = _rowSpans[rowIndex];
        if (spans.isNotEmpty) {
          final colVal = resolvedMouse.winCol > 0
              ? resolvedMouse.winCol - 1
              : resolvedMouse.column;
          final targetSpan = spans.firstWhere(
            (s) => colVal >= s.startCol && colVal < s.endCol,
            orElse: () =>
                colVal >= spans.last.endCol ? spans.last : spans.first,
          );
          await selectIndex(targetSpan.itemIndex);
          return;
        }
      }
    }
    await confirm();
  }

  Future<void> handleTab(bool forward) async {
    final win = _win;
    if (win == null || !await nvim.winIsValid(win) || _rowSpans.isEmpty) return;
    final (row, col) = await nvim.winGetCursor(win);
    final rowIndex = (row - 1).clamp(0, _rowSpans.length - 1);
    final spans = _rowSpans[rowIndex];
    var curIdx = spans.indexWhere((s) => col >= s.startCol && col < s.endCol);
    if (curIdx < 0) curIdx = 0;

    if (forward) {
      if (curIdx < spans.length - 1) {
        await nvim.winSetCursor(win, row, spans[curIdx + 1].focusCol);
      } else {
        final nextRow = (rowIndex + 1) % _rowSpans.length;
        await nvim.winSetCursor(
          win,
          nextRow + 1,
          _rowSpans[nextRow].first.focusCol,
        );
      }
    } else {
      if (curIdx > 0) {
        await nvim.winSetCursor(win, row, spans[curIdx - 1].focusCol);
      } else {
        final prevRow =
            (rowIndex - 1 + _rowSpans.length) % _rowSpans.length;
        await nvim.winSetCursor(
          win,
          prevRow + 1,
          _rowSpans[prevRow].last.focusCol,
        );
      }
    }
  }

  Future<void> handleHorizontalNav(bool right) async {
    final win = _win;
    if (win == null || !await nvim.winIsValid(win) || _rowSpans.isEmpty) return;
    final (row, col) = await nvim.winGetCursor(win);
    final rowIndex = (row - 1).clamp(0, _rowSpans.length - 1);
    final spans = _rowSpans[rowIndex];
    if (spans.length <= 1) return;
    var curIdx = spans.indexWhere((s) => col >= s.startCol && col < s.endCol);
    if (curIdx < 0) curIdx = 0;

    if (right) {
      if (curIdx < spans.length - 1) {
        await nvim.winSetCursor(win, row, spans[curIdx + 1].focusCol);
      }
    } else {
      if (curIdx > 0) {
        await nvim.winSetCursor(win, row, spans[curIdx - 1].focusCol);
      }
    }
  }

  Future<void> handleRightKey() async {
    final win = _win;
    if (win == null || !await nvim.winIsValid(win)) return;
    final (row, col) = await nvim.winGetCursor(win);
    final rowIndex = row - 1;
    if (rowIndex >= 0 && rowIndex < _rowSpans.length) {
      final spans = _rowSpans[rowIndex];
      final targetSpan = spans.firstWhere(
        (s) => col >= s.startCol && col < s.endCol,
        orElse: () => spans.first,
      );
      if (targetSpan.item.isSubmenu) {
        await selectIndex(targetSpan.itemIndex);
        return;
      }
      if (spans.length > 1) {
        await handleHorizontalNav(true);
        return;
      }
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
    final (row, col) = await nvim.winGetCursor(win);
    final rowIndex = row - 1;
    if (rowIndex >= 0 && rowIndex < _rowSpans.length) {
      final spans = _rowSpans[rowIndex];
      if (spans.isNotEmpty) {
        final targetSpan = spans.firstWhere(
          (s) => col >= s.startCol && col < s.endCol,
          orElse: () =>
              col >= spans.last.endCol ? spans.last : spans.first,
        );
        await selectIndex(targetSpan.itemIndex);
        return;
      }
    }
    await close();
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
    _rows = const [];
    _items = const [];
    _rowSpans.clear();
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
