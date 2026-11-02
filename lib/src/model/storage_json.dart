import 'dart:convert';
import 'dart:typed_data';

import 'application_contract.dart';

void checkStorageLimit(String file, String measure, int value, int limit) {
  if (value > limit) {
    throw FormatException('$file: $value $measure exceeds $limit');
  }
}

/// Counts JSON structure before decoding; syntax remains the SDK decoder's job.
void checkStorageJson(String file, List<int> bytes, int limit) {
  checkStorageLimit(file, 'bytes', bytes.length, limit);
  var depth = 0;
  var nodes = 0;
  var quoted = false;
  var escaped = false;
  var atom = false;
  for (final byte in bytes) {
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (byte == 92) {
        escaped = true;
      } else if (byte == 34) {
        quoted = false;
      }
      continue;
    }
    switch (byte) {
      case 34:
        quoted = true;
        atom = false;
        nodes++;
      case 123 || 91:
        depth++;
        nodes++;
        atom = false;
        checkStorageLimit(
          file,
          'JSON depth',
          depth,
          ApplicationContract.backupJsonDepth,
        );
      case 125 || 93:
        depth--;
        atom = false;
      case 32 || 9 || 10 || 13 || 44 || 58:
        atom = false;
      default:
        if (!atom) nodes++;
        atom = true;
    }
    checkStorageLimit(
      file,
      'JSON nodes',
      nodes,
      ApplicationContract.backupJsonNodes,
    );
  }
}

Uint8List encodeStorageJson(String file, Object value, int limit) {
  final output = _StorageBytes(file, limit);
  JsonUtf8Encoder().startChunkedConversion(output)
    ..add(value)
    ..close();
  final bytes = output.bytes.takeBytes();
  checkStorageJson(file, bytes, limit);
  return bytes;
}

/// 未编辑字段沿用原 JSON，包括未知字段、缺省与显式 null。
Map<String, Object?> preserveStorageJsonFields(
  Map<String, Object?>? original,
  Set<String> edited,
  Map<String, Object?> current,
) => original == null
    ? current
    : {...original, for (final field in edited) field: current[field]};

class _StorageBytes implements Sink<List<int>> {
  _StorageBytes(this.file, this.limit);
  final String file;
  final int limit;
  final bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> data) {
    checkStorageLimit(file, 'bytes', bytes.length + data.length, limit);
    bytes.add(data);
  }

  @override
  void close() {}
}
