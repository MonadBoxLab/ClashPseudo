import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clash_pseudo/src/model/config_entry.dart';
import 'package:clash_pseudo/src/logic/configs/config_store.dart';
import 'package:clash_pseudo/src/model/override_entry.dart';
import 'package:clash_pseudo/src/logic/overrides/override_store.dart';
import 'package:clash_pseudo/src/logic/storage/preferences_store.dart';
import 'package:clash_pseudo/src/logic/storage/storage_files.dart';
import 'package:clash_pseudo/src/model/app_preferences.dart';
import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:flutter_test/flutter_test.dart';

class _CleanupFile implements File {
  _CleanupFile(this.file, this.cleanup, {this.release});

  final File file;
  final Object cleanup;
  final Completer<void>? release;
  final entered = Completer<void>();
  var existsCalls = 0;
  var deleteCalls = 0;

  @override
  String get path => file.path;

  @override
  Future<bool> exists() {
    existsCalls++;
    return file.exists();
  }

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    await file.writeAsBytes(bytes, mode: mode, flush: flush);
    return this;
  }

  @override
  Future<File> rename(String newPath) => file.rename(newPath);

  @override
  Future<File> delete({bool recursive = false}) async {
    deleteCalls++;
    if (!entered.isCompleted) entered.complete();
    await release?.future;
    throw cleanup;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnreadableFile implements File {
  _UnreadableFile(this.path, this.failure);

  @override
  final String path;
  final FileSystemException failure;

  // File.exists() is not proof of ENOENT; SDKs can also return false on EACCES.
  @override
  Future<bool> exists() async => false;

  @override
  Future<int> length() async => throw failure;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pseudo-store-cleanup-');
  });
  tearDown(() => directory.delete(recursive: true));

  for (final configurations in [true, false]) {
    final name = configurations ? 'configurations.json' : 'overrides.json';
    final limit = configurations
        ? ApplicationContract.backupConfigurationsJsonBytes
        : ApplicationContract.backupOverridesJsonBytes;
    final empty = <String, Object?>{
      if (configurations) 'selectedId': null,
      if (configurations) 'mode': null,
      'entries': <Object?>[],
    };

    Future<void> clear({
      Future<void> Function()? beforeWrite,
      Future<void> Function(String)? publish,
    }) => configurations
        ? ConfigStore(
            directory,
            beforeWrite: beforeWrite,
            publish: publish,
          ).clear()
        : OverrideStore(
            directory,
            beforeWrite: beforeWrite,
            publish: publish,
          ).clear();

    for (final oversized in [false, true]) {
      test(
        '$name explicit clear bypasses old corrupt/oversized reads; oversized=$oversized',
        () async {
          final file = File('${directory.path}/$name');
          await file.writeAsString('{broken');
          if (oversized) {
            final opened = await file.open(mode: FileMode.append);
            try {
              await opened.truncate(limit + 1);
            } finally {
              await opened.close();
            }
          }
          var checks = 0;
          await clear(
            beforeWrite: () async {
              checks++;
            },
          );
          expect(checks, 2);
          expect(jsonDecode(await file.readAsString()), empty);
          expect(await File('${file.path}.tmp').exists(), isFalse);
        },
      );
    }

    test(
      '$name explicit clear retires unknown fields from a previously read envelope',
      () async {
        final file = File('${directory.path}/$name');
        await file.writeAsString(
          jsonEncode({
            ...empty,
            'future': {'null': null, 'false': false},
          }),
        );
        if (configurations) {
          final store = ConfigStore(directory);
          await store.read();
          await store.clear();
        } else {
          final store = OverrideStore(directory);
          await store.read();
          await store.clear();
        }
        expect(jsonDecode(await file.readAsString()), empty);
      },
    );

    test(
      '$name failed clear publication keeps old bytes and both cleanup causes',
      () async {
        final file = File('${directory.path}/$name');
        await file.writeAsString('{broken old bytes');
        const original = FileSystemException(
          'actual clear publication failure',
        );
        const suppressed = FileSystemException(
          'actual clear temporary cleanup failure',
        );
        final temporary = _CleanupFile(File('${file.path}.tmp'), suppressed);
        await expectLater(
          IOOverrides.runZoned(
            () => clear(publish: (_) async => throw original),
            createFile: (path) => path == temporary.path ? temporary : file,
          ),
          throwsA(
            isA<StorageCleanupFailure>()
                .having(
                  (error) => error.cause,
                  'cause',
                  isA<ConfigFailure>().having(
                    (error) => error.message.detail,
                    'original publication error',
                    original.toString(),
                  ),
                )
                .having(
                  (error) => error.suppressed,
                  'suppressed cleanup',
                  same(suppressed),
                ),
          ),
        );
        expect(await file.readAsString(), '{broken old bytes');
        expect(temporary.deleteCalls, 1);
      },
    );
  }

  for (final name in [
    'configurations.json',
    'overrides.json',
    'preferences.json',
  ]) {
    Future<void> save({
      bool initial = false,
      Future<void> Function()? beforeWrite,
      Future<void> Function(String)? publish,
    }) => switch (name) {
      'configurations.json' =>
        ConfigStore(directory, beforeWrite: beforeWrite, publish: publish).save(
          ConfigCollection(
            entries: initial
                ? []
                : const [
                    ConfigEntry(
                      id: 'saved',
                      name: 'Saved configuration',
                      kind: ConfigKind.local,
                      revision: 1,
                      body: '﻿# exact\r\nrules: []\r\n',
                    ),
                  ],
            selectedId: initial ? null : 'saved',
          ),
        ),
      'overrides.json' =>
        OverrideStore(
          directory,
          beforeWrite: beforeWrite,
          publish: publish,
        ).save(
          initial
              ? []
              : const [
                  OverrideEntry(
                    id: 'saved',
                    name: 'Saved override',
                    kind: ConfigKind.local,
                    revision: 1,
                    body: 'rules: []',
                  ),
                ],
        ),
      _ =>
        PreferencesStore(
          directory,
          beforeWrite: beforeWrite,
          publish: publish,
        ).save(
          AppPreferences(
            brand: initial ? BrandColor.cinnabar : BrandColor.jade,
          ),
        ),
    };

    Future<Object> read() async => switch (name) {
      'configurations.json' => await ConfigStore(directory).read(),
      'overrides.json' => await OverrideStore(directory).read(),
      _ => await PreferencesStore(directory).read(),
    };

    test('$name defaults only for a missing file and does not write', () async {
      await read();
      expect(await directory.list().isEmpty, isTrue);
    });

    test(
      '$name rejects an existing directory instead of using defaults',
      () async {
        await Directory('${directory.path}/$name').create();
        await expectLater(read(), throwsA(isA<ConfigFailure>()));
        expect(await Directory('${directory.path}/$name').exists(), isTrue);
      },
    );

    test(
      '$name retains permission I/O failure even when exists reports false',
      () async {
        final unreadable = _UnreadableFile(
          '${directory.path}/$name',
          FileSystemException(
            'original read permission failure',
            '${directory.path}/$name',
            const OSError('Permission denied', 13),
          ),
        );
        await expectLater(
          IOOverrides.runZoned(read, createFile: (_) => unreadable),
          throwsA(
            isA<ConfigFailure>().having(
              (error) => error.message.detail,
              'original I/O detail',
              contains('original read permission failure'),
            ),
          ),
        );
        expect(await directory.list().isEmpty, isTrue);
      },
    );

    test('$name rejects malformed UTF-8 without rewriting', () async {
      final file = File('${directory.path}/$name');
      await file.writeAsBytes([0xff]);
      await expectLater(
        read(),
        throwsA(
          isA<ConfigFailure>().having(
            (error) => error.message.detail,
            'original decoding detail',
            contains('FormatException'),
          ),
        ),
      );
      expect(await file.readAsBytes(), [0xff]);
    });

    test('$name keeps the write cause and awaits failed cleanup', () async {
      await save(initial: true);
      final file = File('${directory.path}/$name');
      final original = await file.readAsBytes();
      final cause = StateError('original owner expiry');
      const suppressed = FileSystemException(
        'actual temporary cleanup failure',
      );
      final release = Completer<void>();
      final temporary = _CleanupFile(
        File('${file.path}.tmp'),
        suppressed,
        release: release,
      );
      var checks = 0;
      var finished = false;
      final pending =
          IOOverrides.runZoned(
            () => save(
              beforeWrite: () async {
                if (++checks == 2) throw cause;
              },
            ),
            createFile: (path) => path == temporary.path ? temporary : file,
          ).then<Object?>(
            (_) {
              finished = true;
              return null;
            },
            onError: (Object error) {
              finished = true;
              return error;
            },
          );
      try {
        await temporary.entered.future;
        expect(finished, isFalse);
        expect(await file.readAsBytes(), original);
        release.complete();
        final error = await pending;
        expect(error, isA<StorageCleanupFailure>());
        final failure = error! as StorageCleanupFailure;
        expect(failure.cause, same(cause));
        expect(failure.suppressed, same(suppressed));
        expect(failure.toString(), contains(cause.toString()));
        expect(failure.toString(), contains(suppressed.toString()));
        expect(temporary.deleteCalls, 1);
        expect(await file.readAsBytes(), original);
      } finally {
        if (!release.isCompleted) release.complete();
        await pending;
      }
    });

    test('$name retains publication I/O and cleanup errors together', () async {
      await save(initial: true);
      final file = File('${directory.path}/$name');
      final original = await file.readAsBytes();
      const cause = FileSystemException('actual native publication failure');
      const suppressed = FileSystemException(
        'actual temporary cleanup failure',
      );
      final temporary = _CleanupFile(File('${file.path}.tmp'), suppressed);
      await expectLater(
        IOOverrides.runZoned(
          () => save(publish: (_) async => throw cause),
          createFile: (path) => path == temporary.path ? temporary : file,
        ),
        throwsA(
          isA<StorageCleanupFailure>()
              .having((error) => error.cause, 'cause', isA<ConfigFailure>())
              .having(
                (error) => (error.cause as ConfigFailure).message.detail,
                'original publication detail',
                cause.toString(),
              )
              .having(
                (error) => error.suppressed,
                'suppressed',
                same(suppressed),
              ),
        ),
      );
      expect(await file.readAsBytes(), original);
    });

    test(
      '$name does not recheck temporary cleanup after publication',
      () async {
        final file = File('${directory.path}/$name');
        final temporary = _CleanupFile(
          File('${directory.path}/$name.tmp'),
          StateError('cleanup is not part of a committed publication'),
        );
        await IOOverrides.runZoned(
          () => save(),
          createFile: (path) => path == temporary.path ? temporary : file,
        );
        expect(temporary.existsCalls, 0);
        expect(temporary.deleteCalls, 0);
        expect(await File('${directory.path}/$name').exists(), isTrue);
      },
    );
  }
}
