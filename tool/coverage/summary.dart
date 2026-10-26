// Summarize measured FN/FNDA, DA and BRDA separately. Dart functions and VM branch
// locations use source-line units and may merge same-line entries.
import 'dart:io';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/coverage/summary.dart <lcov.info>');
    exitCode = 64;
    return;
  }
  var functions = 0, functionHits = 0;
  var lines = 0, lineHits = 0;
  var branches = 0, branchHits = 0;
  var files = 0;
  var currentLines = 0, currentLineHits = 0;
  final worst = <(double, String, int, int)>[];
  final sources = <String>{};
  String? file;

  int hits(String text) {
    final value = int.parse(text);
    if (value < 0) throw const FormatException('Negative coverage hit count');
    return value;
  }

  void finishFile() {
    final name = file;
    if (name != null && currentLines > 0) {
      worst.add((
        currentLineHits / currentLines,
        name,
        currentLineHits,
        currentLines,
      ));
    }
  }

  for (final line in File(args.first).readAsLinesSync()) {
    if (line.startsWith('SF:')) {
      finishFile();
      file = line.substring(3);
      if (file.isEmpty || !sources.add(file)) {
        throw const FormatException('Expected one merged record per source');
      }
      files++;
      currentLines = 0;
      currentLineHits = 0;
    } else if (line.startsWith('FN:')) {
      functions++;
    } else if (line.startsWith('FNDA:')) {
      if (hits(line.substring(5).split(',').first) > 0) functionHits++;
    } else if (line.startsWith('DA:')) {
      final value = hits(line.substring(3).split(',')[1]);
      lines++;
      currentLines++;
      if (value > 0) {
        lineHits++;
        currentLineHits++;
      }
    } else if (line.startsWith('BRDA:')) {
      final taken = line.substring(5).split(',')[3];
      branches++;
      if (taken != '-' && hits(taken) > 0) branchHits++;
    }
  }
  finishFile();
  if (functionHits > functions) {
    throw const FormatException(
      'Function hits exceed declared function records',
    );
  }
  worst.sort((a, b) => a.$1.compareTo(b.$1));

  String pct(int hit, int total) =>
      total == 0 ? 'n/a' : '${(hit * 100 / total).toStringAsFixed(1)}%';
  stdout.writeln('files=$files');
  stdout.writeln(
    functions == 0
        ? 'functions=n/a (no FN records in this lcov)'
        : 'functions=$functionHits/$functions ${pct(functionHits, functions)}',
  );
  stdout.writeln('lines=$lineHits/$lines ${pct(lineHits, lines)}');
  stdout.writeln(
    branches == 0
        ? 'branches=n/a'
        : 'branches=$branchHits/$branches ${pct(branchHits, branches)}',
  );
  stdout.writeln(
    'condition/decision=n/a (requires separate condition evidence)',
  );
  stdout.writeln('lowest line coverage (up to 10 files; totals include all):');
  for (final row in worst.take(10)) {
    stdout.writeln(
      '  ${(row.$1 * 100).toStringAsFixed(1)}% ${row.$3}/${row.$4} ${row.$2}',
    );
  }
}
