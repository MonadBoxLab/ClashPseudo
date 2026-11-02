import 'dart:io';

import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/logic/overrides/override_store.dart';

class ReadOnlyOverrideStore extends OverrideStore {
  ReadOnlyOverrideStore() : super(Directory.systemTemp);
  List<OverrideEntry> entries = [];
  @override
  Future<List<OverrideEntry>> read() async => List.unmodifiable(entries);

  @override
  Future<void> save(List<OverrideEntry> entries) async {
    throw UnsupportedError('ReadOnlyOverrideStore must not save');
  }

  @override
  Future<void> clear() async {
    throw UnsupportedError('ReadOnlyOverrideStore must not clear');
  }
}
