import 'dart:convert';

import 'package:yaml/yaml.dart';

import '../../model/config_text.dart';

/// Both the downloaded source and the final UTF-8 body include any BOM.
const maxLoonTextBytes = maxConfigBytes;

/// Return conversion results and stable error metadata.
class LoonConversionResult {
  const LoonConversionResult({
    required this.body,
    required this.isLoon,
    required this.ruleCount,
    required this.commentCount,
  });

  final String body;
  final bool isLoon;
  final int ruleCount;

  /// Count nonblank source lines preserved as comments, including headers and original
  /// rejection rules. YAML pass-through reports zero conversion counts.
  final int commentCount;
}

enum LoonConversionError {
  invalidYaml,
  invalidProxyName,
  inputTooLarge,
  outputTooLarge,
}

/// The caller maps [reason] to its existing localized configuration errors.
/// Deliberately excludes parser exceptions, URLs and downloaded source text.
class LoonConversionException implements Exception {
  const LoonConversionException(this.reason);

  final LoonConversionError reason;

  @override
  String toString() => 'LoonConversionException(${reason.name})';
}

/// Recognize a valid YAML mapping byte-for-byte or explicit first Loon section.
/// Preserve unsupported Loon lines as YAML comments. proxyName is a free rule-target
/// name; reject commas and controls that the rule grammar cannot represent. Ordinary
/// YAML ignores conversion options.
LoonConversionResult convertLoonOverride(
  String source, {
  String proxyName = '',
  bool addNoResolve = false,
}) {
  if (utf8.encode(source).length > maxLoonTextBytes) {
    throw const LoonConversionException(LoonConversionError.inputTooLarge);
  }
  final hasBom = source.startsWith('\uFEFF');
  final content = hasBom ? source.substring(1) : source;
  final first = _lines(content).map(_trim).where((line) {
    return line.isNotEmpty && !_isComment(line);
  }).firstOrNull;
  // Require an explicit Loon section independently of YAML parse success.
  final isLoon = first != null && _section(first) != null;
  try {
    final documents = loadYamlDocuments(source);
    if (documents.length == 1 && documents.single.contents is YamlMap) {
      return LoonConversionResult(
        body: source,
        isLoon: false,
        ruleCount: 0,
        commentCount: 0,
      );
    }
  } on YamlException {
    if (!isLoon) {
      throw const LoonConversionException(LoonConversionError.invalidYaml);
    }
  }
  if (!isLoon) {
    throw const LoonConversionException(LoonConversionError.invalidYaml);
  }

  checkLoonProxyName(proxyName);
  final replacement = _trim(proxyName);
  final output = _Output();
  if (hasBom) output.write('\uFEFF');
  output.write(
    '# Loon: compatible [Rule] entries only; other content is inert.\n',
  );
  var inRules = false;
  var continuation = false;
  var openParentheses = 0;
  var ruleCount = 0;
  var commentCount = 0;
  for (final original in _lines(content)) {
    final line = _trim(original);
    final section = _section(line);
    if (section != null || line.startsWith('[')) {
      // Even a malformed/unknown section boundary ends the active Rule area.
      inRules = section == 'Rule';
      continuation = false;
      openParentheses = 0;
    }
    final candidate =
        inRules && section == null && line.isNotEmpty && !_isComment(line);
    final wasContinuation = continuation || openParentheses > 0;
    continuation = candidate && line.endsWith('\\');
    if (candidate) {
      for (final char in line.codeUnits) {
        if (char == 0x28) openParentheses++;
        if (char == 0x29 && openParentheses > 0) openParentheses--;
      }
    }
    // Unproven multiline expressions are wholly inert, even when an interior
    // physical line happens to look like a complete standalone rule.
    final rule =
        candidate && !wasContinuation && !continuation && openParentheses == 0
        ? _convertRule(line, replacement, addNoResolve)
        : null;
    if (rule == null || rule.originalAction != null) {
      output.comment(original);
      if (line.isNotEmpty) commentCount++;
    }
    if (rule == null) continue;
    if (rule.originalAction != null) {
      output.write(
        '# Loon action ${rule.originalAction} -> REJECT: native rejection, '
        'not a Loon response.\n',
      );
    }
    if (ruleCount == 0) output.write('rules:\n');
    output.write('  - ${jsonEncode(rule.text)}\n');
    ruleCount++;
  }
  // An explicit empty list would erase lower-priority rules in replace mode.
  if (ruleCount == 0) output.write('{}\n');
  return LoonConversionResult(
    body: output.toString(),
    isLoon: true,
    ruleCount: ruleCount,
    commentCount: commentCount,
  );
}

/// Validate the name's rule-string representation so the source form can retain invalid
/// input for correction.
void checkLoonProxyName(String name) {
  if (_unsafeText(name) || !_targetCharacters(name)) {
    throw const LoonConversionException(LoonConversionError.invalidProxyName);
  }
}

const _builtins = {
  'DIRECT',
  'REJECT',
  'REJECT-DROP',
  'COMPATIBLE',
  'PASS',
  'PASS-RULE',
  'GLOBAL',
};
const _responseRejects = {
  'REJECT',
  'REJECT-IMG',
  'REJECT-DICT',
  'REJECT-ARRAY',
};
const _ipConditions = {'IP-CIDR', 'IP-CIDR6', 'GEOIP', 'IP-ASN'};
const _logicConditions = {'AND', 'OR', 'NOT'};
final _sectionPattern = RegExp(
  r'''^\[([^\[\],{}:="'\\]+)\](?:[ \t]*(?:#|;|//).*)?$''',
);
final _sectionStart = RegExp(r'^[A-Za-z\u00A0-\uFFFF]');
final _lineEndings = RegExp(r'\r\n|[\r\n\u0085\u2028\u2029]');
final _wildcard = RegExp(r'^[A-Za-z0-9._*?\-]+$');
final _geo = RegExp(r'^[A-Za-z][A-Za-z0-9_-]*$');
final _decimal = RegExp(r'^[0-9]+$');

String _trim(String value) => value.replaceAll(RegExp(r'^[ \t]+|[ \t]+$'), '');

String? _section(String line) {
  final match = _sectionPattern.firstMatch(line);
  if (match == null) return null;
  final name = _trim(match.group(1)!);
  return _sectionStart.hasMatch(name) && !_unsafeText(name) ? name : null;
}

bool _isComment(String line) =>
    line.startsWith('#') || line.startsWith(';') || line.startsWith('//');

Iterable<String> _lines(String text) sync* {
  var start = 0;
  for (final ending in _lineEndings.allMatches(text)) {
    yield text.substring(start, ending.start);
    start = ending.end;
  }
  if (start < text.length) yield text.substring(start);
}

class _ConvertedRule {
  const _ConvertedRule(this.text, this.originalAction);

  final String text;
  final String? originalAction;
}

_ConvertedRule? _convertRule(String line, String replacement, bool noResolve) {
  final fields = _fields(line);
  if (fields == null || fields.length < 2) return null;
  final type = fields.first;
  final isIp = _ipConditions.contains(type);
  final params = fields.skip(2).toList();
  var hasNoResolve = false;
  if (isIp && params.isNotEmpty && params.last == 'no-resolve') {
    hasNoResolve = true;
    params.removeLast();
  }
  if (params.length > 1) return null;
  final explicit = params.firstOrNull;
  // Classify leaf parameters separately from proxy targets.
  if (explicit == 'no-resolve') return null;
  if (explicit != null && !_sourceTarget(explicit)) return null;
  var target = explicit;
  String? originalAction;
  if (_responseRejects.contains(target)) {
    originalAction = target;
    target = 'REJECT';
  } else if (!_builtins.contains(target) && replacement.isNotEmpty) {
    target = replacement;
  }
  if (target == null || target.isEmpty) return null;
  final conditionFields = [type, fields[1], if (hasNoResolve) 'no-resolve'];
  final condition = _condition(conditionFields, noResolve, 0);
  if (condition == null) return null;
  // Place the action before leaf parameters such as no-resolve.
  final payload = isIp
      ? condition.replaceFirst(RegExp(r',no-resolve$'), '')
      : condition;
  return _ConvertedRule(
    '$payload,$target'
    '${isIp && (hasNoResolve || noResolve) ? ',no-resolve' : ''}',
    originalAction,
  );
}

/// Use the list-of-parenthesized-conditions form: NOT,((DOMAIN,example.test)),target.
String? _condition(List<String> fields, bool noResolve, int depth) {
  if (depth > 64 || fields.length < 2) return null;
  final type = fields.first;
  final value = fields[1];
  if (_logicConditions.contains(type)) {
    if (fields.length != 2 || !value.startsWith('(') || !value.endsWith(')')) {
      return null;
    }
    final children = _fields(value.substring(1, value.length - 1));
    if (children == null ||
        children.isEmpty ||
        (type == 'NOT' && children.length != 1)) {
      return null;
    }
    final converted = <String>[];
    for (final child in children) {
      if (!child.startsWith('(') || !child.endsWith(')')) return null;
      final childFields = _fields(child.substring(1, child.length - 1));
      if (childFields == null) return null;
      final condition = _condition(childFields, noResolve, depth + 1);
      if (condition == null) return null;
      converted.add('($condition)');
    }
    return '$type,(${converted.join(',')})';
  }
  final isIp = _ipConditions.contains(type);
  if (fields.length > 3 ||
      (fields.length == 3 && (!isIp || fields[2] != 'no-resolve'))) {
    return null;
  }
  var payload = value;
  switch (type) {
    case 'DOMAIN':
    case 'DOMAIN-SUFFIX':
    case 'DOMAIN-KEYWORD':
      if (!_domainAtom(value)) return null;
    case 'DOMAIN-WILDCARD':
      if (!_wildcard.hasMatch(value)) return null;
    case 'IP-CIDR':
    case 'IP-CIDR6':
      if (!_cidr(value, ipv6: type == 'IP-CIDR6')) return null;
    case 'GEOIP':
      if (!_geo.hasMatch(value)) return null;
    case 'IP-ASN':
      // Require the canonical decimal ASN representation used by the database's
      // literal comparison.
      if (!_decimal.hasMatch(value) ||
          (value.length > 1 && value.startsWith('0')) ||
          value.length > 10 ||
          (int.tryParse(value) ?? 0x100000000) > 0xFFFFFFFF) {
        return null;
      }
    case 'SRC-PORT':
    case 'DEST-PORT':
      final port = _port(value);
      if (port == null) return null;
      payload = port;
    default:
      return null;
  }
  return '${type == 'DEST-PORT' ? 'DST-PORT' : type},$payload'
      '${isIp && (noResolve || fields.length == 3) ? ',no-resolve' : ''}';
}

/// Split only commas outside parentheses, following the common rule grammar.
List<String>? _fields(String text) {
  if (text.isEmpty) return null;
  final result = <String>[];
  var depth = 0;
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    final char = text.codeUnitAt(i);
    if (char == 0x28) {
      if (++depth > 128) return null;
    } else if (char == 0x29) {
      if (--depth < 0) return null;
    } else if (char == 0x2C && depth == 0) {
      result.add(_trim(text.substring(start, i)));
      start = i + 1;
    }
  }
  if (depth != 0) return null;
  result.add(_trim(text.substring(start)));
  return result.any((field) => field.isEmpty) ? null : result;
}

bool _targetCharacters(String text) => !text.contains(',');

bool _sourceTarget(String text) =>
    !_unsafeText(text) &&
    _targetCharacters(text) &&
    !text.contains(RegExp(r'[#;{}]')) &&
    !text.startsWith('"') &&
    !text.endsWith('"') &&
    !text.startsWith("'") &&
    !text.endsWith("'");

bool _domainAtom(String text) =>
    text.isNotEmpty &&
    !_unsafeText(text) &&
    !text.contains(RegExp(r'''[\s,()\[\]{}*?\\"'#;/:]'''));

bool _cidr(String text, {required bool ipv6}) {
  final pieces = text.split('/');
  if (pieces.length != 2 || !_decimal.hasMatch(pieces[1])) return false;
  final prefix = int.tryParse(pieces[1]);
  if (prefix == null || prefix > (ipv6 ? 128 : 32)) return false;
  final address = pieces[0];
  if (ipv6) {
    if (!address.contains(':') || address.contains(RegExp(r'[^0-9A-Fa-f:.]'))) {
      return false;
    }
    try {
      Uri.parseIPv6Address(address);
      return true;
    } on FormatException {
      return false;
    }
  }
  final octets = address.split('.');
  return octets.length == 4 &&
      octets.every((octet) {
        return _decimal.hasMatch(octet) &&
            octet.length <= 3 &&
            (octet.length == 1 || !octet.startsWith('0')) &&
            int.parse(octet) <= 255;
      });
}

String? _port(String value) {
  if (value.startsWith('>=')) {
    final lower = _portNumber(value.substring(2));
    return lower == null ? null : '$lower-65535';
  }
  final bounds = value.split('-');
  if (bounds.length > 2) return null;
  final lower = _portNumber(bounds.first);
  final upper = _portNumber(bounds.last);
  if (lower == null || upper == null || lower > upper) return null;
  return value;
}

int? _portNumber(String value) {
  if (!_decimal.hasMatch(value) || value.length > 5) return null;
  final number = int.parse(value);
  return number <= 65535 ? number : null;
}

bool _unsafeRune(int rune) =>
    rune < 0x20 ||
    (rune >= 0x7F && rune <= 0x9F) ||
    (rune >= 0xD800 && rune <= 0xDFFF) ||
    (rune >= 0x2028 && rune <= 0x202E) ||
    (rune >= 0x2066 && rune <= 0x2069) ||
    rune == 0xFEFF ||
    rune == 0xFFFE ||
    rune == 0xFFFF;

bool _unsafeText(String text) => text.runes.any(_unsafeRune);

class _Output {
  final _buffer = StringBuffer();
  var _bytes = 0;

  void write(String text) {
    _bytes += utf8.encode(text).length;
    if (_bytes > maxLoonTextBytes) {
      throw const LoonConversionException(LoonConversionError.outputTooLarge);
    }
    _buffer.write(text);
  }

  void comment(String text) {
    write('# ');
    // Flush and check bounded escaped chunks against the output budget.
    var chunk = StringBuffer();
    for (final rune in text.runes) {
      if (_unsafeRune(rune)) {
        chunk.write(
          '\\u${rune.toRadixString(16).padLeft(4, '0').toUpperCase()}',
        );
      } else {
        chunk.writeCharCode(rune);
      }
      if (chunk.length >= 4096) {
        write(chunk.toString());
        chunk = StringBuffer();
      }
    }
    write('${chunk.toString()}\n');
  }

  @override
  String toString() => _buffer.toString();
}
