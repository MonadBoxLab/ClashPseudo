import 'dart:convert';

import 'package:clash_pseudo/src/logic/overrides/local_yaml_edit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

dynamic decodeYaml(String text) =>
    loadYaml(text.startsWith('\u{feff}') ? text.substring(1) : text);

Matcher fails(LocalYamlEditError code) => throwsA(
  isA<LocalYamlEditException>().having((error) => error.code, 'code', code),
);

Map<String, Object?> proxy(String name) => {
  'name': name,
  'type': 'http',
  'server': 'localhost',
  'port': 8080,
};

Map<String, Object?> strategyGroup(String name) => {
  'name': name,
  'type': 'select',
  'proxies': ['DIRECT'],
};

String add(LocalYamlEdit editor, LocalYamlSection section, String name) =>
    switch (section) {
      LocalYamlSection.proxies => editor.addProxy(proxy(name)),
      LocalYamlSection.strategyGroups => editor.addStrategyGroup(
        strategyGroup(name),
      ),
      LocalYamlSection.proxyProviders => editor.addProxyProvider(name, {
        'type': 'inline',
        'payload': [proxy('downloaded')],
      }),
      LocalYamlSection.ruleProviders => editor.addRuleProvider(name, {
        'type': 'inline',
        'behavior': 'domain',
        'payload': ['example.com'],
      }),
      LocalYamlSection.rules => editor.addRule(name),
    };

void main() {
  test(
    'original field source maps parser spans back to mixed saved endings',
    () {
      const body =
          '\u{feff}# saved\r\n'
          'proxies:\r\n'
          '  - name: raw\n'
          '    type: http\r'
          '    port: 0\r\n'
          '    tls: false\n'
          '    blank:\r\n'
          '    unknown: {flag: null, empty: [], quoted: "01", list: ["🪷", {}]}\r\n'
          '    note: |-\r\n'
          '      first 🪷\n'
          '      second\r';
      final editor = LocalYamlEdit(body);
      final definition = editor.definitions(LocalYamlSection.proxies).single;
      String? original(List<Object> path) =>
          editor.definitionOriginalValue(definition, path);
      expect(original(['port']), '0');
      expect(original(['tls']), 'false');
      expect(original(['blank']), '');
      expect(
        original(['unknown']),
        '{flag: null, empty: [], quoted: "01", list: ["🪷", {}]}',
      );
      expect(original(['unknown', 'flag']), 'null');
      expect(original(['unknown', 'empty']), '[]');
      expect(original(['unknown', 'quoted']), '"01"');
      expect(original(['unknown', 'list', 0]), '"🪷"');
      expect(original(['unknown', 'list', 1]), '{}');
      expect(original(['note']), '|-\r\n      first 🪷\n      second\r');
      expect(original(['missing']), isNull);
      expect(original(['unknown', 'list', -1]), isNull);
      expect(original(['unknown', 'list', 2]), isNull);
      expect(original(['unknown', 'quoted', 'nested']), isNull);
      expect(editor.body, body);
      expect(
        () =>
            LocalYamlEdit('$body# changed\n')
                .definitionOriginalValue(definition, ['port']),
        fails(LocalYamlEditError.staleDefinition),
      );
    },
  );

  test('block scalar source retains LF CRLF and CR before adjacent fields', () {
    for (final newline in ['\n', '\r\n', '\r']) {
      for (final indicator in ['|-', '>+']) {
        final literal =
            '$indicator$newline'
            '      first 🪷$newline'
            '      second$newline';
        final body =
            '\u{feff}# 🪷 original$newline'
            'proxies:$newline'
            '  - name: source$newline'
            '    type: direct$newline'
            '    note: $literal'
            '    next: "keep"$newline';
        final editor = LocalYamlEdit(body);
        final definition = editor.definitions(LocalYamlSection.proxies).single;
        expect(editor.definitionOriginalValue(definition, ['note']), literal);
        expect(editor.definitionOriginalValue(definition, ['next']), '"keep"');
        expect(editor.body, body);
      }
    }
  });

  test('block scalar source adds no missing line break at EOF', () {
    for (final indicator in ['|', '>']) {
      for (final ending in ['', '\n', '\r\n', '\r']) {
        final literal = '$indicator\n      first 🪷\n      second$ending';
        final body =
            'proxies:\n'
            '  - name: source\n'
            '    type: direct\n'
            '    note: $literal';
        final editor = LocalYamlEdit(body);
        final definition = editor.definitions(LocalYamlSection.proxies).single;
        expect(editor.definitionOriginalValue(definition, ['note']), literal);
        expect(editor.body, body);
      }
    }
  });

  test('same-name provider edits only the changed nested field and keeps original bytes', () {
    const body =
        '\u{feff}# keep 🪷\r\n'
        'proxy-providers:\r\n'
        '  source:\r\n'
        '    type: http\r\n'
        '    url: https://old.invalid\r\n'
        '    headers: {token: old, keep: "01"} # exact\r\n'
        'rules: ["MATCH,DIRECT"] # tail\r\n';
    final editor = LocalYamlEdit(body);
    final target = editor.definitions(LocalYamlSection.proxyProviders).single;
    final value = editor.definitionValue(target);
    expect(editor.replaceProvider(target, 'source', value), body);
    final replacement = <String, Object?>{
      ...value,
      'headers': {'token': 'new', 'keep': '01'},
    };
    final changed = editor.replaceProvider(target, 'source', replacement);
    expect(changed, body.replaceFirst('token: old', 'token: new'));
    expect(decodeYaml(changed)['proxy-providers']['source'], replacement);
    expect(editor.body, body);
  });

  test(
    'invalid rule and provider sections cannot issue editable definitions',
    () {
      for (final (body, section) in [
        ('rules: [1, "MATCH,DIRECT"]\n', LocalYamlSection.rules),
        (
          'proxy-providers: {"": {type: http}}\n',
          LocalYamlSection.proxyProviders,
        ),
        ('rule-providers: {source: []}\n', LocalYamlSection.ruleProviders),
      ]) {
        final editor = LocalYamlEdit(body);
        expect(
          () => editor.definitions(section),
          fails(LocalYamlEditError.invalidStructure),
        );
        expect(
          () => add(editor, section, 'new'),
          fails(LocalYamlEditError.invalidStructure),
        );
        expect(editor.body, body);
      }
    },
  );

  test('section-specific replacement rejects wrong kinds and empty names without changes', () {
    const body =
        'proxies: [{name: A, type: direct}]\n'
        'proxy-providers: {source: {type: http}}\n'
        'rules: ["MATCH,DIRECT"]\n';
    final editor = LocalYamlEdit(body);
    final proxy = editor.definitions(LocalYamlSection.proxies).single;
    final provider = editor.definitions(LocalYamlSection.proxyProviders).single;
    final rule = editor.definitions(LocalYamlSection.rules).single;
    expect(
      () => editor.replaceNamed(proxy, {'name': '', 'type': 'direct'}),
      fails(LocalYamlEditError.invalidStructure),
    );
    expect(
      () => editor.replaceProvider(provider, '', {'type': 'http'}),
      fails(LocalYamlEditError.invalidStructure),
    );
    expect(
      () => editor.replaceProvider(proxy, 'new', {}),
      fails(LocalYamlEditError.unsupportedEdit),
    );
    expect(
      () => editor.replaceRule(proxy, 'MATCH,REJECT'),
      fails(LocalYamlEditError.unsupportedEdit),
    );
    expect(
      () => editor.definitionValue(rule),
      fails(LocalYamlEditError.invalidStructure),
    );
    expect(editor.replaceRule(rule, 'MATCH,DIRECT'), body);
    expect(editor.body, body);
  });

  test('new multiline slash scalars use native-compatible YAML escapes', () {
    const pem =
        '-----BEGIN CERTIFICATE-----\na/b+c/d=\n-----END CERTIFICATE-----\n';
    final upstream = YamlEditor('{}')..update(['ca'], pem);
    // Fixed yaml_edit 2.2.4 emits this escape. Dart accepts it; the fixed
    // native Go YAML scanner rejects it (see the shared native regression).
    expect(upstream.toString(), contains(r'\/'));
    expect(loadYaml(upstream.toString())['ca'], pem);
    final result = LocalYamlEdit('{}')
        .addProxy({'name': 'openvpn-slash', 'type': 'openvpn', 'ca': pem});
    expect(result, isNot(contains(r'\/')));
    expect(decodeYaml(result)['proxies'].single['ca'], pem);
  });

  test('new double-quoted slash repair preserves every literal backslash', () {
    for (var count = 0; count <= 6; count++) {
      final value = '${'\\' * count}/next\nlast/${'\\' * count}';
      final result = LocalYamlEdit(
        '{}',
      ).addProxy({'name': 'slashes-$count', 'type': 'http', 'password': value});
      expect(decodeYaml(result)['proxies'].single['password'], value);
      // Only an odd run denotes a slash escape. An even run followed by slash
      // is necessary to retain a literal backslash and must remain untouched.
      expect(RegExp(r'(?<!\\)(?:\\\\)*\\/').hasMatch(result), isFalse);
    }
  });

  test('slash adaptation touches no old bytes across BOM CRLF and nonBMP', () {
    const old =
        '\u{feff}# 🪷 keep\r\nunknown: {plain: a\\/b, quoted: "a\\\\/b", single: \'a\\/b\'} # old\r\nproxies: []\r\n';
    final result = LocalYamlEdit(old).addProxy({
      'name': 'new/🪷',
      'type': 'http',
      'password': 'one/two\nthree\\/four',
    });
    expect(
      result.startsWith(old.substring(0, old.indexOf('proxies:'))),
      isTrue,
    );
    expect(result.startsWith('\u{feff}'), isTrue);
    expect(result.replaceAll('\r\n', '').contains('\n'), isFalse);
    expect(decodeYaml(result)['unknown'], decodeYaml(old)['unknown']);
    expect(
      decodeYaml(result)['proxies'].single['password'],
      'one/two\nthree\\/four',
    );
  });

  test('alias-bounded insertion adapts only the new slash scalar', () {
    const old =
        'seed: &seed {name: old, type: direct, raw: \'keep\\/this\'}\nproxies:\n  - *seed # exact alias\n';
    final result = LocalYamlEdit(old)
        .addProxy({'name': 'new', 'type': 'http', 'password': 'a/b\nc\\/d'});
    expect(result, contains(old.substring(0, old.indexOf('proxies:'))));
    expect(result, contains('  - *seed # exact alias\n'));
    expect(decodeYaml(result)['proxies'].first['password'], 'a/b\nc\\/d');
  });

  test(
    'slash-adapted UTF8 output still enforces the exact BOM CRLF budget',
    () {
      for (final block in [
        'proxies: []\r\n',
        'seed: &s {name: old, type: direct}\r\nproxies:\r\n  - *s # preserved\r\n',
      ]) {
        String source(int padding) => '\u{feff}# 🪷${'x' * padding}\r\n$block';
        final definition = <String, Object?>{
          'name': 'new/🪷',
          'type': 'http',
          'password': '/a\\/b\n/c',
          'url': 'https://fixture.invalid/path?token=synthetic',
          'allowed-ips': ['::/0'],
        };
        final sample = LocalYamlEdit(source(0)).addProxy(definition);
        final padding = LocalYamlEdit.maxBytes - utf8.encode(sample).length;
        final exact = LocalYamlEdit(source(padding)).addProxy(definition);
        expect(utf8.encode(exact).length, LocalYamlEdit.maxBytes);
        expect(
          decodeYaml(exact)['proxies'].first['password'],
          definition['password'],
        );
        expect(
          () => LocalYamlEdit(source(padding + 1)).addProxy(definition),
          fails(LocalYamlEditError.tooLarge),
        );
      }
    },
  );

  test('new nested map keys and list scalars preserve slash semantics', () {
    final definition = <String, Object?>{
      'name': 'nested',
      'type': 'http',
      'headers': {'line/one\nline\\/two': 'value/one\nvalue\\/two'},
      'unknown': [
        'path/one\npath\\/two',
        {'other/one\nkey': 'other/one\nvalue'},
      ],
    };
    final result = LocalYamlEdit('{}').addProxy(definition);
    expect(decodeYaml(result)['proxies'].single, definition);
    expect(RegExp(r'(?<!\\)(?:\\\\)*\\/').hasMatch(result), isFalse);
  });

  test('new flow URL query and IPv6 scalars are explicitly quoted', () {
    const url = 'https://fixture.invalid/provider?token=synthetic';
    final provider = LocalYamlEdit('{}').addRuleProvider('fixture-rules', {
      'type': 'http',
      'behavior': 'domain',
      'url': url,
    });
    expect(provider, contains('"$url"'));
    expect(decodeYaml(provider)['rule-providers']['fixture-rules']['url'], url);
    final proxy = LocalYamlEdit('{}').addProxy({
      'name': 'fixture',
      'type': 'wireguard',
      'allowed-ips': ['::/0'],
    });
    expect(proxy, contains('"::/0"'));
    expect(decodeYaml(proxy)['proxies'].single['allowed-ips'], ['::/0']);
  });

  test('new flow query keys and literal backslashes round trip without touching old scalars', () {
    const old =
        '\u{feff}# 🪷 old\r\nunknown: {url: https://old.invalid/path?keep=one, path: ::/0, raw: \'keep\\/this?raw\'}\r\nproxy-providers: {}\r\n';
    final definition = <String, Object?>{
      'type': 'http',
      'url': r'https://fixture.invalid/a\/b?token=synthetic',
      'headers': {'X?Name': r'keep\/this?query'},
    };
    final result = LocalYamlEdit(old)
        .addProxyProvider('name?query', definition);
    expect(
      result.startsWith(old.substring(0, old.indexOf('proxy-providers:'))),
      isTrue,
    );
    expect(decodeYaml(result)['proxy-providers']['name?query'], definition);
    expect(result, contains('"name?query"'));
    expect(result, contains('"X?Name"'));
    expect(result.replaceAll('\r\n', '').contains('\n'), isFalse);
  });

  for (final section in [
    LocalYamlSection.proxyProviders,
    LocalYamlSection.ruleProviders,
  ]) {
    test('${section.key} quotes a literal merge-looking provider name', () {
      final created = section == LocalYamlSection.proxyProviders
          ? LocalYamlEdit('{}')
                .addProxyProvider('<<', {'type': 'inline', 'payload': []})
          : LocalYamlEdit('{}')
                .addRuleProvider('<<', {'type': 'inline', 'payload': []});
      final editor = LocalYamlEdit(created);
      expect(editor.definitions(section).single.value, '<<');
      expect(
        (decodeYaml(created)[section.key] as Map).containsKey('<<'),
        isTrue,
      );
      expect(
        () => add(editor, section, '<<'),
        fails(LocalYamlEditError.duplicateName),
      );
      expect(
        LocalYamlEdit(editor.remove(editor.definitions(section).single))
            .definitions(section),
        isEmpty,
      );
    });
  }
  for (final valueAlias in [false, true]) {
    test(
      'provider insertion with root-column alias key (${valueAlias ? 'aliased' : 'direct'} value) stays in target map',
      () {
        final body =
            '&key Existing: anchor-key\nseed: &p {type: inline, payload: []}\n'
            'proxy-providers:\n  ? *key\n  : ${valueAlias ? '*p' : '{type: inline, payload: []}'}\n'
            'other: "\u{20000}"\n';
        final result = LocalYamlEdit(body)
            .addProxyProvider('New', {'type': 'inline', 'payload': []});
        expect((decodeYaml(result)['proxy-providers'] as Map).keys, [
          'Existing',
          'New',
        ]);
        expect(decodeYaml(result).containsKey('New'), isFalse);
        expect(
          result.replaceFirst('  New: {type: inline, payload: []}\n', ''),
          body,
        );
      },
    );
  }

  for (final section in [
    LocalYamlSection.proxies,
    LocalYamlSection.strategyGroups,
    LocalYamlSection.rules,
  ]) {
    for (final position in [0, 1, 2]) {
      test(
        '${section.key} removes position $position beside aliases with comments, blanks, non-BMP, mixed CRLF',
        () {
          final isRules = section == LocalYamlSection.rules;
          final old1 = isRules ? '"MATCH,Old1"' : '{name: Old1, type: direct}';
          final old2 = isRules ? '"MATCH,Old2"' : '{name: Old2, type: direct}';
          final header =
              '﻿unknown: "\u{1d11e}\u{20000}"\r\n'
              'seed1: &p1 $old1\nseed2: &p2 $old2\r\n${section.key}:\r\n';
          final target = isRules
              ? '  - "DOMAIN,\u{20000},DIRECT" # target inline\r\n'
              : '  - name: Target\r\n    type: direct\n'
                    '    unknown: {nested: "\u{20000}"} # target inline\r\n';
          final records = [
            '  - *p1 # sibling one\r\n',
            '  - *p2 # sibling two\n',
          ];
          records.insert(
            position,
            '$target\r\n  # standalone comment retained per package\r\n',
          );
          final body =
              '$header${records.join()}other: {nested: "01"} # untouched\n';
          final editor = LocalYamlEdit(body);
          final result = editor.remove(editor.definitions(section)[position]);
          // Compare comment/blank association with the same public remove call on
          // a non-aliased source. Restore only the two known sibling spellings.
          final baselineBody = body
              .substring(1)
              .replaceAll('\r\n', '\n')
              .replaceFirst('  - *p1', '  - $old1')
              .replaceFirst('  - *p2', '  - $old2');
          final baseline = YamlEditor(baselineBody);
          baseline.remove([section.key, position]);
          final baselineResult = baseline
              .toString()
              .replaceFirst('  - $old1', '  - *p1')
              .replaceFirst('  - $old2', '  - *p2');
          expect(result.substring(1).replaceAll('\r\n', '\n'), baselineResult);
          expect(result, contains('seed1: &p1 $old1\nseed2: &p2 $old2\r\n'));
          expect(result, contains('  - *p1 # sibling one\r\n'));
          expect(result, contains('  - *p2 # sibling two\n'));
          expect(
            result.endsWith('other: {nested: "01"} # untouched\n'),
            isTrue,
          );
          expect(result, isNot(contains('items:')));
          expect(result, isNot(contains('- null')));
          expect((decodeYaml(result)[section.key] as List).length, 2);
          expect(editor.body, body);
        },
      );
    }
  }
  for (final section in [
    LocalYamlSection.proxyProviders,
    LocalYamlSection.ruleProviders,
  ]) {
    for (final style in ['flow', 'block', 'explicit', 'anchored', 'eof']) {
      test('${section.key} inserts beside sibling alias in $style using only new bytes', () {
        const prefix =
            '﻿unknown: "\u{1d11e}\u{20000}"\r\nseed: &p {type: inline, payload: []}\r\n';
        final branch = switch (style) {
          'flow' => '${section.key}: {Existing: *p} # same bytes\r\n',
          'explicit' =>
            '${section.key}:\r\n  ? Existing\r\n  : *p # same bytes\r\n',
          'anchored' =>
            '${section.key}: &unused\r\n  Existing: *p # same bytes\r\n',
          'eof' => '${section.key}:\r\n  Existing: *p # same bytes',
          _ => '${section.key}:\r\n  Existing: *p # same bytes\r\n',
        };
        final body = '$prefix$branch';
        final result = section == LocalYamlSection.proxyProviders
            ? LocalYamlEdit(body)
                  .addProxyProvider('New', {'type': 'inline', 'payload': []})
            : LocalYamlEdit(body)
                  .addRuleProvider('New', {'type': 'inline', 'payload': []});
        final entry = style == 'flow'
            ? ', New: {type: inline, payload: []}'
            : '${style == 'eof' ? '\r\n' : ''}  New: {type: inline, payload: []}\r\n';
        expect(result.replaceFirst(entry, ''), body);
        expect(decodeYaml(result)[section.key]['New'], {
          'type': 'inline',
          'payload': [],
        });
        expect(decodeYaml(result)[section.key]['Existing'], {
          'type': 'inline',
          'payload': [],
        });
      });
    }
  }

  for (final section in [
    LocalYamlSection.proxies,
    LocalYamlSection.strategyGroups,
    LocalYamlSection.rules,
  ]) {
    for (final flow in [true, false]) {
      test(
        '${section.key} inserts before sibling alias in ${flow ? 'flow' : 'block'} without normalizing source',
        () {
          final seeded = section == LocalYamlSection.rules
              ? '"MATCH,DIRECT"'
              : '{name: Old, type: direct}';
          final branch = flow
              ? '${section.key}: [*p] # exact\r\n'
              : '${section.key}:\r\n  - *p # exact\n';
          final body = '﻿unknown: "\u{20000}"\r\nseed: &p $seeded\r\n$branch';
          final result = add(
            LocalYamlEdit(body),
            section,
            section == LocalYamlSection.rules ? 'DOMAIN,new,DIRECT' : 'New',
          );
          final parsed = decodeYaml(result)[section.key] as List;
          expect(parsed.length, 2);
          expect(
            section == LocalYamlSection.rules
                ? parsed.first
                : parsed.first['name'],
            section == LocalYamlSection.rules ? 'DOMAIN,new,DIRECT' : 'New',
          );
          if (flow) expect(result, contains('*p] # exact\r\n'));
          if (!flow) expect(result, contains('  - *p # exact\n'));
          final editor = LocalYamlEdit(result);
          final withoutNew = editor.remove(editor.definitions(section).first);
          // Removing the new target follows package whitespace semantics; all old
          // scalar spelling, aliases, comments, and Unicode must still remain.
          expect(withoutNew, contains('seed: &p $seeded\r\n'));
          expect(
            withoutNew,
            contains(flow ? '*p] # exact\r\n' : '  - *p # exact\n'),
          );
        },
      );
    }
  }

  for (final section in [
    LocalYamlSection.proxyProviders,
    LocalYamlSection.ruleProviders,
  ]) {
    test('${section.key} direct deletion keeps a sibling alias key intact', () {
      final body =
          'seed-key: &k Existing\n${section.key}:\n'
          '  New: {type: inline, payload: []}\n  ? *k\n  : {type: inline, payload: []}\n'
          'other: keep\n';
      final editor = LocalYamlEdit(body);
      final identity = editor.definitions(section).first;
      final result = editor.remove(identity);
      expect(
        result,
        body.replaceFirst('  New: {type: inline, payload: []}\n', ''),
      );
    });
  }

  test('shared provider collection itself still refuses add and deletion', () {
    const body =
        'proxy-providers: &p {A: {type: inline, payload: []}}\ncopy: *p\n';
    final editor = LocalYamlEdit(body);
    expect(
      () => editor.addProxyProvider('B', {'type': 'inline'}),
      fails(LocalYamlEditError.aliasTarget),
    );
    expect(
      () => editor.remove(
        editor.definitions(LocalYamlSection.proxyProviders).single,
      ),
      fails(LocalYamlEditError.aliasTarget),
    );
    expect(editor.body, body);
  });

  test('a merge alias sibling does not block insertion of a different provider', () {
    const body =
        'seed: &p {Inherited: {type: inline, payload: []}}\n'
        'proxy-providers:\n  <<: *p\n  Existing: {type: inline, payload: []}\n'
        'unknown: "\u{20000}"\n';
    final result = LocalYamlEdit(body)
        .addProxyProvider('New', {'type': 'inline', 'payload': []});
    expect(
      result.replaceFirst('  New: {type: inline, payload: []}\n', ''),
      body,
    );
    expect(
      () => LocalYamlEdit(body).addProxyProvider('Inherited', {'type': 'file'}),
      fails(LocalYamlEditError.inheritedTarget),
    );
  });

  test(
    'non-BMP offsets and CRLF boundaries survive first/middle/last deletions',
    () {
      const prefix = '﻿unknown: "\u{1d11e}\u{20000}"\r\n';
      const first = '  - {name: "\u{20000}", type: direct} # first\r\n';
      const middle = '  - {name: B, type: direct} # middle\n';
      const last = '  - {name: C, type: direct} # last\r\n';
      const suffix = 'trailer: "\u{20000}"\n';
      const body = '${prefix}proxies:\r\n$first$middle$last$suffix';
      final editor = LocalYamlEdit(body);
      final identities = editor.definitions(LocalYamlSection.proxies);
      expect(
        editor.remove(identities[0]),
        '${prefix}proxies:\r\n$middle$last$suffix',
      );
      expect(
        editor.remove(identities[1]),
        '${prefix}proxies:\r\n$first$last$suffix',
      );
      expect(
        editor.remove(identities[2]),
        '${prefix}proxies:\r\n$first$middle$suffix',
      );
    },
  );

  for (final section in LocalYamlSection.values) {
    test('${section.key} removal never changes references in any other branch', () {
      const lines = <String, String>{
        'proxies': 'proxies: [{name: A, type: direct}]\n',
        'proxy-groups':
            'proxy-groups: [{name: A, type: select, proxies: [A], use: [A]}]\n',
        'proxy-providers': 'proxy-providers: {A: {type: inline, payload: [{name: Downloaded, type: direct}]}}\n',
        'rule-providers': 'rule-providers: {A: {type: inline, behavior: classical, payload: ["MATCH,A"]}}\n',
        'rules': 'rules: ["RULE-SET,A,A", "MATCH,A"]\n',
      };
      final body = lines.values.join();
      final editor = LocalYamlEdit(body);
      final result = editor.remove(editor.definitions(section).first);
      for (final entry in lines.entries) {
        if (entry.key != section.key) expect(result, contains(entry.value));
      }
      expect(editor.body, body);
    });
  }

  test('invalid syntax diagnostics never expose original credentials', () {
    const secret = 'https://user:password@example.test/path?token=secret';
    try {
      LocalYamlEdit('secret: "$secret"\nproxies: [invalid');
      fail('Expected invalid YAML');
    } on LocalYamlEditException catch (error) {
      expect(error.code, LocalYamlEditError.invalidYaml);
      expect(error.path, isEmpty);
      expect('$error', isNot(contains(secret)));
      expect('$error', isNot(contains('password')));
    }
  });

  test(
    'new definitions preserve nested public Option shapes without defaults',
    () {
      final definition = <String, Object?>{
        'name': '公开\u{20000}',
        'type': 'wireguard',
        'udp': false,
        'reserved': [0, 128, 255],
        'peers': [
          {'server': 'example.test', 'port': 0, 'allowed-ips': <String>[]},
        ],
        'http-opts': {
          'headers': {
            'X-Test': ['a', 'b'],
          },
        },
        'untouched-null': null,
        'empty-string': '',
      };
      final body = LocalYamlEdit('unknown: keep\n').addProxy(definition);
      expect(decodeYaml(body)['proxies'].single, definition);
      expect((decodeYaml(body)['proxies'].single as Map).keys, definition.keys);
      expect(body, contains('unknown: keep\n'));
    },
  );

  for (final section in LocalYamlSection.values) {
    groupTests(section);
  }

  test('first body can explicitly initialize {}, stored empty body cannot', () {
    expect(() => LocalYamlEdit(''), fails(LocalYamlEditError.notMapping));
    expect(() => LocalYamlEdit('﻿'), fails(LocalYamlEditError.notMapping));
    final result = LocalYamlEdit(
      '',
      initializeEmpty: true,
    ).addProxy(proxy('A'));
    expect((decodeYaml(result)['proxies'] as List).single['name'], 'A');
    final bom = LocalYamlEdit(
      '﻿',
      initializeEmpty: true,
    ).addRule('MATCH,DIRECT');
    expect(bom.startsWith('﻿{'), isTrue);
    expect(decodeYaml(bom)['rules'], ['MATCH,DIRECT']);
  });

  for (final (body, code) in <(String, LocalYamlEditError)>[
    ('# stored comment\n', LocalYamlEditError.notMapping),
    ('   \n', LocalYamlEditError.notMapping),
    ('null', LocalYamlEditError.notMapping),
    ('[a, b]', LocalYamlEditError.notMapping),
    ('word', LocalYamlEditError.notMapping),
    ('rules: [broken', LocalYamlEditError.invalidYaml),
    ('a: *missing', LocalYamlEditError.invalidYaml),
    ('---\na: 1\n---\nb: 2\n', LocalYamlEditError.multipleDocuments),
    ('{}\n---\n', LocalYamlEditError.multipleDocuments),
    ('a: 1\na: 2\n', LocalYamlEditError.duplicateKey),
    ('unknown: {nested: {a: 1, a: 2}}\n', LocalYamlEditError.duplicateKey),
    ('a: 1\n"a": 2\n', LocalYamlEditError.duplicateKey),
    ('1: a\n', LocalYamlEditError.invalidStructure),
    ('unknown: {true: a}', LocalYamlEditError.invalidStructure),
    ('loop: &loop [*loop]\n', LocalYamlEditError.unsafeStructure),
  ]) {
    test('rejects $code without overwriting even with initializeEmpty', () {
      expect(
        () =>
            LocalYamlEdit(body, initializeEmpty: true).addRule('MATCH,DIRECT'),
        fails(code),
      );
    });
  }

  test(
    'inserts native rule first without deduplication or MATCH reordering',
    () {
      const body =
          'rules:\n'
          '  - MATCH,Old # stays before old domain\n'
          '  - DOMAIN,example.com,DIRECT\n'
          '  - DOMAIN,example.com,DIRECT\n';
      const rule = 'DOMAIN,example.com,DIRECT';
      final editor = LocalYamlEdit(body);
      final result = editor.addRule(rule);
      expect(decodeYaml(result)['rules'], [rule, 'MATCH,Old', rule, rule]);
      expect(result.endsWith(body.substring('rules:\n'.length)), isTrue);
      expect(editor.body, body);
    },
  );

  test('duplicate rule identities remove only their actual indexed entry', () {
    const body =
        'rules:\n'
        '  - MATCH,DIRECT # first\n'
        '  - MATCH,DIRECT # second\n'
        '  - MATCH,REJECT # third\n';
    final editor = LocalYamlEdit(body);
    final definitions = editor.definitions(LocalYamlSection.rules);
    expect(definitions.map((item) => item.path.last), [0, 1, 2]);
    final result = editor.remove(definitions[1]);
    expect(
      result,
      'rules:\n'
      '  - MATCH,DIRECT # first\n'
      '  - MATCH,REJECT # third\n',
    );
  });

  test(
    'deleting a proxy never cascades into group/provider/rule references',
    () {
      const references =
          'proxy-groups:\n'
          '  - {name: Group, type: select, proxies: [A], use: [Source]}\n'
          'proxy-providers:\n'
          '  Source: {type: inline, payload: [{name: A, type: direct}]}\n'
          'rule-providers:\n'
          '  Rules: {type: inline, behavior: classical, payload: [MATCH,A]}\n'
          'rules: [MATCH,A, RULE-SET,Rules,Group]\n';
      final editor = LocalYamlEdit(
        'proxies: [{name: A, type: direct}]\n$references',
      );
      final result = editor.remove(
        editor.definitions(LocalYamlSection.proxies).single,
      );
      expect(result, 'proxies: []\n$references');
    },
  );

  test('provider identity removes definition, not its downloaded name', () {
    const body =
        'proxy-providers:\n'
        '  A: {type: inline, payload: [{name: Downloaded, type: direct}]}\n'
        'proxies: [{name: A, type: direct}]\n'
        'rules: [MATCH,A]\n';
    final editor = LocalYamlEdit(body);
    final direct = editor.definitions(LocalYamlSection.proxyProviders);
    expect(direct.map((item) => item.value), ['A']);
    expect(direct.single.path, ['proxy-providers', 'A']);
    final result = editor.remove(direct.single);
    expect(
      result,
      'proxy-providers:\n  {}\n'
      'proxies: [{name: A, type: direct}]\n'
      'rules: [MATCH,A]\n',
    );
  });

  test('body-bound identity rejects index drift, rename, and unrelated changes', () {
    const body = 'proxies: [{name: A, type: direct}]\n';
    final identity = LocalYamlEdit(body)
        .definitions(LocalYamlSection.proxies)
        .single;
    for (final changed in [
      'proxies: [{name: B, type: direct}, {name: A, type: direct}]\n',
      body.replaceAll('name: A', 'name: B'),
      '$body# revision changed elsewhere\n',
    ]) {
      final editor = LocalYamlEdit(changed);
      expect(
        () => editor.remove(identity),
        fails(LocalYamlEditError.staleDefinition),
      );
      expect(editor.body, changed);
    }
    // Independently constructed editor of the exact same body is valid; storage
    // ID/revision/epoch are deliberately outside this pure module.
    expect(LocalYamlEdit(body).remove(identity), 'proxies: []\n');
    expect(() => identity.path.add('forged'), throwsUnsupportedError);
  });

  test('unrelated alias and merge branch stays byte-for-byte unchanged', () {
    const unrelated =
        '# unknown anchor\n'
        'unknown: &defaults\n'
        '  nested: {quoted: "01", flag: false, empty: null}\n'
        'copy: *defaults\n'
        'merged: {<<: *defaults, extra: 0} # untouched\n';
    final result = LocalYamlEdit('${unrelated}rules: ["MATCH,DIRECT"]\n')
        .addRule('DOMAIN,new.example,DIRECT');
    expect(result.startsWith(unrelated), isTrue);
    expect(decodeYaml(result)['rules'].first, 'DOMAIN,new.example,DIRECT');
    final absent = LocalYamlEdit(unrelated).addProxy(proxy('A'));
    expect(absent.startsWith(unrelated), isTrue);
  });

  test(
    'alias-backed target list refuses add and delete without body changes',
    () {
      const body = 'source: &rules [MATCH,DIRECT]\nrules: *rules\n';
      final editor = LocalYamlEdit(body);
      expect(
        () => editor.addRule('MATCH,REJECT'),
        fails(LocalYamlEditError.aliasTarget),
      );
      final direct = editor.definitions(LocalYamlSection.rules);
      expect(
        () => editor.remove(direct.first),
        fails(LocalYamlEditError.aliasTarget),
      );
      expect(editor.body, body);
    },
  );

  test('deleting an anchored definition used elsewhere fails safely', () {
    const body =
        'proxies:\n'
        '  - &node {name: A, type: direct}\n'
        'unknown: *node\n';
    final editor = LocalYamlEdit(body);
    final direct = editor.definitions(LocalYamlSection.proxies).single;
    expect(() => editor.remove(direct), fails(LocalYamlEditError.aliasTarget));
    expect(editor.body, body);
  });

  test(
    'target nested alias and provider alias refuse without source leakage',
    () {
      const body =
          'secret: &auth "credential-do-not-log"\n'
          'proxy-providers:\n'
          '  A: {type: http, url: *auth}\n';
      final editor = LocalYamlEdit(body);
      final withSibling = editor.addProxyProvider('B', {
        'type': 'inline',
        'payload': [],
      });
      expect(decodeYaml(withSibling)['proxy-providers']['B'], {
        'type': 'inline',
        'payload': [],
      });
      expect(withSibling, contains('  A: {type: http, url: *auth}\n'));
      final identity = editor
          .definitions(LocalYamlSection.proxyProviders)
          .single;
      try {
        editor.remove(identity);
        fail('Expected alias refusal');
      } on LocalYamlEditException catch (error) {
        expect(error.code, LocalYamlEditError.aliasTarget);
        expect('$error', isNot(contains('credential-do-not-log')));
      }
      expect(editor.body, body);
    },
  );

  test('root inherited target refuses but unrelated root merge is allowed', () {
    const inherited =
        'defaults: &defaults {rules: ["MATCH,DIRECT"]}\n'
        '<<: *defaults\n';
    final editor = LocalYamlEdit(inherited);
    expect(
      () => editor.addRule('MATCH,REJECT'),
      fails(LocalYamlEditError.inheritedTarget),
    );
    expect(
      () => editor.definitions(LocalYamlSection.rules),
      fails(LocalYamlEditError.inheritedTarget),
    );
    expect(editor.body, inherited);

    const unrelated =
        'defaults: &defaults {unknown: {nested: keep}}\n<<: *defaults\n';
    final result = LocalYamlEdit(unrelated).addRule('MATCH,DIRECT');
    expect(result, contains('defaults: &defaults {unknown: {nested: keep}}\n'));
    expect(result, contains('<<: *defaults\n'));
    expect(decodeYaml(result)['rules'], ['MATCH,DIRECT']);
  });

  test(
    'explicit target overrides root merge without modifying inheritance',
    () {
      const inherited =
          'defaults: &defaults {rules: [MATCH,Lower]}\n<<: *defaults\n';
      final result = LocalYamlEdit('${inherited}rules: ["MATCH,DIRECT"]\n')
          .addRule('MATCH,REJECT');
      expect(result.startsWith(inherited), isTrue);
      expect(decodeYaml(result)['rules'], ['MATCH,REJECT', 'MATCH,DIRECT']);
    },
  );

  test(
    'merge sequence and nested merge target are recognized as inherited',
    () {
      const body =
          'a: &a {rules: ["MATCH,DIRECT"]}\n'
          'b: &b {<<: *a, unknown: 1}\n'
          '<<: [{other: 2}, *b]\n';
      expect(
        () => LocalYamlEdit(body).addRule('MATCH,REJECT'),
        fails(LocalYamlEditError.inheritedTarget),
      );
    },
  );

  test(
    'inherited provider is not a direct definition and cannot be overwritten',
    () {
      const body =
          'proxy-providers:\n'
          '  <<: {Inherited: {type: inline, payload: []}}\n'
          '  Direct: {type: inline, payload: []}\n';
      final editor = LocalYamlEdit(body);
      expect(
        editor
            .definitions(LocalYamlSection.proxyProviders)
            .map((item) => item.value),
        ['Direct'],
      );
      expect(
        () => editor.addProxyProvider('Inherited', {'type': 'file'}),
        fails(LocalYamlEditError.inheritedTarget),
      );
      final result = editor.addProxyProvider('New', {
        'type': 'inline',
        'payload': [],
      });
      expect(
        result,
        contains('  <<: {Inherited: {type: inline, payload: []}}\n'),
      );
    },
  );

  test('name inherited by an item is not guessed from a runtime snapshot', () {
    const body = 'proxies:\n  - <<: {name: A, type: direct}\n';
    expect(
      () => LocalYamlEdit(body).definitions(LocalYamlSection.proxies),
      fails(LocalYamlEditError.inheritedTarget),
    );
    expect(
      () => LocalYamlEdit(body).addProxy(proxy('B')),
      fails(LocalYamlEditError.inheritedTarget),
    );
  });

  test('quoted merge-looking key is ordinary unknown data', () {
    const body = '"<<": {rules: [MATCH,NotInherited]}\n';
    final result = LocalYamlEdit(body).addRule('MATCH,DIRECT');
    expect(result.startsWith(body), isTrue);
    expect(decodeYaml(result)['rules'], ['MATCH,DIRECT']);
  });

  test('does not rewrite unrelated aliases when deleting a direct sibling', () {
    const body =
        'unknown: &unknown {nested: keep}\ncopy: *unknown\n'
        'proxies: [{name: A, type: direct}, {name: B, type: direct}]\n';
    final editor = LocalYamlEdit(body);
    final result = editor.remove(
      editor.definitions(LocalYamlSection.proxies).first,
    );
    expect(
      result,
      'unknown: &unknown {nested: keep}\ncopy: *unknown\n'
      'proxies: [ {name: B, type: direct}]\n',
    );
  });

  for (final ending in ['\n', '\r\n', '\r']) {
    test(
      'preserves BOM and ${jsonEncode(ending)} on insertion and deletion',
      () {
        final prefix = '﻿# unchanged${ending}unknown: {text: "中文"}$ending';
        final original = '${prefix}rules:$ending  - MATCH,DIRECT # old$ending';
        final result = LocalYamlEdit(original)
            .addRule('DOMAIN,new.example,DIRECT');
        expect(
          result,
          '${prefix}rules:$ending'
          '  - "DOMAIN,new.example,DIRECT"$ending'
          '  - MATCH,DIRECT # old$ending',
        );
        final updated = LocalYamlEdit(result);
        final removed = updated.remove(
          updated.definitions(LocalYamlSection.rules).first,
        );
        expect(removed, original);
      },
    );
  }

  test(
    'mixed endings retain all untouched bytes; new text uses dominant ending',
    () {
      const prefix = '﻿# first\r\nunknown: {nested: "中文"}\n# separator\r\n';
      const suffix =
          'rules:\r\n  - MATCH,DIRECT # old\ntrailer: |\r\n  stays\r\n';
      final result = LocalYamlEdit('$prefix$suffix').addRule('DOMAIN,x,DIRECT');
      expect(
        result,
        '${prefix}rules:\r\n  - "DOMAIN,x,DIRECT"\r\n'
        '  - MATCH,DIRECT # old\ntrailer: |\r\n  stays\r\n',
      );
      final editor = LocalYamlEdit(result);
      expect(
        editor.remove(editor.definitions(LocalYamlSection.rules).first),
        '$prefix$suffix',
      );
    },
  );

  test('mixed ending tie chooses first but never normalizes old endings', () {
    const body = '# first\r\nrules:\n  - MATCH,DIRECT\r\nunknown: yes\n';
    expect(
      LocalYamlEdit(body).addRule('MATCH,REJECT'),
      '# first\r\nrules:\n  - "MATCH,REJECT"\r\n  - MATCH,DIRECT\r\nunknown: yes\n',
    );
  });

  test('block scalar unknown text and comments survive byte-for-byte', () {
    const before =
        '# heading\n'
        'unknown:\n'
        '  nested:\n'
        '    - "001" # quoted\n'
        '    - {false-value: false, zero: 0, null-value: null, empty: ""}\n'
        '  prose: |+\n'
        '    # not a comment\n'
        '    rules: [not, configuration]\n'
        '\n';
    const after = '# end rule branch\nother: >-\n  literal unknown content\n';
    const body = '${before}rules:\n  - MATCH,DIRECT # old rule\n$after';
    final result = LocalYamlEdit(body).addRule('DOMAIN,new.example,Select');
    expect(
      result,
      '${before}rules:\n  - "DOMAIN,new.example,Select"\n'
      '  - MATCH,DIRECT # old rule\n$after',
    );
  });

  test('safe failure for deep structure and alias expansion bomb', () {
    final deep = 'unknown: ${'[' * 100}0${']' * 100}\nrules: []\n';
    expect(
      () => LocalYamlEdit(deep),
      fails(LocalYamlEditError.unsafeStructure),
    );
    final bomb = StringBuffer('a0: &a0 [leaf, leaf]\n');
    for (var i = 1; i < 22; i++) {
      bomb.writeln('a$i: &a$i [*a${i - 1}, *a${i - 1}]');
    }
    expect(
      () => LocalYamlEdit('$bomb'),
      fails(LocalYamlEditError.unsafeStructure),
    );
  });

  test('safe failure for caller-built cyclic, deep, and non-YAML values', () {
    final cycle = <String, Object?>{'name': 'A'};
    cycle['self'] = cycle;
    expect(
      () => LocalYamlEdit('{}').addProxy(cycle),
      fails(LocalYamlEditError.unsafeStructure),
    );
    Object? value = 'leaf';
    for (var i = 0; i < 100; i++) {
      value = [value];
    }
    expect(
      () => LocalYamlEdit('{}').addProxy({'name': 'A', 'deep': value}),
      fails(LocalYamlEditError.unsafeStructure),
    );
    expect(
      () => LocalYamlEdit('{}').addProxy({'name': 'A', 'bad': Object()}),
      fails(LocalYamlEditError.invalidStructure),
    );
    expect(
      () => LocalYamlEdit('{}').addProxy({
        'name': 'A',
        'bad': {1: 'a'},
      }),
      fails(LocalYamlEditError.invalidStructure),
    );
  });

  test(
    '16 MiB exact output accepted, +1 byte rejected, BOM and Unicode counted',
    () {
      const small = '﻿unknown: "中文"\nrules: ["MATCH,DIRECT"]\n';
      final smallResult = LocalYamlEdit(small).addRule('MATCH,REJECT');
      final padding = LocalYamlEdit.maxBytes - utf8.encode(smallResult).length;
      final body = '#${'x' * (padding - 2)}\n${small.substring(1)}';
      final withBom = '﻿$body';
      final editor = LocalYamlEdit(withBom);
      final exact = editor.addRule('MATCH,REJECT');
      expect(utf8.encode(exact).length, LocalYamlEdit.maxBytes);
      expect(exact.startsWith('﻿#'), isTrue);
      expect(exact, contains('unknown: "中文"\n'));
      final oversized = LocalYamlEdit(withBom.replaceFirst('#', '#x'));
      expect(
        () => oversized.addRule('MATCH,REJECT'),
        fails(LocalYamlEditError.tooLarge),
      );
      expect(oversized.body, withBom.replaceFirst('#', '#x'));
      expect(
        () => LocalYamlEdit('${exact}x'),
        fails(LocalYamlEditError.tooLarge),
      );
      expect(editor.body, withBom);
    },
  );

  test('CRLF output budget counts generated carriage returns and keeps the whole original', () {
    const seed = '﻿rules:\r\n  - MATCH,DIRECT\r\n';
    final small = LocalYamlEdit(seed).addRule('MATCH,REJECT');
    final padding = LocalYamlEdit.maxBytes - utf8.encode(small).length;
    final original = '$seed#${'x' * (padding - 3)}\r\n';
    final editor = LocalYamlEdit(original);
    final exact = editor.addRule('MATCH,REJECT');
    expect(utf8.encode(exact).length, LocalYamlEdit.maxBytes);
    expect(exact.replaceFirst('  - "MATCH,REJECT"\r\n', ''), original);
    final plusOne = LocalYamlEdit(original.replaceFirst('#', '#x'));
    expect(
      () => plusOne.addRule('MATCH,REJECT'),
      fails(LocalYamlEditError.tooLarge),
    );
    expect(plusOne.body, original.replaceFirst('#', '#x'));
  });

  test('does not allocate semantic protocol/provider resources or reject references', () {
    final result = LocalYamlEdit('{}').addProxy({
      'name': 'A',
      'type': 'unregistered-protocol-left-to-core',
      'server': 'not-a-host',
      'unknown-nested': {'untouched': false},
    });
    expect(
      decodeYaml(result)['proxies'].single['type'],
      'unregistered-protocol-left-to-core',
    );
    expect(
      decodeYaml(
        LocalYamlEdit(result).addRule('RULE-SET,Missing,AlsoMissing'),
      )['rules'],
      ['RULE-SET,Missing,AlsoMissing'],
    );
  });

  test(
    'package boundary: public YamlEditor rejects a parent containing aliases',
    () {
      const body =
          'defaults: &d {type: inline, payload: []}\n'
          'proxy-providers: {Existing: *d}\n';
      final editor = YamlEditor(body);
      expect(
        () => editor.update(['proxy-providers', 'New'], {'type': 'inline'}),
        throwsA(isA<AliasException>()),
      );
      expect(editor.toString(), body);
      expect(editor.edits, isEmpty);
    },
  );
}

void groupTests(LocalYamlSection section) {
  group(section.key, () {
    final value = section == LocalYamlSection.rules ? 'MATCH,DIRECT' : 'A';
    test('adds its own definition without touching unknown data', () {
      const unknown =
          '# preserved\nunknown: {nested: ["01", null, false]} # tail\n';
      final editor = LocalYamlEdit(unknown);
      final result = add(editor, section, value);
      expect(result, contains('# preserved\n'));
      expect(result, contains(unknown.substring('# preserved\n'.length)));
      final direct = LocalYamlEdit(result).definitions(section);
      expect(direct.single.value, value);
      expect(direct.single.path.first, section.key);
      expect(decodeYaml(result).length, 2);
      expect(editor.body, unknown);
    });

    test('adds into an existing list/map without encoding its old entry', () {
      final existing = switch (section) {
        LocalYamlSection.proxies || LocalYamlSection.strategyGroups =>
          '${section.key}:\n  - {name: Old, type: "direct", unknown: [01, null]} # exact\n',
        LocalYamlSection.proxyProviders || LocalYamlSection.ruleProviders =>
          '${section.key}:\n  Old: {type: "inline", unknown: [01, null]} # exact\n',
        LocalYamlSection.rules => 'rules:\n  - MATCH,Old # exact\n',
      };
      final result = add(LocalYamlEdit(existing), section, value);
      expect(result, contains(existing.substring(existing.indexOf('\n') + 1)));
      final definitions = LocalYamlEdit(result).definitions(section);
      expect(definitions.length, 2);
      expect(definitions.map((item) => item.value), contains(value));
    });

    test(
      'deletes exactly its direct definition and leaves other sections alone',
      () {
        final body = add(
          LocalYamlEdit('unknown: {nested: keep}\n'),
          section,
          value,
        );
        final editor = LocalYamlEdit(body);
        final direct = editor.definitions(section);
        final result = editor.remove(direct.single);
        expect(decodeYaml(result)['unknown'], {'nested': 'keep'});
        expect(result, contains('unknown: {nested: keep}\n'));
        expect(LocalYamlEdit(result).definitions(section), isEmpty);
        expect(editor.body, body);
      },
    );

    test('empty mapping does not require a root rewrite', () {
      final result = add(
        LocalYamlEdit('{  } # preserve inline root\n'),
        section,
        value,
      );
      expect(result.startsWith('{  '), isTrue);
      expect(result.endsWith('} # preserve inline root\n'), isTrue);
      expect(LocalYamlEdit(result).definitions(section).single.value, value);
    });

    test('wrong target shape is rejected instead of overwritten', () {
      final body = '${section.key}: null # do not overwrite\n';
      final editor = LocalYamlEdit(body);
      expect(
        () => add(editor, section, value),
        fails(LocalYamlEditError.invalidStructure),
      );
      expect(editor.body, body);
    });

    if (section != LocalYamlSection.rules) {
      test(
        'same-name insert rejected, independent document same name allowed',
        () {
          final body = add(LocalYamlEdit('{}'), section, value);
          final editor = LocalYamlEdit(body);
          expect(
            () => add(editor, section, value),
            fails(LocalYamlEditError.duplicateName),
          );
          expect(editor.body, body);
          final independentlyAdded = add(LocalYamlEdit('{}'), section, value);
          expect(
            LocalYamlEdit(independentlyAdded).definitions(section).single.value,
            value,
          );
          expect(() => add(editor, section, 'a'), returnsNormally);
        },
      );
    }

    if (section == LocalYamlSection.proxies ||
        section == LocalYamlSection.strategyGroups) {
      test('already duplicated/missing/non-string names refuse editing', () {
        for (final entries in [
          '[{name: A, type: direct}, {name: A, type: http}]',
          '[{type: direct}]',
          '[{name: 1, type: direct}]',
          '[null]',
        ]) {
          final editor = LocalYamlEdit('${section.key}: $entries\n');
          expect(
            () => add(editor, section, 'B'),
            throwsA(isA<LocalYamlEditException>()),
          );
          expect(
            () => editor.definitions(section),
            throwsA(isA<LocalYamlEditException>()),
          );
        }
        for (final definition in <Map<String, Object?>>[
          {},
          {'name': ''},
          {'name': 1},
        ]) {
          final editor = LocalYamlEdit('{}');
          expect(
            () => section == LocalYamlSection.proxies
                ? editor.addProxy(definition)
                : editor.addStrategyGroup(definition),
            fails(LocalYamlEditError.invalidStructure),
          );
        }
      });
    }
  });

  group('direct named replacements', () {
    test('definitionValue is the raw field map, not a runtime projection', () {
      final editor = LocalYamlEdit('''# top
proxy-groups:
  - name: A
    type: select
    proxies:
      - DIRECT
    hidden: false
    unknown-field:
      nested: 0
    empty: ""
''');
      final definition = editor
          .definitions(LocalYamlSection.strategyGroups)
          .where((item) => item.value == 'A')
          .firstOrNull;
      expect(definition, isNotNull);
      expect(editor.definitionValue(definition!), {
        'name': 'A',
        'type': 'select',
        'proxies': ['DIRECT'],
        'hidden': false,
        'unknown-field': {'nested': 0},
        'empty': '',
      });
      expect(
        editor
            .definitions(LocalYamlSection.strategyGroups)
            .where((item) => item.value == 'missing')
            .firstOrNull,
        isNull,
      );
    });

    test('in-place replacement keeps list position, comments and siblings', () {
      const body = '''# preserve
proxy-groups:
  # first comment
  - name: first
    type: url-test
    proxies: [DIRECT]
  # second comment
  - name: second
    type: select
    proxies: [DIRECT]
  - name: third
    type: fallback
    proxies: [DIRECT]
''';
      final editor = LocalYamlEdit(body);
      final target = editor
          .definitions(LocalYamlSection.strategyGroups)
          .where((item) => item.value == 'second')
          .firstOrNull!;
      final value = editor.definitionValue(target);
      final changed = editor.replaceNamed(target, {
        ...value,
        'name': 'renamed',
        'unknown-specific': {'keep': true},
      });
      expect(changed, contains('# preserve'));
      expect(changed, contains('# first comment'));
      expect(changed, contains('- name: first'));
      expect(changed, contains('# second comment'));
      expect(changed, contains('- name: renamed'));
      expect(changed, contains('- name: third'));
      expect(changed, contains('unknown-specific:'));
      expect(changed.indexOf('renamed'), lessThan(changed.indexOf('third')));
      final parsed = LocalYamlEdit(changed)
          .definitions(LocalYamlSection.strategyGroups);
      expect(parsed.map((definition) => definition.value), [
        'first',
        'renamed',
        'third',
      ]);
    });

    test('replacement rejects duplicate names and unsupported sections', () {
      final editor = LocalYamlEdit('''proxy-groups:
  - {name: A, type: select}
  - {name: B, type: select}
rules:
  - MATCH,DIRECT
''');
      final target = editor
          .definitions(LocalYamlSection.strategyGroups)
          .where((item) => item.value == 'A')
          .firstOrNull!;
      final value = editor.definitionValue(target);
      expect(
        () => editor.replaceNamed(target, {...value, 'name': 'B'}),
        fails(LocalYamlEditError.duplicateName),
      );
      expect(() => editor.replaceNamed(target, value), returnsNormally);
      final rule = editor.definitions(LocalYamlSection.rules).single;
      expect(
        () => editor.replaceNamed(rule, value),
        fails(LocalYamlEditError.unsupportedEdit),
      );
    });

    test(
      'stale body-bound identity and aliased targets refuse replacement',
      () {
        const body = '''proxy-groups:
  - &shared {name: A, type: select}
  - {name: B, type: select}
proxies:
  - *shared
''';
        final editor = LocalYamlEdit(
          'proxy-groups:\n  - {name: A, type: select}\n',
        );
        final target = editor
            .definitions(LocalYamlSection.strategyGroups)
            .where((item) => item.value == 'A')
            .firstOrNull!;
        final value = editor.definitionValue(target);
        final other = LocalYamlEdit(body);
        final stale = other
            .definitions(LocalYamlSection.strategyGroups)
            .where((item) => item.value == 'A')
            .firstOrNull!;
        expect(
          () => editor.replaceNamed(stale, value),
          fails(LocalYamlEditError.staleDefinition),
        );
        expect(
          () => other.replaceNamed(stale, value),
          fails(LocalYamlEditError.aliasTarget),
        );
      },
    );

    test('merge-backed direct fields are not presented as complete source', () {
      final editor = LocalYamlEdit('''proxy-groups:
  - name: A
    type: select
    <<: {proxies: [DIRECT]}
''');
      final target = editor
          .definitions(LocalYamlSection.strategyGroups)
          .where((item) => item.value == 'A')
          .firstOrNull!;
      expect(
        () => editor.definitionValue(target),
        fails(LocalYamlEditError.inheritedTarget),
      );
      expect(
        () => editor.replaceNamed(target, {
          'name': 'A',
          'type': 'select',
          'proxies': ['DIRECT'],
        }),
        fails(LocalYamlEditError.inheritedTarget),
      );
    });
  });
}
