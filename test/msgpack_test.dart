import 'dart:typed_data';
import 'package:nvim/nvim.dart';
import 'package:test/test.dart';

void main() {
  group('MsgpackCodec', () {
    test('encodes and decodes primitives, collections, and Ext types', () {
      final ext = MsgpackExt(1, MsgpackCodec.encode(42));
      final payload = [
        null,
        true,
        false,
        0,
        127,
        255,
        65535,
        -1,
        -32,
        -128,
        -32768,
        3.14159,
        'hello nvim',
        'a' * 300,
        Uint8List.fromList([1, 2, 3, 4]),
        {'key': 'value', 'nested': [1, 2, 3]},
        ext,
      ];

      final bytes = MsgpackCodec.encode(payload);
      final decoded = MsgpackCodec.decode(bytes) as List;

      expect(decoded[0], isNull);
      expect(decoded[1], isTrue);
      expect(decoded[2], isFalse);
      expect(decoded[3], 0);
      expect(decoded[4], 127);
      expect(decoded[5], 255);
      expect(decoded[6], 65535);
      expect(decoded[7], -1);
      expect(decoded[8], -32);
      expect(decoded[9], -128);
      expect(decoded[10], -32768);
      expect((decoded[11] as double), closeTo(3.14159, 1e-6));
      expect(decoded[12], 'hello nvim');
      expect(decoded[13], 'a' * 300);
      expect(decoded[14], Uint8List.fromList([1, 2, 3, 4]));
      expect(decoded[15], {'key': 'value', 'nested': [1, 2, 3]});
      final decodedExt = decoded[16] as MsgpackExt;
      expect(decodedExt, ext);
      expect(decodedExt.toHandle(), 42);
    });

    test('MsgpackStreamDecoder handles fragmented chunks', () {
      final msg1 = MsgpackCodec.encode([0, 1, 'nvim_get_current_win', <Object?>[]]);
      final msg2 = MsgpackCodec.encode([2, 'viff_action', ['toggle']]);
      final combined = Uint8List.fromList([...msg1, ...msg2]);

      final decoder = MsgpackStreamDecoder();
      final part1 = decoder.addChunk(combined.sublist(0, 5));
      expect(part1, isEmpty);

      final part2 = decoder.addChunk(combined.sublist(5));
      expect(part2, hasLength(2));
      expect(part2[0], [0, 1, 'nvim_get_current_win', <Object?>[]]);
      expect(part2[1], [2, 'viff_action', ['toggle']]);
    });
  });
}
