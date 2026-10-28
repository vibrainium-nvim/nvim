import 'dart:convert';
import 'dart:typed_data';

/// Represents a MessagePack extension type (used by Neovim for Buffer=0, Window=1, Tabpage=2).
class MsgpackExt {
  final int type;
  final Uint8List data;

  const MsgpackExt(this.type, this.data);

  /// Decodes the payload as an integer handle (Neovim encodes handles as msgpack integers inside ext data, or raw bytes).
  int toHandle() {
    if (data.isEmpty) return 0;
    final decoded = MsgpackCodec.decode(data);
    if (decoded is int) return decoded;
    var value = 0;
    for (final byte in data) {
      value = (value << 8) | byte;
    }
    return value;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! MsgpackExt || other.type != type || other.data.length != data.length) {
      return false;
    }
    for (var i = 0; i < data.length; i++) {
      if (other.data[i] != data[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(type, Object.hashAll(data));

  @override
  String toString() => 'MsgpackExt(type: $type, len: ${data.length})';
}

/// Pure-Dart MessagePack encoder and decoder.
class MsgpackCodec {
  static Uint8List encode(Object? value) {
    final builder = BytesBuilder(copy: false);
    _encodeValue(builder, value);
    return builder.takeBytes();
  }

  static Object? decode(Uint8List bytes) {
    final reader = _MsgpackReader(bytes, 0);
    return reader.readValue();
  }

  static void _encodeValue(BytesBuilder builder, Object? value) {
    if (value == null) {
      builder.addByte(0xc0);
    } else if (value is bool) {
      builder.addByte(value ? 0xc3 : 0xc2);
    } else if (value is int) {
      _encodeInt(builder, value);
    } else if (value is double) {
      final bd = ByteData(9);
      bd.setUint8(0, 0xcb);
      bd.setFloat64(1, value, Endian.big);
      builder.add(bd.buffer.asUint8List());
    } else if (value is String) {
      final utf8Bytes = utf8.encode(value);
      final len = utf8Bytes.length;
      if (len <= 31) {
        builder.addByte(0xa0 | len);
      } else if (len <= 0xff) {
        builder.addByte(0xd9);
        builder.addByte(len);
      } else if (len <= 0xffff) {
        final bd = ByteData(3);
        bd.setUint8(0, 0xda);
        bd.setUint16(1, len, Endian.big);
        builder.add(bd.buffer.asUint8List());
      } else {
        final bd = ByteData(5);
        bd.setUint8(0, 0xdb);
        bd.setUint32(1, len, Endian.big);
        builder.add(bd.buffer.asUint8List());
      }
      builder.add(utf8Bytes);
    } else if (value is Uint8List) {
      final len = value.length;
      if (len <= 0xff) {
        builder.addByte(0xc4);
        builder.addByte(len);
      } else if (len <= 0xffff) {
        final bd = ByteData(3);
        bd.setUint8(0, 0xc5);
        bd.setUint16(1, len, Endian.big);
        builder.add(bd.buffer.asUint8List());
      } else {
        final bd = ByteData(5);
        bd.setUint8(0, 0xc6);
        bd.setUint32(1, len, Endian.big);
        builder.add(bd.buffer.asUint8List());
      }
      builder.add(value);
    } else if (value is List) {
      final len = value.length;
      if (len <= 15) {
        builder.addByte(0x90 | len);
      } else if (len <= 0xffff) {
        final bd = ByteData(3);
        bd.setUint8(0, 0xdc);
        bd.setUint16(1, len, Endian.big);
        builder.add(bd.buffer.asUint8List());
      } else {
        final bd = ByteData(5);
        bd.setUint8(0, 0xdd);
        bd.setUint32(1, len, Endian.big);
        builder.add(bd.buffer.asUint8List());
      }
      for (final item in value) {
        _encodeValue(builder, item);
      }
    } else if (value is Map) {
      final len = value.length;
      if (len <= 15) {
        builder.addByte(0x80 | len);
      } else if (len <= 0xffff) {
        final bd = ByteData(3);
        bd.setUint8(0, 0xde);
        bd.setUint16(1, len, Endian.big);
        builder.add(bd.buffer.asUint8List());
      } else {
        final bd = ByteData(5);
        bd.setUint8(0, 0xdf);
        bd.setUint32(1, len, Endian.big);
        builder.add(bd.buffer.asUint8List());
      }
      value.forEach((k, v) {
        _encodeValue(builder, k);
        _encodeValue(builder, v);
      });
    } else if (value is MsgpackExt) {
      _encodeExt(builder, value);
    } else {
      throw ArgumentError('Unsupported type for Msgpack encoding: ${value.runtimeType}');
    }
  }

  static void _encodeInt(BytesBuilder builder, int value) {
    if (value >= 0) {
      if (value <= 0x7f) {
        builder.addByte(value);
      } else if (value <= 0xff) {
        builder.addByte(0xcc);
        builder.addByte(value);
      } else if (value <= 0xffff) {
        final bd = ByteData(3);
        bd.setUint8(0, 0xcd);
        bd.setUint16(1, value, Endian.big);
        builder.add(bd.buffer.asUint8List());
      } else if (value <= 0xffffffff) {
        final bd = ByteData(5);
        bd.setUint8(0, 0xce);
        bd.setUint32(1, value, Endian.big);
        builder.add(bd.buffer.asUint8List());
      } else {
        final bd = ByteData(9);
        bd.setUint8(0, 0xcf);
        bd.setInt64(1, value, Endian.big);
        builder.add(bd.buffer.asUint8List());
      }
    } else {
      if (value >= -32) {
        builder.addByte(value & 0xff);
      } else if (value >= -128) {
        builder.addByte(0xd0);
        builder.addByte(value & 0xff);
      } else if (value >= -32768) {
        final bd = ByteData(3);
        bd.setUint8(0, 0xd1);
        bd.setInt16(1, value, Endian.big);
        builder.add(bd.buffer.asUint8List());
      } else if (value >= -2147483648) {
        final bd = ByteData(5);
        bd.setUint8(0, 0xd2);
        bd.setInt32(1, value, Endian.big);
        builder.add(bd.buffer.asUint8List());
      } else {
        final bd = ByteData(9);
        bd.setUint8(0, 0xd3);
        bd.setInt64(1, value, Endian.big);
        builder.add(bd.buffer.asUint8List());
      }
    }
  }

  static void _encodeExt(BytesBuilder builder, MsgpackExt ext) {
    final len = ext.data.length;
    final typeByte = ext.type & 0xff;
    if (len == 1) {
      builder.addByte(0xd4);
      builder.addByte(typeByte);
    } else if (len == 2) {
      builder.addByte(0xd5);
      builder.addByte(typeByte);
    } else if (len == 4) {
      builder.addByte(0xd6);
      builder.addByte(typeByte);
    } else if (len == 8) {
      builder.addByte(0xd7);
      builder.addByte(typeByte);
    } else if (len == 16) {
      builder.addByte(0xd8);
      builder.addByte(typeByte);
    } else if (len <= 0xff) {
      builder.addByte(0xc7);
      builder.addByte(len);
      builder.addByte(typeByte);
    } else if (len <= 0xffff) {
      final bd = ByteData(4);
      bd.setUint8(0, 0xc8);
      bd.setUint16(1, len, Endian.big);
      bd.setUint8(3, typeByte);
      builder.add(bd.buffer.asUint8List());
    } else {
      final bd = ByteData(6);
      bd.setUint8(0, 0xc9);
      bd.setUint32(1, len, Endian.big);
      bd.setUint8(5, typeByte);
      builder.add(bd.buffer.asUint8List());
    }
    builder.add(ext.data);
  }
}

/// Incremental stream decoder that buffers incoming bytes and emits complete MessagePack values.
class MsgpackStreamDecoder {
  Uint8List _buffer = Uint8List(0);

  List<Object?> addChunk(List<int> chunk) {
    if (chunk.isEmpty) return const [];
    if (_buffer.isEmpty) {
      _buffer = chunk is Uint8List ? Uint8List.fromList(chunk) : Uint8List.fromList(chunk);
    } else {
      final merged = Uint8List(_buffer.length + chunk.length);
      merged.setRange(0, _buffer.length, _buffer);
      merged.setRange(_buffer.length, merged.length, chunk);
      _buffer = merged;
    }

    final results = <Object?>[];
    var offset = 0;
    while (offset < _buffer.length) {
      final reader = _MsgpackReader(_buffer, offset);
      try {
        final val = reader.readValue();
        results.add(val);
        offset = reader.offset;
      } on _IncompleteMsgpackException {
        break;
      }
    }

    if (offset > 0) {
      _buffer = Uint8List.sublistView(_buffer, offset);
    }
    return results;
  }
}

class _IncompleteMsgpackException implements Exception {
  const _IncompleteMsgpackException();
}

class _MsgpackReader {
  final Uint8List bytes;
  final ByteData _bd;
  int offset;

  _MsgpackReader(this.bytes, this.offset)
      : _bd = ByteData.sublistView(bytes);

  void _require(int count) {
    if (offset + count > bytes.length) {
      throw const _IncompleteMsgpackException();
    }
  }

  Object? readValue() {
    _require(1);
    final b = bytes[offset++];

    // Positive fixint: 0x00 - 0x7f
    if (b <= 0x7f) return b;

    // Fixmap: 0x80 - 0x8f
    if (b >= 0x80 && b <= 0x8f) {
      return _readMap(b & 0x0f);
    }

    // Fixarray: 0x90 - 0x9f
    if (b >= 0x90 && b <= 0x9f) {
      return _readArray(b & 0x0f);
    }

    // Fixstr: 0xa0 - 0xbf
    if (b >= 0xa0 && b <= 0xbf) {
      return _readString(b & 0x1f);
    }

    // Negative fixint: 0xe0 - 0xff
    if (b >= 0xe0) {
      return b - 256;
    }

    switch (b) {
      case 0xc0:
        return null;
      case 0xc2:
        return false;
      case 0xc3:
        return true;
      case 0xc4:
        _require(1);
        final len = bytes[offset++];
        return _readBin(len);
      case 0xc5:
        _require(2);
        final len = _bd.getUint16(offset, Endian.big);
        offset += 2;
        return _readBin(len);
      case 0xc6:
        _require(4);
        final len = _bd.getUint32(offset, Endian.big);
        offset += 4;
        return _readBin(len);
      case 0xc7:
        _require(2);
        final len = bytes[offset++];
        final type = _bd.getInt8(offset++);
        return _readExt(type, len);
      case 0xc8:
        _require(3);
        final len = _bd.getUint16(offset, Endian.big);
        offset += 2;
        final type = _bd.getInt8(offset++);
        return _readExt(type, len);
      case 0xc9:
        _require(5);
        final len = _bd.getUint32(offset, Endian.big);
        offset += 4;
        final type = _bd.getInt8(offset++);
        return _readExt(type, len);
      case 0xca:
        _require(4);
        final val = _bd.getFloat32(offset, Endian.big);
        offset += 4;
        return val;
      case 0xcb:
        _require(8);
        final val = _bd.getFloat64(offset, Endian.big);
        offset += 8;
        return val;
      case 0xcc:
        _require(1);
        return bytes[offset++];
      case 0xcd:
        _require(2);
        final val = _bd.getUint16(offset, Endian.big);
        offset += 2;
        return val;
      case 0xce:
        _require(4);
        final val = _bd.getUint32(offset, Endian.big);
        offset += 4;
        return val;
      case 0xcf:
        _require(8);
        final val = _bd.getInt64(offset, Endian.big);
        offset += 8;
        return val;
      case 0xd0:
        _require(1);
        return _bd.getInt8(offset++);
      case 0xd1:
        _require(2);
        final val = _bd.getInt16(offset, Endian.big);
        offset += 2;
        return val;
      case 0xd2:
        _require(4);
        final val = _bd.getInt32(offset, Endian.big);
        offset += 4;
        return val;
      case 0xd3:
        _require(8);
        final val = _bd.getInt64(offset, Endian.big);
        offset += 8;
        return val;
      case 0xd4:
        _require(1);
        final type = _bd.getInt8(offset++);
        return _readExt(type, 1);
      case 0xd5:
        _require(1);
        final type = _bd.getInt8(offset++);
        return _readExt(type, 2);
      case 0xd6:
        _require(1);
        final type = _bd.getInt8(offset++);
        return _readExt(type, 4);
      case 0xd7:
        _require(1);
        final type = _bd.getInt8(offset++);
        return _readExt(type, 8);
      case 0xd8:
        _require(1);
        final type = _bd.getInt8(offset++);
        return _readExt(type, 16);
      case 0xd9:
        _require(1);
        final len = bytes[offset++];
        return _readString(len);
      case 0xda:
        _require(2);
        final len = _bd.getUint16(offset, Endian.big);
        offset += 2;
        return _readString(len);
      case 0xdb:
        _require(4);
        final len = _bd.getUint32(offset, Endian.big);
        offset += 4;
        return _readString(len);
      case 0xdc:
        _require(2);
        final len = _bd.getUint16(offset, Endian.big);
        offset += 2;
        return _readArray(len);
      case 0xdd:
        _require(4);
        final len = _bd.getUint32(offset, Endian.big);
        offset += 4;
        return _readArray(len);
      case 0xde:
        _require(2);
        final len = _bd.getUint16(offset, Endian.big);
        offset += 2;
        return _readMap(len);
      case 0xdf:
        _require(4);
        final len = _bd.getUint32(offset, Endian.big);
        offset += 4;
        return _readMap(len);
      default:
        throw FormatException('Invalid MessagePack byte: 0x${b.toRadixString(16)}');
    }
  }

  String _readString(int length) {
    _require(length);
    final slice = Uint8List.sublistView(bytes, offset, offset + length);
    offset += length;
    return utf8.decode(slice, allowMalformed: true);
  }

  Uint8List _readBin(int length) {
    _require(length);
    final slice = Uint8List.fromList(Uint8List.sublistView(bytes, offset, offset + length));
    offset += length;
    return slice;
  }

  MsgpackExt _readExt(int type, int length) {
    _require(length);
    final slice = Uint8List.fromList(Uint8List.sublistView(bytes, offset, offset + length));
    offset += length;
    return MsgpackExt(type, slice);
  }

  List<Object?> _readArray(int length) {
    final list = List<Object?>.filled(length, null, growable: true);
    for (var i = 0; i < length; i++) {
      list[i] = readValue();
    }
    return list;
  }

  Map<Object?, Object?> _readMap(int length) {
    final map = <Object?, Object?>{};
    for (var i = 0; i < length; i++) {
      final k = readValue();
      final v = readValue();
      map[k] = v;
    }
    return map;
  }
}
