import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:isar_bench/benchmark.dart';
import 'package:path/path.dart' as p;

void main(List<String> args) async {
  final parser = ArgParser();
  parser.addOption('count', abbr: 'n', defaultsTo: '10');
  parser.addOption('skip', abbr: 's', defaultsTo: '3');
  parser.addMultiOption('ref', abbr: 'r', defaultsTo: []);
  parser.addMultiOption('benchmark', abbr: 'b', defaultsTo: []);
  final argResult = parser.parse(args);

  final count = int.parse(argResult['count']);
  final skip = int.parse(argResult['skip']);
  final refs = <String>['current', ...argResult['ref']];

  final selectedBenchmarks = argResult['benchmark'] as List<String>;
  final allBenchmarks = _findAllBenchmarks();

  final benchmarks = selectedBenchmarks.isNotEmpty
      ? selectedBenchmarks.where((e) => allBenchmarks.contains(e)).toList()
      : allBenchmarks;

  final result = <String, Map<String, BenchmarkResult>>{};

  for (var ref in refs) {
    await Future.delayed(Duration(milliseconds: 100));
    try {
      String? workingDir;
      if (ref != 'current') {
        _run('git', ['clone', 'https://github.com/isar/isar.git']);
        _run('git', ['checkout', ref],
            workingDirectory: Directory('isar').absolute.path);
        workingDir = p.join('isar', 'packages', 'isar_bench');
      }
      final results = _runBenchmarks(benchmarks, count + skip, workingDir);
      final skippedResults = results.map((e) => e.skip(skip)).toList();
      result[ref] = {
        for (var r in skippedResults) r.name: r,
      };
    } finally {
      if (ref != 'current') {
        Directory('isar').deleteSync(recursive: true);
      }
    }
  }

  print(formatBenchmarks(result));
}

List<String> _findAllBenchmarks() {
  final benchmarks = <String>[];
  final dir = Directory(p.join('lib', 'benchmarks'));
  for (var file in dir.listSync()) {
    if (file is File &&
        file.path.endsWith('.dart') &&
        !file.path.endsWith('g.dart')) {
      final name = p.basenameWithoutExtension(file.path);
      benchmarks.add(name);
    }
  }
  return benchmarks;
}

String _run(String executable, List<String> arguments,
    {String? workingDirectory}) {
  final process = Process.runSync(executable, arguments,
      workingDirectory: workingDirectory);
  if (process.exitCode == 0) {
    return process.stdout;
  } else {
    throw process.stderr;
  }
}

List<BenchmarkResult> _runBenchmarks(
    List<String> benchmarks, int count, String? workingDirectory) {
  _run(Platform.executable, ['pub', 'get'], workingDirectory: workingDirectory);
  _run(
    Platform.executable,
    ['pub', 'run', 'build_runner', 'build', '--delete-conflicting-outputs'],
    workingDirectory: workingDirectory,
  );
  final results = <BenchmarkResult>[];
  for (var benchmark in benchmarks) {
    _run(
      Platform.executable,
      [
        'compile',
        'aot-snapshot',
        p.join('lib', 'benchmarks', '$benchmark.dart')
      ],
      workingDirectory: workingDirectory,
    );
    final result = _run(
      '/Users/simon/flutter/bin/cache/dart-sdk/bin/dartaotruntime',
      [p.join('lib', 'benchmarks', '$benchmark.aot'), '-n', count.toString()],
      workingDirectory: workingDirectory,
    );
    results.add(BenchmarkResult.fromJson(jsonDecode(result)));
  }
  return results;
}

String formatBenchmarks(Map<String, Map<String, BenchmarkResult>> results) {
  final current = results['current']!;
  final refs = results.keys.where((e) => e != 'current').toList()..sort();
  final benchmarks = current.keys.toList()..sort();

  var html =
      '<table><thead><tr><th>Benchmark</th><th>Metric</th><th>Current</th>';
  for (var ref in refs) {
    html += '<th>$ref</th>';
  }
  html += '</thead><tbody>';

  for (var benchmark in benchmarks) {
    final currentAverage = current[benchmark]!.averageTime;
    html += '<tr><td rowspan="2">$benchmark</td><td>Average</td>'
        '<td>${_formatTime(currentAverage)}</td>';
    for (var ref in refs) {
      final resultAverage = results[ref]![benchmark]!.averageTime;
      html += '<td>${_formatTime(resultAverage, currentAverage)}</td>';
    }
    html += '</tr>';

    final currentMax = current[benchmark]!.maxTime;
    html += '<tr><td>Max</td><td>${_formatTime(currentMax)}</td>';
    for (var ref in refs) {
      final resultMax = results[ref]![benchmark]!.averageTime;
      html += '<td>${_formatTime(resultMax, currentMax)}</td>';
    }
    html += '</tr>';
  }

  html += '</tbody></table>';

  return html;
}

String _formatTime(int time, [int? current]) {
  final timeStr = (time.toDouble() / 1000).toStringAsFixed(2);
  if (current != null) {
    final diff = 100 - ((current.toDouble() / time) * 100).round();
    return '${timeStr}ms (${diff > 0 ? '+' : ''}$diff%)';
  } else {
    return '${timeStr}ms';
  }
}