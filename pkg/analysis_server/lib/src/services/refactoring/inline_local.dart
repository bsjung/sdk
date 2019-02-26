// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:analysis_server/src/protocol_server.dart' hide Element;
import 'package:analysis_server/src/services/correction/status.dart';
import 'package:analysis_server/src/services/correction/util.dart';
import 'package:analysis_server/src/services/refactoring/refactoring.dart';
import 'package:analysis_server/src/services/refactoring/refactoring_internal.dart';
import 'package:analysis_server/src/services/search/search_engine.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/precedence.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/src/dart/analysis/session_helper.dart';
import 'package:analyzer/src/dart/ast/utilities.dart';
import 'package:analyzer/src/generated/java_core.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer_plugin/utilities/range_factory.dart';

/**
 * [InlineLocalRefactoring] implementation.
 */
class InlineLocalRefactoringImpl extends RefactoringImpl
    implements InlineLocalRefactoring {
  final SearchEngine searchEngine;
  final ResolvedUnitResult resolveResult;
  final int offset;
  CorrectionUtils utils;

  Element _variableElement;
  VariableDeclaration _variableNode;
  List<SearchMatch> _references;

  InlineLocalRefactoringImpl(
      this.searchEngine, this.resolveResult, this.offset) {
    utils = new CorrectionUtils(resolveResult);
  }

  @override
  String get refactoringName => 'Inline Local Variable';

  @override
  int get referenceCount {
    if (_references == null) {
      return 0;
    }
    return _references.length;
  }

  @override
  String get variableName {
    if (_variableElement == null) {
      return null;
    }
    return _variableElement.name;
  }

  @override
  Future<RefactoringStatus> checkFinalConditions() {
    RefactoringStatus result = new RefactoringStatus();
    return new Future.value(result);
  }

  @override
  Future<RefactoringStatus> checkInitialConditions() async {
    // TODO(brianwilkerson) Determine whether this await is necessary.
    await null;
    RefactoringStatus result = new RefactoringStatus();
    // prepare variable
    {
      AstNode offsetNode =
          new NodeLocator(offset).searchWithin(resolveResult.unit);
      if (offsetNode is SimpleIdentifier) {
        Element element = offsetNode.staticElement;
        if (element is LocalVariableElement) {
          _variableElement = element;
          var declarationResult =
              await AnalysisSessionHelper(resolveResult.session)
                  .getElementDeclaration(element);
          _variableNode = declarationResult.node;
        }
      }
    }
    // validate node declaration
    if (!_isVariableDeclaredInStatement()) {
      result = new RefactoringStatus.fatal(
          'Local variable declaration or reference must be selected '
          'to activate this refactoring.');
      return new Future<RefactoringStatus>.value(result);
    }
    // should have initializer at declaration
    if (_variableNode.initializer == null) {
      String message = format(
          "Local variable '{0}' is not initialized at declaration.",
          _variableElement.displayName);
      result = new RefactoringStatus.fatal(
          message, newLocation_fromNode(_variableNode));
      return new Future<RefactoringStatus>.value(result);
    }
    // prepare references
    _references = await searchEngine.searchReferences(_variableElement);
    // should not have assignments
    for (SearchMatch reference in _references) {
      if (reference.kind != MatchKind.READ) {
        String message = format(
            "Local variable '{0}' is assigned more than once.",
            [_variableElement.displayName]);
        return new RefactoringStatus.fatal(
            message, newLocation_fromMatch(reference));
      }
    }
    // done
    return result;
  }

  @override
  Future<SourceChange> createChange() {
    SourceChange change = new SourceChange(refactoringName);
    // remove declaration
    {
      Statement declarationStatement =
          _variableNode.thisOrAncestorOfType<VariableDeclarationStatement>();
      SourceRange range = utils.getLinesRangeStatements([declarationStatement]);
      doSourceChange_addElementEdit(change, resolveResult.unit.declaredElement,
          newSourceEdit_range(range, ''));
    }
    // prepare initializer
    Expression initializer = _variableNode.initializer;
    String initializerCode = utils.getNodeText(initializer);
    // replace references
    for (SearchMatch reference in _references) {
      SourceRange editRange = reference.sourceRange;
      // prepare context
      int offset = editRange.offset;
      AstNode node = utils.findNode(offset);
      AstNode parent = node.parent;
      // prepare code
      String codeForReference;
      if (parent is InterpolationExpression) {
        StringInterpolation target = parent.parent;
        if (initializer is SingleStringLiteral &&
            !initializer.isRaw &&
            initializer.isSingleQuoted == target.isSingleQuoted &&
            (!initializer.isMultiline || target.isMultiline)) {
          editRange = range.node(parent);
          // unwrap the literal being inlined
          int initOffset = initializer.contentsOffset;
          int initLength = initializer.contentsEnd - initOffset;
          codeForReference = utils.getText(initOffset, initLength);
        } else if (_shouldBeExpressionInterpolation(parent, initializer)) {
          codeForReference = '{$initializerCode}';
        } else {
          codeForReference = initializerCode;
        }
      } else if (_shouldUseParenthesis(initializer, node)) {
        codeForReference = '($initializerCode)';
      } else {
        codeForReference = initializerCode;
      }
      // do replace
      doSourceChange_addElementEdit(change, resolveResult.unit.declaredElement,
          newSourceEdit_range(editRange, codeForReference));
    }
    // done
    return new Future.value(change);
  }

  bool _isVariableDeclaredInStatement() {
    if (_variableNode == null) {
      return false;
    }
    AstNode parent = _variableNode.parent;
    if (parent is VariableDeclarationList) {
      parent = parent.parent;
      if (parent is VariableDeclarationStatement) {
        parent = parent.parent;
        return parent is Block || parent is SwitchCase;
      }
    }
    return false;
  }

  static bool _shouldBeExpressionInterpolation(
      InterpolationExpression target, Expression expression) {
    TokenType targetType = target.beginToken.type;
    return targetType == TokenType.STRING_INTERPOLATION_IDENTIFIER &&
        expression is! SimpleIdentifier;
  }

  static bool _shouldUseParenthesis(Expression init, AstNode node) {
    // check precedence
    Precedence initPrecedence = getExpressionPrecedence(init);
    if (initPrecedence < getExpressionParentPrecedence(node)) {
      return true;
    }
    // special case for '-'
    AstNode parent = node.parent;
    if (init is PrefixExpression && parent is PrefixExpression) {
      if (parent.operator.type == TokenType.MINUS) {
        TokenType initializerOperator = init.operator.type;
        if (initializerOperator == TokenType.MINUS ||
            initializerOperator == TokenType.MINUS_MINUS) {
          return true;
        }
      }
    }
    // no () is needed
    return false;
  }
}
