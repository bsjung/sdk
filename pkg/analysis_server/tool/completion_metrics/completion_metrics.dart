// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io' as io;

import 'package:analysis_server/src/domains/completion/available_suggestions.dart';
import 'package:analysis_server/src/protocol_server.dart';
import 'package:analysis_server/src/services/completion/completion_core.dart';
import 'package:analysis_server/src/services/completion/completion_performance.dart';
import 'package:analysis_server/src/services/completion/dart/completion_manager.dart';
import 'package:analysis_server/src/services/completion/dart/utilities.dart';
import 'package:analysis_server/src/status/pages.dart';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/file_system/physical_file_system.dart';
import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/services/available_declarations.dart';

import 'metrics_util.dart';
import 'visitors.dart';

main() async {
  var analysisRoots = [''];
  await _computeCompletionMetrics(
      PhysicalResourceProvider.INSTANCE, analysisRoots);
}

/// When enabled, expected, but missing completion tokens will be printed to
/// stdout.
const bool _doPrintMissingCompletions = true;

/// TODO(jwren) put the following methods into a class
Future _computeCompletionMetrics(
    ResourceProvider resourceProvider, List<String> analysisRoots) async {
  int includedCount = 0;
  int notIncludedCount = 0;
  Counter completionKindCounter = Counter('completion kind counter');
  Counter completionElementKindCounter =
      Counter('completion element kind counter');

  for (var root in analysisRoots) {
    print('Analyzing root: \"$root\"');

    if (!io.Directory(root).existsSync()) {
      print('\tError: No such directory exists on this machine.\n');
      continue;
    }

    final collection = AnalysisContextCollection(
      includedPaths: [root],
      resourceProvider: resourceProvider,
    );

    for (var context in collection.contexts) {
      var declarationsTracker =
          DeclarationsTracker(MemoryByteStore(), resourceProvider);
      declarationsTracker.addContext(context);

      while (declarationsTracker.hasWork) {
        declarationsTracker.doWork();
      }

      for (var filePath in context.contextRoot.analyzedFiles()) {
        if (AnalysisEngine.isDartFileName(filePath)) {
          try {
            final resolvedUnitResult =
                await context.currentSession.getResolvedUnit(filePath);
            final visitor = ExpectedCompletionsVisitor();

            resolvedUnitResult.unit.accept(visitor);

            for (var expectedCompletion in visitor.expectedCompletions) {
              var suggestions = await computeCompletionSuggestions(
                  resolvedUnitResult,
                  expectedCompletion.offset,
                  declarationsTracker);

              var fraction =
                  _placementInSuggestionList(suggestions, expectedCompletion);

              if (fraction.denominator != 0) {
                includedCount++;
              } else {
                notIncludedCount++;
                if (_doPrintMissingCompletions) {
                  // The format "/file/path/foo.dart:3:4" makes for easier input
                  // with the Files dialog in IntelliJ
                  print(
                      '$filePath:${expectedCompletion.lineNumber}:${expectedCompletion.columnNumber}');
                  print(
                      '\tdid not include the expected completion: \"${expectedCompletion.completion}\", completion kind: ${expectedCompletion.kind.toString()}, element kind: ${expectedCompletion.elementKind.toString()}');
                  print('');

                  completionKindCounter
                      .count(expectedCompletion.kind.toString());
                  completionElementKindCounter
                      .count(expectedCompletion.elementKind.toString());
                }
              }
            }
          } catch (e) {
            print('Exception caught analyzing: $filePath');
            print(e.toString());
          }
        }
      }
    }

    final totalCompletionCount = includedCount + notIncludedCount;
    final percentIncluded = includedCount / totalCompletionCount;
    final percentNotIncluded = 1 - percentIncluded;

    completionKindCounter.printCounterValues();
    completionElementKindCounter.printCounterValues();
    print('Summary for $root:');
    print('Total number of completion tests   = $totalCompletionCount');
    print(
        'Number of successful completions   = $includedCount (${printPercentage(percentIncluded)})');
    print(
        'Number of unsuccessful completions = $notIncludedCount (${printPercentage(percentNotIncluded)})');
  }
  includedCount = 0;
  notIncludedCount = 0;
  completionKindCounter.clear();
  completionElementKindCounter.clear();
}

Place _placementInSuggestionList(List<CompletionSuggestion> suggestions,
    ExpectedCompletion expectedCompletion) {
  var placeCounter = 1;
  for (var completionSuggestion in suggestions) {
    if (expectedCompletion.matches(completionSuggestion)) {
      return Place(placeCounter, suggestions.length);
    }
    placeCounter++;
  }
  return Place.none();
}

Future<List<CompletionSuggestion>> computeCompletionSuggestions(
    ResolvedUnitResult resolvedUnitResult, int offset,
    [DeclarationsTracker declarationsTracker]) async {
  var completionRequestImpl = CompletionRequestImpl(
    resolvedUnitResult,
    offset,
    CompletionPerformance(),
  );

  // This gets all of the suggestions with relevances.
  var suggestions =
      await DartCompletionManager().computeSuggestions(completionRequestImpl);

  // If a non-null declarationsTracker was passed, use it to call
  // computeIncludedSetList, this current implementation just adds the set of
  // included element names with relevance 0, future implementations should
  // compute out the relevance that clients will set to each value.
  if (declarationsTracker != null) {
    var includedSuggestionSets = <IncludedSuggestionSet>[];
    var includedElementNames = <String>{};

    computeIncludedSetList(declarationsTracker, resolvedUnitResult,
        includedSuggestionSets, includedElementNames);

    for (var eltName in includedElementNames) {
      suggestions.add(CompletionSuggestion(CompletionSuggestionKind.INVOCATION,
          0, eltName, 0, eltName.length, false, false));
    }
  }

  suggestions.sort(completionComparator);
  return suggestions;
}
