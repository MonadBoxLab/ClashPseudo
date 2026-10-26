import 'dart:io';

import 'package:clash_pseudo/src/features/overrides/override_entry.dart';
import 'package:clash_pseudo/src/features/overrides/override_store.dart';

class ReadOnlyOverrideStore extends OverrideStore {
  ReadOnlyOverrideStore() : super(Directory.systemTemp);
  List<OverrideEntry> entries = [];
  @override
  Future<List<OverrideEntry>> read() async => List.unmodifiable(entries);

  @override
  Future<void> save(List<OverrideEntry> entries) async {
    throw UnsupportedError('ReadOnlyOverrideStore must not save');
  }
}
