import 'dart:async';

/// Serializes project operations without storing snapshots in the queue.
class ProjectMutationQueue {
  Future<void> _tail = Future<void>.value();
  int _pending = 0;

  Future<void> get drained => _tail;
  int get pending => _pending;

  Future<T> run<T>(Future<T> Function() operation) {
    _pending++;
    final result = _tail
        .then((_) => operation())
        .whenComplete(() => _pending--);
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}
