import 'dart:convert';

import 'package:clash_pseudo/src/features/configs/config_entry.dart';
import 'package:clash_pseudo/src/features/overrides/override_entry.dart';
import 'package:clash_pseudo/src/l10n/messages.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const remote = OverrideEntry(
    id: 'remote',
    name: 'Remote',
    kind: ConfigKind.remote,
    source: 'https://fixture.invalid/loon',
    revision: 1,
    body: '{}',
    proxyName: 'Selected proxy',
    addNoResolve: true,
    enabled: true,
    mode: OverrideMode.replace,
    update: UpdatePolicy(enabled: true, hours: 12),
  );

  test('conversion options round-trip without raw content or format state', () {
    final encoded =
        jsonDecode(jsonEncode(remote.toJson())) as Map<String, dynamic>;
    final restored = OverrideEntry.fromJson(encoded);
    expect(restored.proxyName, 'Selected proxy');
    expect(restored.addNoResolve, isTrue);
    expect(restored.sameDownloadInput(remote), isTrue);
    expect(encoded.keys, isNot(contains('raw')));
    expect(encoded.keys, isNot(contains('format')));
    expect(encoded.keys, isNot(contains('history')));
  });

  test('missing optional conversion fields use their actual defaults', () {
    final input = remote.toJson()
      ..remove('proxyName')
      ..remove('addNoResolve');
    final restored = OverrideEntry.fromJson(input);
    expect(restored.proxyName, '');
    expect(restored.addNoResolve, isFalse);
    expect(restored.role, isNull);
  });

  for (final invalid in [
    {'proxyName': null},
    {'proxyName': 3},
    {'addNoResolve': null},
    {'addNoResolve': 'true'},
    {'addNoResolve': 1},
  ]) {
    test('rejects malformed option types $invalid', () {
      expect(
        () => OverrideEntry.fromJson({...remote.toJson(), ...invalid}),
        throwsFormatException,
      );
    });
  }

  test('every copy retains source conversion options and update policy', () {
    for (final copy in [
      remote.withContent('rules: []'),
      remote.changed(
        name: 'Renamed',
        enabled: false,
        mode: OverrideMode.prepend,
      ),
      remote.changed(error: messages.downloadFailed),
      remote.withUpdate(const UpdatePolicy(enabled: true, hours: 6)),
    ]) {
      expect(copy.proxyName, remote.proxyName);
      expect(copy.addNoResolve, remote.addNoResolve);
      expect(copy.source, remote.source);
    }
    expect(remote.withContent(remote.body).revision, remote.revision);
    expect(remote.withContent('rules: []').revision, remote.revision + 1);
    final changed = remote.changed(proxyName: '', addNoResolve: false);
    expect(changed.proxyName, '');
    expect(changed.addNoResolve, isFalse);
    expect(changed.revision, remote.revision);
  });

  test(
    'download identity includes ID/source/revision and both conversion options',
    () {
      expect(
        remote.sameDownloadInput(remote.changed(name: 'Other', enabled: false)),
        isTrue,
      );
      expect(
        remote.sameDownloadInput(
          remote.withUpdate(const UpdatePolicy(hours: 6)),
        ),
        isTrue,
      );
      for (final changed in [
        remote.changed(source: 'https://other.invalid/part'),
        remote.changed(proxyName: 'New proxy'),
        remote.changed(addNoResolve: false),
        remote.withContent('rules: []'),
        OverrideEntry.fromJson({...remote.toJson(), 'id': 'another'}),
        const OverrideEntry(
          id: 'remote',
          name: 'Local',
          kind: ConfigKind.local,
          revision: 1,
          body: '{}',
        ),
      ]) {
        expect(remote.sameDownloadInput(changed), isFalse);
        expect(changed.sameDownloadInput(remote), isFalse);
      }
    },
  );

  const custom = OverrideEntry(
    id: 'custom-id',
    name: 'Not identified by display name',
    kind: ConfigKind.local,
    role: OverrideRole.localCustom,
    revision: 1,
    body: '{}',
    enabled: false,
    mode: OverrideMode.replace,
  );
  test(
    'local-custom role is explicit and survives every copy and JSON round-trip',
    () {
      for (final entry in [
        custom,
        custom.withContent('rules: []'),
        custom.changed(name: 'Any name'),
        custom.changed(enabled: true, mode: OverrideMode.prepend),
        custom.withUpdate(const UpdatePolicy()),
        OverrideEntry.fromJson(
          jsonDecode(jsonEncode(custom.toJson())) as Map<String, dynamic>,
        ),
      ]) {
        expect(entry.role, OverrideRole.localCustom);
        expect(entry.kind, ConfigKind.local);
      }
      expect(custom.toJson()['role'], 'localCustom');
      expect(
        OverrideEntry.fromJson({...custom.toJson(), 'role': null}).role,
        isNull,
      );
    },
  );

  test('unknown or remotely assigned local-custom role is rejected', () {
    expect(
      () => OverrideEntry.fromJson({...custom.toJson(), 'role': 'unknown'}),
      throwsArgumentError,
    );
    expect(
      () => OverrideEntry.fromJson({...remote.toJson(), 'role': 'localCustom'}),
      throwsFormatException,
    );
  });
}
