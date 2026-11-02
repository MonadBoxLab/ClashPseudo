import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const lastRevision = 0x7fffffff;
  const config = ConfigEntry(
    id: 'config',
    name: 'Local',
    kind: ConfigKind.local,
    revision: lastRevision,
    body: 'rules: []',
  );
  const override = OverrideEntry(
    id: 'override',
    name: 'Plugin',
    kind: ConfigKind.local,
    revision: lastRevision,
    body: '{}',
  );

  test('the last Android revision round trips without truncation', () {
    expect(ConfigEntry.fromJson(config.toJson()).revision, lastRevision);
    expect(OverrideEntry.fromJson(override.toJson()).revision, lastRevision);
    expect(config.withContent(config.body).revision, lastRevision);
    expect(override.withContent(override.body).revision, lastRevision);
  });

  for (final invalid in [0, -1, 0x80000000, 0x100000001, 1.5, '1']) {
    test('record readers reject nonrepresentable revision $invalid', () {
      expect(
        () => ConfigEntry.fromJson({...config.toJson(), 'revision': invalid}),
        invalid is int ? throwsFormatException : throwsA(isA<TypeError>()),
      );
      expect(
        () =>
            OverrideEntry.fromJson({...override.toJson(), 'revision': invalid}),
        invalid is int ? throwsFormatException : throwsA(isA<TypeError>()),
      );
    });
  }
}
