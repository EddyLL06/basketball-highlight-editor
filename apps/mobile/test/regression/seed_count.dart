import 'dart:io';

/// One seed budget for the whole regression directory; old per-suite overrides
/// remain supported when the shared budget is not set.
int regressionSeedCount(String legacyVariable) {
  final raw =
      Platform.environment['BHE_FUZZ_SEEDS'] ??
      Platform.environment[legacyVariable];
  if (raw == null || raw.isEmpty) return 30;
  final count = int.tryParse(raw);
  if (count == null || count < 1) {
    throw ArgumentError('Seed count must be a positive integer: $raw');
  }
  return count;
}
