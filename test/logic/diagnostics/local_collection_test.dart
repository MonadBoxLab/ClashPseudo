import 'dart:convert';

import 'package:clash_pseudo/src/logic/diagnostics/core_collection_page.dart';
import 'package:clash_pseudo/src/model/application_contract.dart';
import 'package:clash_pseudo/src/model/platform_failure.dart';
import 'package:clash_pseudo/src/platform/core/core_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/core_diagnostic_fixture.dart';

Map<String, dynamic> local(
  String path, {
  String name = 'needle',
  int revision = 7,
  String? kind,
}) => {
  'localDefinition': 'snapshot-1$path',
  'entryId': 'custom',
  'revision': revision,
  'definitionPath': path,
  'name': name,
  'type': 'direct',
  'kind': ?kind,
  'definition': {'name': name, 'type': 'direct'},
};

Map<String, dynamic> provenance(
  String path, {
  String id = 'custom',
  int revision = 7,
}) => {
  'contributors': [
    {
      'kind': 'plugin',
      'id': id,
      'revision': revision,
      'name': 'saved',
      'role': 'localCustom',
      'path': path,
    },
  ],
};

void stream(
  CoreDiagnosticFixture fixture,
  String method,
  List<Map<String, dynamic>> rows,
) {
  fixture.script(
    method == 'nodes'
        ? ApplicationContract.coreOperationNodes
        : ApplicationContract.coreOperationRules,
    (request) {
      request.frame(ApplicationContract.coreIpcFrameMetadata, {
        'source': 'native-source',
        if (method == 'rules') ...{
          'origin': 'compiled-rules',
          'scopes': [
            {'kind': 'main', 'name': '', 'count': rows.length},
            {'kind': 'sub', 'name': 'branch', 'count': rows.length},
            {'kind': 'provider', 'name': 'feed', 'count': rows.length},
          ],
        },
      });
      for (final row in rows) {
        request.frame(ApplicationContract.coreIpcFrameRecord, row);
      }
      request.terminal({
        'complete': true,
        'source': 'native-source',
        'recordCount': rows.length,
      });
      request.signalExit();
    },
  );
}

Future<Map> read(
  CoreDiagnosticFixture fixture,
  String method,
  List<Map<String, dynamic>> rows, {
  List<Map<String, dynamic>> definitions = const [],
  String snapshot = 'snapshot-1',
  String search = '',
  int offset = 0,
  String token = '',
  String kind = 'main',
  String? name,
}) async {
  stream(fixture, method, rows);
  final result = await fixture.read(
    method,
    arguments: {
      'query': {
        'offset': offset,
        'limit': 50,
        'search': search,
        'token': token,
        'localIdentity': snapshot,
        'definitions': definitions,
        if (method == 'rules') ...{'kind': kind, 'name': name ?? ''},
        if (method == 'nodes' && name != null) 'source': name,
      },
    },
  );
  return result['page'] as Map;
}

void main() {
  test('阅读身份不参与搜索，也不授予运行对象编辑权', () {
    final definition = {
      ...local('/proxies/0'),
      'readingDefinition': 'private-reading-anchor',
    };
    expect(
      DefinitionRows.matches(definition, 'private-reading-anchor'),
      isFalse,
    );
    final rows = DefinitionRows.merge(
      [
        {'name': 'needle', 'sourceKind': 'configuration'},
      ],
      [definition],
    );
    expect(rows, hasLength(2));
    expect(rows.first.containsKey('localDefinition'), isFalse);
    expect(rows.first.containsKey('readingDefinition'), isFalse);
  });

  diagnosticTest('未完整返回保留实际取消错误与 native receipt', (tester, fixture) async {
    await fixture.warmUp(tester);
    fixture.script(ApplicationContract.coreOperationNodes, (request) {
      request.frame(ApplicationContract.coreIpcFrameMetadata, {
        'source': 'source',
      });
      request.terminal({
        'complete': false,
        'recordCount': 0,
        'source': 'source',
        'cancelError': 'actual cancellation failure',
        'raw': 'unrelated terminal payload',
      });
      request.signalExit(receipt: {'status': 'actual exit'});
    });
    final call = await fixture.client.submit(
      ApplicationContract.coreOperationNodes,
      CoreIdentity(processId: diagnosticSource.processId!),
    );
    await expectLater(
      CoreCollectionPage.read(call, offset: 0, limit: 50, search: ''),
      throwsA(
        isA<PlatformFailure>().having(
          (failure) => failure.details,
          'details',
          allOf(
            containsPair('cancelError', 'actual cancellation failure'),
            containsPair('nativeReceipt', {'status': 'actual exit'}),
            isNot(containsPair('raw', 'unrelated terminal payload')),
          ),
        ),
      ),
    );
  });

  diagnosticTest('节点 stream 先关联再分页，跨页对象不重复', (tester, fixture) async {
    await fixture.warmUp(tester);
    final records = [
      for (var index = 0; index < 120; index++)
        <String, dynamic>{
          'name': index == 99 ? 'needle' : 'node-$index',
          'sourceKind': 'configuration',
          'sourceName': '',
          'type': 'Direct',
          'udp': false,
          'history': <Object>[],
          if (index == 99) 'provenance': provenance('/proxies/0'),
        },
    ];
    final original = jsonEncode(records);
    final definitions = [
      local('/proxies/0'),
      local('/proxies/1', name: 'offline'),
    ];
    final first = await read(
      fixture,
      'nodes',
      records,
      definitions: definitions,
    );
    expect(first['total'], 121);
    expect(first['nodes'], hasLength(50));
    expect(
      (first['nodes'] as List).any(
        (row) => (row as Map).containsKey('localDefinition'),
      ),
      isFalse,
    );
    final middle = await read(
      fixture,
      'nodes',
      records,
      definitions: definitions,
      offset: 50,
      token: first['token'] as String,
    );
    expect(middle['nodes'], hasLength(50));
    final associated = (middle['nodes'] as List).last as Map;
    expect(associated['localDefinition'], definitions.first['localDefinition']);
    expect(associated['type'], 'Direct');
    expect(associated['udp'], isFalse);
    expect(associated.containsKey('raw'), isFalse);
    final last = await read(
      fixture,
      'nodes',
      records,
      definitions: definitions,
      offset: 100,
      token: first['token'] as String,
    );
    expect(last['nodes'], hasLength(21));
    expect(last['nextOffset'], -1);
    expect(((last['nodes'] as List).last as Map).containsKey('raw'), isFalse);
    expect(jsonEncode(records), original);
    expect(
      fixture
          .calls(ApplicationContract.coreOperationNodes)
          .every(
            (request) =>
                !request.arguments.containsKey('definitions') &&
                !request.arguments.containsKey('localIdentity'),
          ),
      isTrue,
    );
  });

  diagnosticTest('统一搜索在关联后计数，旧本地snapshot使分页token失效', (tester, fixture) async {
    await fixture.warmUp(tester);
    final records = [
      for (var index = 0; index < 110; index++)
        <String, dynamic>{
          'name': index == 90 ? 'needle' : 'node-$index',
          'sourceKind': 'configuration',
          'type': 'Direct',
          if (index == 90) 'provenance': provenance('/proxies/0'),
        },
    ];
    final definitions = [
      local('/proxies/0'),
      local('/proxies/1', name: 'offline'),
    ];
    final match = await read(
      fixture,
      'nodes',
      records,
      definitions: definitions,
      search: ' NEEDLE ',
    );
    expect(match['total'], 1);
    expect(match['nodes'], hasLength(1));
    final offline = await read(
      fixture,
      'nodes',
      records,
      definitions: definitions,
      search: 'offline',
    );
    expect(offline['total'], 1);
    expect(
      ((offline['nodes'] as List).single as Map).containsKey('raw'),
      isFalse,
    );
    final first = await read(
      fixture,
      'nodes',
      records,
      definitions: definitions,
    );
    await expectLater(
      read(
        fixture,
        'nodes',
        records,
        definitions: definitions,
        snapshot: 'snapshot-2',
        offset: 50,
        token: first['token'] as String,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  for (final (description, source) in [
    ('同名无provenance', null),
    ('旧revision', provenance('/proxies/0', revision: 6)),
    ('其它entry', provenance('/proxies/0', id: 'another')),
    ('其它path', provenance('/proxies/1')),
  ]) {
    test('$description不授予运行项编辑权', () {
      final rows = DefinitionRows.merge(
        [
          {
            'name': 'needle',
            'sourceKind': 'configuration',
            'provenance': source,
          },
        ],
        [local('/proxies/0')],
      );
      expect(rows, hasLength(2));
      expect(rows.first.containsKey('localDefinition'), isFalse);
      expect(rows.last['localDefinition'], 'snapshot-1/proxies/0');
    });
  }

  diagnosticTest('重复rules按原始path关联并保留native index和未加载原文顺序', (
    tester,
    fixture,
  ) async {
    await fixture.warmUp(tester);
    final records = [
      for (var index = 0; index < 70; index++)
        <String, dynamic>{
          'index': index,
          'type': 'Match',
          'payload': '',
          'target': 'DIRECT',
          if (index == 51) 'provenance': provenance('/rules/1'),
          if (index == 52) 'provenance': provenance('/rules/0'),
        },
    ];
    final definitions = [
      for (var index = 0; index < 4; index++)
        <String, dynamic>{
          ...local('/rules/$index'),
          'definition': 'MATCH,DIRECT',
        },
    ];
    final first = await read(
      fixture,
      'rules',
      records,
      definitions: definitions,
    );
    expect(first['total'], 72);
    expect((first['scopes'] as List).first['count'], 72);
    expect((first['scopes'] as List)[1]['count'], 70);
    expect((first['scopes'] as List)[2]['count'], 70);
    final next = await read(
      fixture,
      'rules',
      records,
      definitions: definitions,
      offset: 50,
      token: first['token'] as String,
    );
    final rows = next['rows'] as List;
    expect(rows[1]['index'], 51);
    expect(rows[1]['localDefinition'], 'snapshot-1/rules/1');
    expect(rows[2]['index'], 52);
    expect(rows[2]['localDefinition'], 'snapshot-1/rules/0');
    expect(rows[20]['localDefinition'], 'snapshot-1/rules/2');
    expect(rows[21]['localDefinition'], 'snapshot-1/rules/3');
    expect((rows[20] as Map).containsKey('index'), isFalse);
    expect((rows[21] as Map).containsKey('index'), isFalse);
  });

  for (final kind in ['sub', 'provider']) {
    diagnosticTest('$kind scope不合入顶层本地rules', (tester, fixture) async {
      await fixture.warmUp(tester);
      final result = await read(
        fixture,
        'rules',
        [
          {
            'index': 0,
            'type': 'Match',
            'payload': '',
            'target': 'DIRECT',
            'provenance': provenance('/rules/0'),
          },
        ],
        definitions: [local('/rules/0')],
        kind: kind,
        name: 'feed',
      );
      expect(result['total'], 1);
      expect(
        ((result['rows'] as List).single as Map).containsKey('localDefinition'),
        isFalse,
      );
    });
  }

  diagnosticTest('provider节点页不合入直接本地proxy', (tester, fixture) async {
    await fixture.warmUp(tester);
    final result = await read(
      fixture,
      'nodes',
      [
        {
          'name': 'needle',
          'sourceKind': 'proxyProvider',
          'type': 'Direct',
          'providerProvenance': provenance('/proxy-providers/feed'),
        },
      ],
      definitions: [local('/proxies/0')],
      name: 'feed',
    );
    expect(result['total'], 1);
    expect(
      ((result['nodes'] as List).single as Map).containsKey('localDefinition'),
      isFalse,
    );
  });

  test('provider kind独立且下载成员不能继承定义编辑权', () {
    final proxy = local(
      '/proxy-providers/feed',
      kind: 'proxyProvider',
      name: 'feed',
    );
    final rule = local(
      '/rule-providers/feed',
      kind: 'ruleProvider',
      name: 'feed',
    );
    final rows = DefinitionRows.merge(
      [
        {
          'name': 'feed',
          'kind': 'ruleProvider',
          'provenance': provenance('/proxy-providers/feed'),
        },
        {
          'name': 'feed',
          'kind': 'proxyProvider',
          'provenance': provenance('/proxy-providers/feed'),
        },
        {
          'name': 'feed',
          'kind': 'ruleProvider',
          'provenance': provenance('/rule-providers/feed'),
        },
        {
          'name': 'needle',
          'sourceKind': 'proxyProvider',
          'provenance': provenance('/proxies/0'),
        },
      ],
      [proxy, rule, local('/proxies/0')],
    );
    expect(rows, hasLength(5));
    expect(rows[0].containsKey('localDefinition'), isFalse);
    expect(rows[1]['localDefinition'], proxy['localDefinition']);
    expect(rows[2]['localDefinition'], rule['localDefinition']);
    expect(rows[3].containsKey('localDefinition'), isFalse);
  });
}
