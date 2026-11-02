import 'dart:convert';

import 'package:clash_pseudo/src/logic/overrides/loon_converter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('content recognition and YAML pass-through', () {
    for (final source in [
      '{}',
      '# kept\nrules: []\n',
      '\uFEFF# 中文\r\nrules:\r\n - DOMAIN,example.test,DIRECT\nunknown: null\r',
      '---\nanchors: &item {name: x}\ncopy: *item\n...\n',
      '{rules: ["DOMAIN,example.test,DIRECT"], enabled: false}',
      '# [Rule] is only a comment\ntext: |\n  [Rule]\n  FINAL,DIRECT\n',
      '? [Rule]\n: literal YAML key\n',
    ]) {
      test('preserves mapping ${source.length} / ${source.hashCode}', () {
        final converted = convertLoonOverride(
          source,
          proxyName: 'ignored,even\ninvalid',
          addNoResolve: true,
        );
        expect(converted.body, source);
        expect(converted.isLoon, isFalse);
        expect(converted.ruleCount, 0);
        expect(converted.commentCount, 0);
        expect(utf8.encode(converted.body), utf8.encode(source));
      });
    }

    for (final source in [
      '',
      '# comments only\n',
      'plain text',
      '- DOMAIN,example.test,DIRECT\n',
      'rules: [broken\n[Rule]\nDOMAIN,example.test,DIRECT',
      'rules:\n  - [Rule]\n  broken: [\n',
      'rules: []\nrules: []\n',
      '{}\n---\n{}\n',
      '---\n[Rule]\nDOMAIN,example.test,DIRECT\n',
      '# metadata\nDOMAIN,example.test,DIRECT\n[Rule]\n',
      '[Rule] trailing junk\nDOMAIN,example.test,DIRECT',
      '[1,2,3]\n',
    ]) {
      test('rejects nonmapping or broken YAML ${source.hashCode}', () {
        expect(
          () => convertLoonOverride(source, proxyName: 'fallback'),
          failsWith(LoonConversionError.invalidYaml),
        );
      });
    }

    test('only first nonblank noncomment content selects Loon', () {
      final result = convertLoonOverride(
        '\uFEFF\n #!name=最小转换示例\r\n; comment\n// comment\n'
        '[General] # inert\nname = demo\n[Rule]\n'
        'DOMAIN,example.test,DIRECT\n',
      );
      expect(result.isLoon, isTrue);
      expect(result.body.startsWith('\uFEFF# Loon:'), isTrue);
      expect(rulesOf(result), ['DOMAIN,example.test,DIRECT']);
      expect(result.body, contains('# name = demo\n'));
      expect(result.body, contains('#  #!name=最小转换示例\n'));
    });
  });

  group('section isolation and source preservation', () {
    // Self-authored conversion input with reserved example URLs.
    test('only Rule sections contribute, in original order', () {
      const fixture =
          '#!name=转换示例\n'
          '#!homepage=https://metadata.invalid/never-fetch\n'
          '[Rule]\nDOMAIN,first.test,DIRECT\n'
          '[Argument]\nDOMAIN,argument.test,DIRECT\n'
          '[General]\nDOMAIN,general.test,DIRECT\n'
          '[Host]\nDOMAIN,host.test,DIRECT\n'
          '[Script]\nDOMAIN,script.test,DIRECT\n'
          'http-response https://invalid.test script-path=x.js\n'
          '[Rewrite]\nDOMAIN,rewrite.test,DIRECT\n'
          '[MITM]\nhostname = *\nDOMAIN,mitm.test,DIRECT\n'
          '[IP Rewrite]\nDOMAIN,ip-rewrite.test,DIRECT\n'
          '[Unknown.Custom]\nDOMAIN,unknown.test,DIRECT\n'
          '[未知区段]\nDOMAIN,unicode-section.test,DIRECT\n'
          '[Rule]\nDOMAIN,last.test,DIRECT\n'
          'DOMAIN,last.test,DIRECT\n';
      final result = convertLoonOverride(fixture);
      expect(rulesOf(result), [
        'DOMAIN,first.test,DIRECT',
        'DOMAIN,last.test,DIRECT',
        'DOMAIN,last.test,DIRECT',
      ]);
      for (final original
          in fixture.split('\n').where((line) => line.isNotEmpty)) {
        if (original == 'DOMAIN,first.test,DIRECT' ||
            original == 'DOMAIN,last.test,DIRECT') {
          continue;
        }
        expect(result.body, contains('# $original\n'), reason: original);
      }
      expect(
        RegExp(r'^rules:$', multiLine: true).allMatches(result.body).length,
        1,
      );
      expect(result.commentCount, 24);
    });

    test('malformed section-like boundaries also stop rule extraction', () {
      final result = convertLoonOverride(
        '[Rule]\nDOMAIN,before.test,DIRECT\n'
        '[Script] unexpected suffix\nDOMAIN,not-a-rule.test,DIRECT\n'
        '[Rule]\nDOMAIN,after.test,DIRECT\n',
      );
      expect(rulesOf(result), [
        'DOMAIN,before.test,DIRECT',
        'DOMAIN,after.test,DIRECT',
      ]);
      expect(result.body, contains('# DOMAIN,not-a-rule.test,DIRECT\n'));
    });

    test('all unknown sections and final unsupported rules remain visible', () {
      final result = convertLoonOverride(
        '[Not A Known Section]\nraw content with 中文\n'
        '[Rule]\nFINAL,DIRECT\nRULE-SET,https://external.invalid/a,PROXY\n'
        'DOMAIN-SET,https://external.invalid/b,PROXY\n'
        'USER-AGENT,Example*,DIRECT\nURL-REGEX,^https://.*,DIRECT\n'
        'PROTOCOL,HTTP,DIRECT\nPROCESS-NAME,example,DIRECT\n'
        'UNKNOWN,anything,DIRECT\n',
      );
      expect(rulesOf(result), isEmpty);
      expect(loadYaml(result.body), isEmpty);
      expect(result.body.endsWith('{}\n'), isTrue);
      expect(result.body, isNot(contains('rules: []')));
      expect(result.body, contains('# raw content with 中文\n'));
      expect(result.body, contains('# FINAL,DIRECT\n'));
      expect(
        result.body,
        contains('# RULE-SET,https://external.invalid/a,PROXY\n'),
      );
      expect(result.commentCount, 11);
    });

    test('unproven continuation never turns its next line into a rule', () {
      final result = convertLoonOverride(
        '[Rule]\nDOMAIN,one.test,PROXY \\\n'
        'DOMAIN,two.test,DIRECT \\\n'
        'DOMAIN,three.test,DIRECT\n'
        'DOMAIN,real.test,DIRECT\n',
      );
      expect(rulesOf(result), ['DOMAIN,real.test,DIRECT']);
      expect(result.body, contains('# DOMAIN,one.test,PROXY \\\n'));
      expect(result.body, contains('# DOMAIN,three.test,DIRECT\n'));
    });

    test('unclosed multiline logic cannot leak a standalone-looking child', () {
      final result = convertLoonOverride(
        '[Rule]\nAND,((DOMAIN,first.test),\n'
        'DOMAIN,continuation.test,DIRECT\n),DIRECT\n'
        'DOMAIN,real.test,DIRECT\n',
      );
      expect(rulesOf(result), ['DOMAIN,real.test,DIRECT']);
      expect(result.body, contains('# AND,((DOMAIN,first.test),\n'));
      expect(result.body, contains('# DOMAIN,continuation.test,DIRECT\n'));
      expect(result.body, contains('# ),DIRECT\n'));
    });

    test('a new section resets an unfinished logical continuation', () {
      final result = convertLoonOverride(
        '[Rule]\nAND,((DOMAIN,first.test),\n'
        'DOMAIN,not-a-standalone-rule.test,DIRECT\n'
        '[Script]\nDOMAIN,also-inert.test,DIRECT\n'
        '[Rule]\nDOMAIN,recovered.test,DIRECT\n',
      );
      expect(rulesOf(result), ['DOMAIN,recovered.test,DIRECT']);
      expect(
        result.body,
        contains('# DOMAIN,not-a-standalone-rule.test,DIRECT\n'),
      );
      expect(result.body, contains('# DOMAIN,also-inert.test,DIRECT\n'));
    });

    test('a comment ending in backslash does not consume a real rule', () {
      final result = convertLoonOverride(
        '[Rule]\n# not a continuation \\\n'
        'DOMAIN,real.test,DIRECT\n',
      );
      expect(rulesOf(result), ['DOMAIN,real.test,DIRECT']);
      expect(result.body, contains('# # not a continuation \\\n'));
    });

    test(
      'comments, blank lines, indentation and CRLF do not reorder rules',
      () {
        final result = convertLoonOverride(
          '[Rule]\r\n\r\n # visible comment\r\n'
          ' \tDOMAIN , example.test , DIRECT\t \r\n'
          '; another comment\rDOMAIN-SUFFIX,example.test,DIRECT',
        );
        expect(rulesOf(result), [
          'DOMAIN,example.test,DIRECT',
          'DOMAIN-SUFFIX,example.test,DIRECT',
        ]);
        expect(result.commentCount, 3);
        expect(result.body, contains('# \n#  # visible comment\n'));
      },
    );
  });

  group('supported literal conditions', () {
    const examples = {
      'DOMAIN,example.test,DIRECT': 'DOMAIN,example.test,DIRECT',
      'DOMAIN,例子.测试,DIRECT': 'DOMAIN,例子.测试,DIRECT',
      'DOMAIN-SUFFIX,.example.test,DIRECT':
          'DOMAIN-SUFFIX,.example.test,DIRECT',
      'DOMAIN-KEYWORD,ads,DIRECT': 'DOMAIN-KEYWORD,ads,DIRECT',
      'DOMAIN-WILDCARD,*.ad?.example-test_1.test,DIRECT':
          'DOMAIN-WILDCARD,*.ad?.example-test_1.test,DIRECT',
      'IP-CIDR,192.0.2.7/24,DIRECT': 'IP-CIDR,192.0.2.7/24,DIRECT',
      'IP-CIDR,0.0.0.0/0,DIRECT': 'IP-CIDR,0.0.0.0/0,DIRECT',
      'IP-CIDR,255.255.255.255/32,DIRECT': 'IP-CIDR,255.255.255.255/32,DIRECT',
      'IP-CIDR6,::/0,DIRECT': 'IP-CIDR6,::/0,DIRECT',
      'IP-CIDR6,2001:DB8::1/128,DIRECT': 'IP-CIDR6,2001:DB8::1/128,DIRECT',
      'IP-CIDR6,::ffff:192.0.2.1/128,DIRECT':
          'IP-CIDR6,::ffff:192.0.2.1/128,DIRECT',
      'GEOIP,CN,DIRECT': 'GEOIP,CN,DIRECT',
      'GEOIP,LAN,DIRECT': 'GEOIP,LAN,DIRECT',
      'GEOIP,PRIVATE,DIRECT': 'GEOIP,PRIVATE,DIRECT',
      'IP-ASN,0,DIRECT': 'IP-ASN,0,DIRECT',
      'IP-ASN,4134,DIRECT': 'IP-ASN,4134,DIRECT',
      'IP-ASN,4294967295,DIRECT': 'IP-ASN,4294967295,DIRECT',
      'SRC-PORT,0,DIRECT': 'SRC-PORT,0,DIRECT',
      'SRC-PORT,80-443,DIRECT': 'SRC-PORT,80-443,DIRECT',
      'DEST-PORT,65535,DIRECT': 'DST-PORT,65535,DIRECT',
      'DEST-PORT,0-65535,DIRECT': 'DST-PORT,0-65535,DIRECT',
      'DEST-PORT,>=443,DIRECT': 'DST-PORT,443-65535,DIRECT',
      'SRC-PORT,>=0,DIRECT': 'SRC-PORT,0-65535,DIRECT',
      'DEST-PORT,>=65535,DIRECT': 'DST-PORT,65535-65535,DIRECT',
    };
    for (final entry in examples.entries) {
      test(entry.key, () {
        expect(rulesOf(one(entry.key)), [entry.value]);
      });
    }
  });

  group('invalid or unproven conditions retain the complete source', () {
    for (final rule in [
      'DOMAIN-WILDCARD,*.例子.test,DIRECT',
      'DOMAIN-WILDCARD,ad[0-9].test,DIRECT',
      'DOMAIN-WILDCARD,{ad,ads}.test,DIRECT',
      r'DOMAIN-WILDCARD,ad\*.test,DIRECT',
      'DOMAIN-WILDCARD,[a-z],DIRECT',
      'DOMAIN,a b.test,DIRECT',
      'DOMAIN,https://example.test,DIRECT',
      'DOMAIN,*.example.test,DIRECT',
      'DOMAIN,{{{domain}}},DIRECT',
      'DOMAIN,example.test,DIRECT,unknown-parameter',
      'DOMAIN,example.test,DIRECT,no-resolve',
      'DOMAIN,example.test,,DIRECT',
      'DOMAIN,,DIRECT',
      'domain,example.test,DIRECT',
      'IP-CIDR,::1/128,DIRECT',
      'IP-CIDR6,192.0.2.1/32,DIRECT',
      'IP-CIDR,192.0.2.1/33,DIRECT',
      'IP-CIDR,192.0.2.1/-1,DIRECT',
      'IP-CIDR,192.0.2.1/+1,DIRECT',
      'IP-CIDR,192.0.2.1,DIRECT',
      'IP-CIDR,192.0.2.1/1/2,DIRECT',
      'IP-CIDR,256.0.2.1/24,DIRECT',
      'IP-CIDR,192.000.2.1/24,DIRECT',
      'IP-CIDR,192.0.2/24,DIRECT',
      'IP-CIDR,0xc0000201/24,DIRECT',
      'IP-CIDR6,2001:db8::1/129,DIRECT',
      'IP-CIDR6,2001:db8:::1/64,DIRECT',
      'IP-CIDR6,gggg::1/64,DIRECT',
      'IP-CIDR6,[::1]/128,DIRECT',
      'IP-CIDR6,fe80::1%eth0/64,DIRECT',
      'IP-CIDR6,::ffff:192.000.2.1/128,DIRECT',
      'IP-ASN,AS4134,DIRECT',
      'IP-ASN,04134,DIRECT',
      'IP-ASN,-1,DIRECT',
      'IP-ASN,4294967296,DIRECT',
      'IP-ASN,1.10,DIRECT',
      'IP-ASN,1e2,DIRECT',
      'IP-ASN,+4134,DIRECT',
      'GEOIP,!CN,DIRECT',
      'GEOIP,{{{country}}},DIRECT',
      'DEST-PORT,>443,DIRECT',
      'DEST-PORT,<443,DIRECT',
      'DEST-PORT,<=443,DIRECT',
      'DEST-PORT,65536,DIRECT',
      'DEST-PORT,443-80,DIRECT',
      'DEST-PORT,-1,DIRECT',
      'DEST-PORT,80-443-8080,DIRECT',
      'DEST-PORT,80/443,DIRECT',
      'DEST-PORT,>=65536,DIRECT',
      'DEST-PORT,80 - 443,DIRECT',
      'SRC-IP-CIDR,192.0.2.0/24,DIRECT',
      'DST-PORT,443,DIRECT',
      'FINAL,DIRECT',
      'MATCH,DIRECT',
    ]) {
      test(rule, () {
        final result = one(rule, proxyName: 'Replacement', addNoResolve: true);
        expect(rulesOf(result), isEmpty);
        expect(result.body, contains('# $rule\n'));
        expect(loadYaml(result.body), isEmpty);
        expect(result.body, isNot(contains('rules: []')));
      });
    }
  });

  group('targets and native rejection', () {
    for (final target in [
      'DIRECT',
      'REJECT',
      'REJECT-DROP',
      'COMPATIBLE',
      'PASS',
      'PASS-RULE',
      'GLOBAL',
    ]) {
      test('builtin $target is never overridden', () {
        expect(
          rulesOf(one('DOMAIN,example.test,$target', proxyName: 'Chosen')),
          ['DOMAIN,example.test,$target'],
        );
      });
    }
    for (final action in [
      'REJECT',
      'REJECT-IMG',
      'REJECT-DICT',
      'REJECT-ARRAY',
    ]) {
      test(
        '$action preserves blocking intent and comments original action',
        () {
          final result = one(
            'DOMAIN,example.test,$action',
            proxyName: 'Chosen',
          );
          expect(rulesOf(result), ['DOMAIN,example.test,REJECT']);
          expect(result.body, contains('# DOMAIN,example.test,$action\n'));
          expect(result.body, contains('# Loon action $action -> REJECT:'));
          expect(result.commentCount, 2);
        },
      );
    }
    test('REJECT-DROP stays native and has no response-emulation note', () {
      final result = one('DOMAIN,example.test,REJECT-DROP');
      expect(rulesOf(result), ['DOMAIN,example.test,REJECT-DROP']);
      expect(result.body, isNot(contains('Loon action')));
      expect(result.commentCount, 1);
    });

    for (final target in [
      'PROXY',
      'My Proxy',
      'dns',
      'direct',
      'REJECT-UNKNOWN',
      '节点甲',
      'Hong Kong (01)',
      r'Path\Name',
    ]) {
      test('nonbuiltin $target is retained by default and can be replaced', () {
        expect(rulesOf(one('DOMAIN,example.test,$target')), [
          'DOMAIN,example.test,$target',
        ]);
        expect(
          rulesOf(
            one('DOMAIN,example.test,$target', proxyName: '  不在当前配置中的名称  '),
          ),
          ['DOMAIN,example.test,不在当前配置中的名称'],
        );
      });
    }
    test(
      'blank replacement keeps explicit targets and comments omitted targets',
      () {
        final result = convertLoonOverride(
          '[Rule]\nDOMAIN,explicit.test,PROXY\nDOMAIN,missing.test\n'
          'IP-CIDR,192.0.2.0/24,no-resolve\n',
          proxyName: '   ',
        );
        expect(rulesOf(result), ['DOMAIN,explicit.test,PROXY']);
        expect(result.body, contains('# DOMAIN,missing.test\n'));
        expect(result.body, contains('# IP-CIDR,192.0.2.0/24,no-resolve\n'));
      },
    );
    test('replacement fills only omitted/custom targets, never DIRECT', () {
      final result = convertLoonOverride(
        '[Rule]\nDOMAIN,missing.test\nIP-CIDR,192.0.2.0/24,no-resolve\n'
        'DOMAIN,explicit.test,PROXY\nDOMAIN,direct.test,DIRECT\n',
        proxyName: 'Chosen',
      );
      expect(rulesOf(result), [
        'DOMAIN,missing.test,Chosen',
        'IP-CIDR,192.0.2.0/24,Chosen,no-resolve',
        'DOMAIN,explicit.test,Chosen',
        'DOMAIN,direct.test,DIRECT',
      ]);
    });
    test(
      'explicit form names are YAML quoted without losing Unicode or quotes',
      () {
        const name = '节点 🧭: O\'Reilly #1 "quoted"';
        final result = one('DOMAIN,example.test,PROXY', proxyName: name);
        expect(rulesOf(result), ['DOMAIN,example.test,$name']);
        expect(result.body, contains(r'\"quoted\"'));
        expect(result.body, contains('节点 🧭'));
      },
    );
    for (final name in ['a(b)', 'unbalanced(', r'a\b']) {
      test(
        'literal name punctuation is not confused with condition syntax $name',
        () {
          final result = one('DOMAIN,example.test,PROXY', proxyName: name);
          expect(rulesOf(result), ['DOMAIN,example.test,$name']);
          final logical = one(
            'NOT,((DOMAIN,example.test)),PROXY',
            proxyName: name,
          );
          expect(rulesOf(logical), ['NOT,((DOMAIN,example.test)),$name']);
        },
      );
    }
    for (final name in [
      'a,b',
      'a\nb',
      'a\rb',
      'a\tb',
      'a\u0085b',
      'a\u2028b',
      'a\u2029b',
      'a\u0000b',
      'a\uFEFFb',
      String.fromCharCode(0x202E),
      String.fromCharCode(0xD800),
    ]) {
      test('unrepresentable form name ${name.codeUnits} fails explicitly', () {
        expect(
          () => one('DOMAIN,example.test,DIRECT', proxyName: name),
          failsWith(LoonConversionError.invalidProxyName),
        );
      });
    }
    for (final rule in [
      'DOMAIN,example.test,"name,with,commas"',
      "DOMAIN,example.test,'name,with,commas'",
      'DOMAIN,"example,test",DIRECT',
      'DOMAIN,example.test,name,unexpected',
      'DOMAIN,example.test,"Quoted Proxy"',
      'DOMAIN,example.test,Proxy # comment',
      'DOMAIN,example.test,{{{proxy}}}',
      'DOMAIN,example.test,Proxy\u0001Name',
    ]) {
      test(
        'ambiguous source target is not repaired by replacement ${rule.hashCode}',
        () {
          final result = one(rule, proxyName: 'Chosen');
          expect(rulesOf(result), isEmpty);
          expect(result.commentCount, 2);
        },
      );
    }
  });

  group('no-resolve leaf behavior', () {
    for (final condition in [
      'IP-CIDR,192.0.2.0/24',
      'IP-CIDR6,2001:db8::/32',
      'GEOIP,CN',
      'IP-ASN,4134',
    ]) {
      test(
        '$condition defaults off, adds only once, retains explicit flags',
        () {
          expect(rulesOf(one('$condition,DIRECT')), ['$condition,DIRECT']);
          expect(rulesOf(one('$condition,DIRECT', addNoResolve: true)), [
            '$condition,DIRECT,no-resolve',
          ]);
          for (final option in [false, true]) {
            expect(
              rulesOf(
                one('$condition,DIRECT,no-resolve', addNoResolve: option),
              ),
              ['$condition,DIRECT,no-resolve'],
            );
          }
        },
      );
    }
    test('never adds flags to domain or port conditions', () {
      final result = convertLoonOverride(
        '[Rule]\nDOMAIN,example.test,DIRECT\nSRC-PORT,80,DIRECT\n'
        'DEST-PORT,>=443,DIRECT\n',
        addNoResolve: true,
      );
      expect(rulesOf(result), [
        'DOMAIN,example.test,DIRECT',
        'SRC-PORT,80,DIRECT',
        'DST-PORT,443-65535,DIRECT',
      ]);
      expect(result.body, isNot(contains('no-resolve')));
    });
    for (final rule in [
      'IP-CIDR,192.0.2.0/24,DIRECT,no-resolve,no-resolve',
      'IP-CIDR,192.0.2.0/24,no-resolve,DIRECT',
      'IP-CIDR,192.0.2.0/24,DIRECT,extended-matching',
      'IP-CIDR,192.0.2.0/24,DIRECT,NO-RESOLVE',
    ]) {
      test('unsupported/repeated/misplaced parameter is inert $rule', () {
        expect(rulesOf(one(rule, addNoResolve: true)), isEmpty);
      });
    }
  });

  group('logical expressions are atomic and structurally faithful', () {
    test(
      'AND/OR preserve children, order and only destination IP leaf flags',
      () {
        const source =
            'AND,((DOMAIN-SUFFIX,example.test),'
            '(OR,((DEST-PORT,>=443),(IP-CIDR6,2001:db8::/32))),'
            '(GEOIP,CN,no-resolve),(IP-ASN,4134)),PROXY';
        expect(rulesOf(one(source)), [
          'AND,((DOMAIN-SUFFIX,example.test),'
              '(OR,((DST-PORT,443-65535),(IP-CIDR6,2001:db8::/32))),'
              '(GEOIP,CN,no-resolve),(IP-ASN,4134)),PROXY',
        ]);
        expect(rulesOf(one(source, proxyName: 'Chosen', addNoResolve: true)), [
          'AND,((DOMAIN-SUFFIX,example.test),'
              '(OR,((DST-PORT,443-65535),(IP-CIDR6,2001:db8::/32,no-resolve))),'
              '(GEOIP,CN,no-resolve),(IP-ASN,4134,no-resolve)),Chosen',
        ]);
      },
    );
    test('NOT has one actual parsed child, including no-resolve inside leaf', () {
      final result = one(
        'NOT,((IP-CIDR,192.0.2.0/24)),DIRECT',
        addNoResolve: true,
      );
      final rule = rulesOf(result).single;
      expect(rule, 'NOT,((IP-CIDR,192.0.2.0/24,no-resolve)),DIRECT');
      // Require the outer group and nested child parentheses used by the public
      // parser.
      expect(logicalChildren(rule), ['IP-CIDR,192.0.2.0/24,no-resolve']);
    });
    test('nested NOT keeps its complete AND rather than negating one leaf', () {
      const source =
          'NOT,((AND,((DOMAIN-SUFFIX,example.test),'
          '(DEST-PORT,443),(GEOIP,CN)))),REJECT-IMG';
      final result = one(source, addNoResolve: true);
      final rule = rulesOf(result).single;
      expect(
        rule,
        'NOT,((AND,((DOMAIN-SUFFIX,example.test),'
        '(DST-PORT,443),(GEOIP,CN,no-resolve)))),REJECT',
      );
      final children = logicalChildren(rule);
      expect(children, [
        'AND,((DOMAIN-SUFFIX,example.test),'
            '(DST-PORT,443),(GEOIP,CN,no-resolve))',
      ]);
      expect(logicalChildren('${children.single},DIRECT'), [
        'DOMAIN-SUFFIX,example.test',
        'DST-PORT,443',
        'GEOIP,CN,no-resolve',
      ]);
      expect(result.body, contains('# $source\n'));
    });
    test('omitted logical target uses name only when explicitly provided', () {
      const rule = 'OR,((DOMAIN,example.test),(DEST-PORT,443))';
      expect(rulesOf(one(rule)), isEmpty);
      expect(rulesOf(one(rule, proxyName: 'Chosen')), [
        'OR,((DOMAIN,example.test),(DST-PORT,443)),Chosen',
      ]);
    });
    for (final rule in [
      'AND,((DOMAIN,example.test),(URL-REGEX,^https://.*)),DIRECT',
      'OR,((DOMAIN,example.test),(SRC-IP-CIDR,192.0.2.0/24)),DIRECT',
      'NOT,((PROTOCOL,HTTP)),DIRECT',
      'NOT,((DOMAIN,one.test),(DOMAIN,two.test)),DIRECT',
      'NOT,(DOMAIN,example.test),DIRECT',
      'NOT,(),DIRECT',
      'NOT,(()),DIRECT',
      'AND,(),DIRECT',
      'OR,((DOMAIN,example.test),),DIRECT',
      'AND,((DOMAIN,example.test,DIRECT),(GEOIP,CN)),DIRECT',
      'AND,((DOMAIN,example.test,no-resolve),(GEOIP,CN)),DIRECT',
      'AND,((DOMAIN,example.test),(IP-CIDR,192.0.2.0/33)),DIRECT',
      'AND,((DOMAIN,example.test),(NOT,(GEOIP,CN))),DIRECT',
      'AND,((DOMAIN,example.test),(GEOIP,CN)),DIRECT,no-resolve',
      'AND,((DOMAIN,example.test)(GEOIP,CN)),DIRECT',
      'AND,((DOMAIN,example.test),(GEOIP,CN)),DIRECT,unknown',
      'AND,((DOMAIN,example.test),(GEOIP,CN),DIRECT',
      'OR,((DOMAIN,example.test),(GEOIP,CN)))),DIRECT',
    ]) {
      test(
        'one incompatible child or malformed structure rejects whole $rule',
        () {
          final result = one(rule, proxyName: 'Chosen', addNoResolve: true);
          expect(rulesOf(result), isEmpty);
          expect(result.body, contains('# $rule\n'));
          expect(result.body, isNot(contains('  - ')));
        },
      );
    }
    test('hostile nesting remains inert without recursive overflow', () {
      var nested = 'DOMAIN,example.test';
      for (var i = 0; i < 512; i++) {
        nested = 'NOT,(($nested))';
      }
      final source = '$nested,DIRECT';
      final result = one(source);
      expect(rulesOf(result), isEmpty);
      expect(result.body, contains('# $source\n'));
    });
  });

  group('Unicode, control characters and safe scalar/comment output', () {
    test('all YAML line endings keep Script and metadata content inert', () {
      final result = convertLoonOverride(
        '#!name=安全注释\u0085[Script]\r\n'
        'script = never-run()\u2028rules: ["MATCH,DIRECT"]\u2029'
        'proxies: [{name: injected}]\r'
        '[MITM]\nhostname = *\u0085'
        '[Rule]\u2028DOMAIN,example.test,DIRECT\u2029',
      );
      final yaml = loadYaml(result.body) as YamlMap;
      expect(yaml.keys, ['rules']);
      expect(rulesOf(result), ['DOMAIN,example.test,DIRECT']);
      expect(result.body, contains('# rules: ["MATCH,DIRECT"]\n'));
      expect(result.body, contains('# proxies: [{name: injected}]\n'));
      expect(result.body, isNot(contains('\u0085')));
      expect(result.body, isNot(contains('\u2028')));
      expect(result.body, isNot(contains('\u2029')));
    });
    test(
      'comment escape attempts, document markers and controls never execute',
      () {
        final hostile =
            '[Script]\n'
            '\u0000\u0001\u000B\u000C\u001B\u007F\u0080\u009F\uFEFF'
            '${String.fromCharCodes([0x202E, 0x2066, 0xFFFE, 0xFFFF])}\n'
            '${String.fromCharCode(0xD800)}\n'
            '${String.fromCharCode(0xDC00)}\n'
            '---\nrules:\n  - MATCH,DIRECT\n...\n'
            '# nested comment\n中文与 emoji 🧭 保持可读\n';
        final result = convertLoonOverride(hostile);
        expect(loadYamlDocuments(result.body), hasLength(1));
        expect(loadYaml(result.body), isEmpty);
        for (final escape in [
          '0000',
          '0001',
          '000B',
          '000C',
          '001B',
          '007F',
          '0080',
          '009F',
          'FEFF',
          '202E',
          '2066',
          'FFFE',
          'FFFF',
          'D800',
          'DC00',
        ]) {
          expect(result.body, contains('\\u$escape'));
        }
        expect(
          result.body,
          contains('# ---\n# rules:\n#   - MATCH,DIRECT\n# ...\n'),
        );
        expect(result.body, contains('# 中文与 emoji 🧭 保持可读\n'));
        expect(result.body, isNot(contains('�')));
      },
    );
    test('invalid controls in a Rule are commented, not silently stripped', () {
      const raw = 'DOMAIN,exa\u0000mple.test,DIRECT';
      final result = one(raw);
      expect(rulesOf(result), isEmpty);
      expect(result.body, contains(r'# DOMAIN,exa\u0000mple.test,DIRECT'));
    });
    test('YAML special characters in names cannot create mapping keys', () {
      const name = '🧭: {rules: []} # &anchor *alias';
      final result = one('DOMAIN,example.test,PROXY', proxyName: name);
      final yaml = loadYaml(result.body) as YamlMap;
      expect(yaml.keys, ['rules']);
      expect(rulesOf(result), ['DOMAIN,example.test,$name']);
    });
    test(
      'conversion is deterministic and final YAML is not converted twice',
      () {
        const source =
            '#!name=示例\n[Rule]\nDOMAIN,a.test,REJECT-ARRAY\n'
            'FINAL,PROXY\n';
        final first = convertLoonOverride(source);
        final second = convertLoonOverride(source);
        expect(second.body, first.body);
        expect(second.ruleCount, first.ruleCount);
        expect(second.commentCount, first.commentCount);
        final again = convertLoonOverride(
          first.body,
          proxyName: 'Ignored',
          addNoResolve: true,
        );
        expect(again.isLoon, isFalse);
        expect(again.body, first.body);
        expect(first.body, isNot(contains('2026')));
      },
    );
    test('failures expose only stable reason, not downloaded text', () {
      const sensitive =
          'https://user:password@invalid.test/?token=secret\nrules: [';
      try {
        convertLoonOverride(sensitive);
        fail('must reject the invalid source');
      } on LoonConversionException catch (error) {
        expect(error.reason, LoonConversionError.invalidYaml);
        expect(error.toString(), 'LoonConversionException(invalidYaml)');
        expect(error.toString(), isNot(contains('password')));
        expect(error.toString(), isNot(contains('secret')));
      }
    });
  });

  group('independent 16 MiB UTF-8 budgets including BOM', () {
    test('exact input limit passes unchanged, one extra byte fails', () {
      const prefix = '\uFEFF# ';
      const suffix = '\n{}\n';
      final source =
          '$prefix${'x' * (maxLoonTextBytes - utf8.encode('$prefix$suffix').length)}$suffix';
      expect(utf8.encode(source).length, maxLoonTextBytes);
      expect(convertLoonOverride(source).body, source);
      expect(
        () => convertLoonOverride('$source '),
        failsWith(LoonConversionError.inputTooLarge),
      );
    });
    test('input budget measures multibyte UTF-8, not Dart code units', () {
      const prefix = '\uFEFF# ';
      const suffix = '\n{}\n';
      final remaining = maxLoonTextBytes - utf8.encode('$prefix$suffix').length;
      final source =
          '$prefix${'中' * (remaining ~/ 3)}${' ' * (remaining % 3)}$suffix';
      expect(source.length, lessThan(maxLoonTextBytes));
      expect(utf8.encode(source).length, maxLoonTextBytes);
      expect(convertLoonOverride(source).body, source);
      expect(
        () => convertLoonOverride('$source中'),
        failsWith(LoonConversionError.inputTooLarge),
      );
    });
    for (final bom in ['', '\uFEFF']) {
      test('exact converted output limit, BOM=${bom.isNotEmpty}', () {
        final overhead =
            utf8.encode(convertLoonOverride('$bom[General]\nx').body).length -
            1;
        final source = '$bom[General]\n${'x' * (maxLoonTextBytes - overhead)}';
        expect(utf8.encode(source).length, lessThan(maxLoonTextBytes));
        final result = convertLoonOverride(source);
        expect(utf8.encode(result.body).length, maxLoonTextBytes);
        expect(loadYaml(result.body), isEmpty);
        expect(
          () => convertLoonOverride('${source}x'),
          failsWith(LoonConversionError.outputTooLarge),
        );
      });
    }
    test(
      'control escaping can exceed output budget while input is much smaller',
      () {
        final source = '[General]\n${'\u0000' * (maxLoonTextBytes ~/ 6)}';
        expect(utf8.encode(source).length, lessThan(maxLoonTextBytes ~/ 2));
        expect(
          () => convertLoonOverride(source),
          failsWith(LoonConversionError.outputTooLarge),
        );
      },
    );
  });
}

Matcher failsWith(LoonConversionError reason) => throwsA(
  isA<LoonConversionException>().having(
    (error) => error.reason,
    'reason',
    reason,
  ),
);

LoonConversionResult one(
  String rule, {
  String proxyName = '',
  bool addNoResolve = false,
}) => convertLoonOverride(
  '[Rule]\n$rule\n',
  proxyName: proxyName,
  addNoResolve: addNoResolve,
);

List<String> rulesOf(LoonConversionResult result) {
  final documents = loadYamlDocuments(result.body);
  expect(documents, hasLength(1));
  final mapping = documents.single.contents as YamlMap;
  final rules = mapping['rules'];
  final values = rules == null
      ? <String>[]
      : (rules as YamlList).cast<String>().toList();
  expect(result.ruleCount, values.length);
  return values;
}

/// Use an independent range scanner for the outer-group/child-group contract.
List<String> logicalChildren(String rule) {
  final payloadStart = rule.indexOf(',') + 1;
  expect(rule[payloadStart], '(');
  final children = <String>[];
  var depth = 0;
  var start = -1;
  for (var i = payloadStart; i < rule.length; i++) {
    if (rule[i] == '(') {
      depth++;
      if (depth == 2) start = i + 1;
    } else if (rule[i] == ')') {
      if (depth == 2) children.add(rule.substring(start, i));
      depth--;
      if (depth == 0) break;
    }
  }
  expect(depth, 0);
  return children;
}
