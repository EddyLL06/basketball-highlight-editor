import 'package:bhe_core/bhe_core.dart';

enum ReviewChange { selection, player, note, range }

class ReviewEntry {
  ReviewEntry(this.kind, this.before, this.focusId);
  final ReviewChange kind;
  final Map<String, Candidate> before;
  final String focusId;
  int sequence = -1;
}

class ReviewHistory {
  final List<ReviewEntry> _entries = [];
  final List<ReviewEntry> _pending = [];
  int _sequence = 0;
  Iterable<ReviewEntry> get allEntries => [..._entries, ..._pending];
  bool get canUndo => _entries.isNotEmpty;
  void clear() {
    _entries.clear();
    _pending.clear();
  }

  void add(ReviewEntry entry) {
    if (entry.before.isEmpty) return;
    if (entry.sequence < 0) entry.sequence = _sequence++;
    _entries.add(entry);
    _entries.sort((a, b) => a.sequence.compareTo(b.sequence));
    if (_entries.length > 20) _entries.removeAt(0);
  }

  void remapPlayer(String oldName, String? newName) {
    for (final entry in allEntries) {
      for (final item in entry.before.entries.toList()) {
        if (item.value.player == oldName) {
          entry.before[item.key] = item.value.copyWith(
            player: newName,
            clearPlayer: newName == null,
          );
        }
      }
    }
  }

  ReviewEntry? pop() {
    if (_entries.isEmpty) return null;
    final entry = _entries.removeLast();
    _pending.add(entry);
    return entry;
  }

  bool complete(ReviewEntry entry) => _pending.remove(entry);
  bool restore(ReviewEntry entry) {
    if (!_pending.remove(entry)) return false;
    add(entry);
    return true;
  }


}

Candidate restoreReviewFields(
  Candidate current,
  Candidate before,
  ReviewChange kind,
) => switch (kind) {
  ReviewChange.selection => current.copyWith(
    selection: before.selection,
    reviewed: before.reviewed,
  ),
  ReviewChange.player => current.copyWith(
    player: before.player,
    clearPlayer: before.player == null,
  ),
  ReviewChange.note => current.copyWith(
    note: before.note,
    clearNote: before.note == null,
  ),
  ReviewChange.range => current.copyWith(
    startMs: before.startMs,
    endMs: before.endMs,
    rangeEdited: before.rangeEdited,
  ),
};
