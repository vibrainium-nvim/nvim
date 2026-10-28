import 'package:nvim/nvim.dart';
import 'package:test/test.dart';

void main() {
  group('HotReloader', () {
    test('reload() runs reloadSources on the current isolate', () async {
      final ok = await HotReloader.reload();
      expect(ok, isTrue);
    });
  });
}
