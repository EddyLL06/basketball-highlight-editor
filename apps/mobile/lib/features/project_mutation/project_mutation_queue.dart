import 'dart:async';

/// Serializes project operations without storing snapshots in the queue.
class ProjectMutationQueue {
  Future<void> _tail = Future<void>.value();

  Future<void> get drained => _tail;

  Future<T> run<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
