import 'package:clash_pseudo/src/features/connections/connection_window.dart';
import 'package:flutter_test/flutter_test.dart';

import 'connection_window_fixtures.dart';

void main() {
  late ConnectionWindow window;
  setUp(() => window = ConnectionWindow());

  void accept(
    List<Map<String, dynamic>> rows,
    int elapsed, {
    Map<String, bool> presence = const {},
    Map<String, dynamic>? detail,
    bool limited = false,
  }) {
    window.accept(
      sample(
        rows,
        elapsed,
        presence: presence,
        detail: detail,
        limited: limited,
      ),
      core,
      window.parameters,
    );
  }

  test(
    'capacity eviction is not inactivity and leaves no hidden watch IDs',
    () {
      accept(List.generate(1000, (i) => row('$i')), 0);
      accept(
        List.generate(1000, (i) => row('${i + 1000}')),
        1000,
        presence: {for (var i = 0; i < 1000; i++) '$i': true},
        limited: true,
      );
      expect(window.records.length, 1000);
      expect(window.records.every((record) => record.active), isTrue);
      expect(window.parameters['previousActiveIds'], hasLength(1000));
      expect(window.parameters['previousActiveIds'], isNot(contains('0')));
      expect(window.limited, isTrue);
    },
  );

  test('inactive count and TTL are bounded and stop does not renew expiry', () {
    accept(List.generate(1000, (i) => row('$i')), 0);
    accept([], 1000, presence: {for (var i = 0; i < 1000; i++) '$i': false});
    expect(window.records.length, 500);
    expect(window.records.every((record) => !record.active), isTrue);
    window.stop(10000);
    window.prune(1000 + ConnectionWindow.retentionMs - 1);
    expect(window.records.length, 500);
    window.prune(1000 + ConnectionWindow.retentionMs);
    expect(window.records, isEmpty);
    expect(window.nextExpiry(1000000), isNull);
  });

  test('incomplete presence does not partially mark records inactive', () {
    accept([row('a'), row('b')], 0);
    expect(
      () => accept([], 1000, presence: {'a': false}),
      throwsFormatException,
    );
    expect(window.records.every((record) => record.active), isTrue);
    expect(window.records.length, 2);
  });

  test('oversized sample is rejected without replacing the window', () {
    accept([row('a')], 0);
    expect(
      () => accept(
        List.generate(1001, (i) => row('$i')),
        1000,
        presence: {'a': false},
      ),
      throwsFormatException,
    );
    expect(window.records.single.id, 'a');
    expect(window.records.single.active, isTrue);
  });

  test(
    'speed uses actual intervals and treats each direction independently',
    () {
      accept([row('a')], 0);
      expect(window.records.single.uploadSpeed, isNull);
      accept([row('a', upload: 30, download: 20)], 2000, presence: {'a': true});
      expect(window.records.single.uploadSpeed, 10);
      expect(window.records.single.downloadSpeed, 0);
      accept([row('a', upload: 1, download: 50)], 3000, presence: {'a': true});
      expect(window.records.single.uploadSpeed, isNull);
      expect(window.records.single.downloadSpeed, 30);
      accept(
        [row('a', upload: null, download: 60)],
        9000,
        presence: {'a': true},
      );
      expect(window.records.single.uploadSpeed, isNull);
      expect(window.records.single.downloadSpeed, isNull);
      accept([row('a', upload: 2, download: 70)], 10000, presence: {'a': true});
      expect(window.records.single.uploadSpeed, isNull);
      expect(window.records.single.downloadSpeed, 10);
      window.invalidate();
      accept([row('a', upload: 3, download: 80)], 11000, presence: {'a': true});
      expect(window.records.single.downloadSpeed, isNull);
      accept([], 12000, presence: {'a': false});
      expect(window.records.single.downloadSpeed, isNull);
      expect(
        window.records.single.observedAt!.millisecondsSinceEpoch,
        1792144811000,
      );
    },
  );

  test(
    'extra detail survives capacity eviction but cannot retain the engine',
    () {
      accept([row('a')], 0);
      window.pinDetail('a');
      accept(
        [row('b')],
        1000,
        presence: {'a': true},
        detail: row('a', download: 30),
      );
      expect(window.records.single.id, 'b');
      expect(window.detail!.id, 'a');
      expect(window.detail!.downloadSpeed, 10);
      accept([], 2000, presence: {'a': false, 'b': false});
      expect(window.detail!.active, isFalse);
      window.prune(2000 + ConnectionWindow.retentionMs);
      expect(window.isNotEmpty, isFalse);
      expect(window.detail, isNotNull);
      window.pinDetail(null);
      expect(window.detail, isNull);
      expect(window.parameters.containsKey('detailId'), isFalse);
    },
  );

  test(
    'missing pinned projection rejects the entire sample before mutation',
    () {
      accept([row('a'), row('b')], 0);
      window.pinDetail('b');
      expect(
        () => accept([], 1000, presence: {'a': false, 'b': true}),
        throwsFormatException,
      );
      expect(window.records.every((record) => record.active), isTrue);
    },
  );

  test(
    'evicted detail absence remains explicit without retaining another row',
    () {
      accept([row('a')], 0);
      accept([row('b')], 1000, presence: {'a': true});
      window.pinDetail('a');
      expect(window.detail, isNull);
      accept([row('b')], 2000, presence: {'a': false, 'b': true});
      expect(window.missingDetailId, 'a');
      expect(window.records.single.id, 'b');
      window.pinDetail('b');
      expect(window.missingDetailId, isNull);
    },
  );

  test('historical and pinned icons survive stop but not session clearing', () {
    final descriptor = {
      ...row('a'),
      'strategy': {'type': 'select', 'icon': 'https://fixture.test/old.svg'},
    };
    accept([descriptor], 0);
    window.pinDetail('a');
    accept([row('b')], 1000, presence: {'a': true}, detail: descriptor);
    expect(window.detail!.strategyIcon, 'https://fixture.test/old.svg');
    accept([], 2000, presence: {'a': false, 'b': false});
    window.stop(3000);
    expect(window.detail!.strategyType, 'select');
    expect(window.detail!.strategyIcon, 'https://fixture.test/old.svg');
    expect(window.detail!.active, isFalse);
    window.clear();
    accept([row('a')], 4000);
    expect(window.records.single.strategyIcon, isEmpty);
    expect(window.detail, isNull);
  });

  test('stop bounds remaining records and clear removes the old session', () {
    accept(List.generate(1000, (i) => row('$i')), 0);
    window.pinDetail('0');
    window.stop(1000);
    expect(window.records.length, 500);
    expect(window.records.every((record) => !record.active), isTrue);
    expect(window.detail!.active, isFalse);
    window.clear();
    expect(window.records, isEmpty);
    expect(window.detail, isNull);
    expect(window.observedAt, isNull);
  });
}
