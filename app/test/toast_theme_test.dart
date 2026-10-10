import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibemobile/core/theme.dart';

void main() {
  for (final theme in [AppTheme.dark, AppTheme.light]) {
    test('toast is a floating surface card, not the inverse bar (${theme.brightness.name})', () {
      final s = theme.snackBarTheme;
      expect(s.behavior, SnackBarBehavior.floating);
      expect(s.backgroundColor, theme.colorScheme.surfaceContainerHigh);
      expect(s.contentTextStyle?.color, theme.colorScheme.onSurface);
      expect((s.shape! as RoundedRectangleBorder).side.color, theme.colorScheme.outlineVariant);
    });
  }
}
