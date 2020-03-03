// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:path/path.dart' as p;
import 'package:source_maps/source_maps.dart';
import 'package:stack_trace/stack_trace.dart';

/// Convert [stackTrace], a stack trace generated by dart2js-compiled
/// JavaScript, to a native-looking stack trace using [sourceMap].
///
/// [minified] indicates whether or not the dart2js code was minified. If it
/// hasn't, this tries to clean up the stack frame member names.
///
/// The [packageMap] maps package names to the base uri used to resolve the
/// `package:` uris for those packages. It is used to  it's used to reconstruct
/// `package:` URIs for stack frames that come from packages.
///
/// [sdkRoot] is the URI surfaced in the stack traces for SDK libraries.
/// If it's passed, stack frames from the SDK will have `dart:` URLs.
StackTrace mapStackTrace(Mapping sourceMap, StackTrace stackTrace,
    {bool minified = false, Map<String, Uri> packageMap, Uri sdkRoot}) {
  if (stackTrace is Chain) {
    return Chain(stackTrace.traces.map((trace) {
      return Trace.from(mapStackTrace(sourceMap, trace,
          minified: minified, packageMap: packageMap, sdkRoot: sdkRoot));
    }));
  }

  var sdkLib = sdkRoot == null ? null : '$sdkRoot/lib';

  var trace = Trace.from(stackTrace);
  return Trace(trace.frames.map((frame) {
    // If there's no line information, there's no way to translate this frame.
    // We could return it as-is, but these lines are usually not useful anyways.
    if (frame.line == null) return null;

    // If there's no column, try using the first column of the line.
    var column = frame.column ?? 0;

    // Subtract 1 because stack traces use 1-indexed lines and columns and
    // source maps uses 0-indexed.
    var span = sourceMap.spanFor(frame.line - 1, column - 1,
        uri: frame.uri?.toString());

    // If we can't find a source span, ignore the frame. It's probably something
    // internal that the user doesn't care about.
    if (span == null) return null;

    var sourceUrl = span.sourceUrl.toString();
    if (sdkRoot != null && p.url.isWithin(sdkLib, sourceUrl)) {
      sourceUrl = 'dart:' + p.url.relative(sourceUrl, from: sdkLib);
    } else if (packageMap != null) {
      for (var package in packageMap.keys) {
        var packageUrl = packageMap[package].toString();
        if (!p.url.isWithin(packageUrl, sourceUrl)) continue;

        sourceUrl =
            'package:$package/' + p.url.relative(sourceUrl, from: packageUrl);
        break;
      }
    }

    return Frame(
        Uri.parse(sourceUrl),
        span.start.line + 1,
        span.start.column + 1,
        // If the dart2js output is minified, there's no use trying to prettify
        // its member names. Use the span's identifier if available, otherwise
        // use the minified member name.
        minified
            ? (span.isIdentifier ? span.text : frame.member)
            : _prettifyMember(frame.member));
  }).where((frame) => frame != null));
}

/// Reformats a JS member name to make it look more Dart-like.
String _prettifyMember(String member) {
  return member
      // Get rid of the noise that Firefox sometimes adds.
      .replaceAll(RegExp(r'/?<$'), '')
      // Get rid of arity indicators and named arguments.
      .replaceAll(RegExp(r'\$\d+(\$[a-zA-Z_0-9]+)*$'), '')
      // Convert closures to <fn>.
      .replaceAllMapped(
          RegExp(r'(_+)closure\d*\.call$'),
          // The number of underscores before "closure" indicates how nested it
          // is.
          (match) => '.<fn>' * match[1].length)
      // Get rid of explicitly-generated calls.
      .replaceAll(RegExp(r'\.call$'), '')
      // Get rid of the top-level method prefix.
      .replaceAll(RegExp(r'^dart\.'), '')
      // Get rid of library namespaces.
      .replaceAll(RegExp(r'[a-zA-Z_0-9]+\$'), '')
      // Get rid of the static method prefix. The class name also exists in the
      // invocation, so we're not getting rid of any information.
      .replaceAll(RegExp(r'^[a-zA-Z_0-9]+.(static|dart).'), '')
      // Convert underscores after identifiers to dots. This runs the risk of
      // incorrectly converting members that contain underscores, but those are
      // contrary to the style guide anyway.
      .replaceAllMapped(RegExp(r'([a-zA-Z0-9]+)_'), (match) => match[1] + '.');
}
