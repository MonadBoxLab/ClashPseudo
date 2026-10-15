import 'dart:convert';
import 'dart:io';

import '../features/configs/config_entry.dart';
import '../features/mode/tunnel_mode.dart';

class CoreInput {
  CoreInput(this.file);
  final File file;

  Future<void> write(ConfigEntry entry, TunnelMode mode) async {
    if (entry.body == null) {
      throw const ConfigFailure('该配置没有可用正文，请重新导入更新。');
    }
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(
        jsonEncode({
          'id': entry.id,
          'revision': entry.revision,
          'mode': mode.name,
          'body': entry.body,
          'choices': entry.choices.map(
            (name, choice) => MapEntry(name, choice.toJson()),
          ),
        }),
        flush: true,
      );
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> clear() async {
    if (await file.exists()) await file.delete();
  }
}
