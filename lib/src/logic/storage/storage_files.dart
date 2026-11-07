import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../model/storage_json.dart';

// Android/Linux ENOENT only; permission and other I/O failures are not defaults.
bool isMissingStorageFile(Object error) =>
    error is FileSystemException && error.osError?.errorCode == 2;

Future<Object?> readStorageJson(File file, int limit) async {
  checkStorageLimit(file.path, 'bytes', await file.length(), limit);
  final bytes = BytesBuilder(copy: false);
  await for (final part in file.openRead()) {
    checkStorageLimit(file.path, 'bytes', bytes.length + part.length, limit);
    bytes.add(part);
  }
  final value = bytes.takeBytes();
  checkStorageJson(file.path, value, limit);
  return jsonDecode(utf8.decode(value));
}

/// Temporary file cleanup failures must not replace the original write or publication
/// error.
Future<void> cleanupStorageTemporary(File file, {Object? cause}) async {
  try {
    if (await file.exists()) await file.delete();
  } catch (cleanup) {
    if (cause == null) rethrow;
    throw StorageCleanupFailure(cause, cleanup);
  }
}

class StorageCleanupFailure implements Exception {
  const StorageCleanupFailure(this.cause, this.suppressed);

  final Object cause;
  final Object suppressed;

  @override
  String toString() => '$cause\nSuppressed: $suppressed';
}
