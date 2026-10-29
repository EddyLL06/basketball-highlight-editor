typedef PlayerGroup = ({String name, List<String> players});

/// Project-session draft; only the ordered group list determines import order.
class RosterSelection {
  String? groupName;
  bool userSelected = false;
  bool automatic = false;
  bool groupChanged = false;
  final selected = <String>{};
  List<String> _members = [];

  void choose(String? name, List<String> players, {bool automatic = false}) {
    groupName = name;
    this.automatic = automatic;
    userSelected = !automatic;
    groupChanged = false;
    _members = List.of(players);
    selected
      ..clear()
      ..addAll(players);
  }

  void reconcile(List<PlayerGroup> groups, {required bool hasPlayers}) {
    if (automatic && hasPlayers) {
      groupName = null;
      automatic = false;
      selected.clear();
      _members = [];
    }
    final name = groupName;
    if (name == null) return;
    final matching = groups.where((group) => group.name == name);
    if (matching.isEmpty) {
      groupName = null;
      selected.clear();
      _members = [];
      automatic = false;
      userSelected = true;
      groupChanged = true;
      return;
    }
    final latest = matching.first.players;
    selected.removeWhere((player) => !latest.contains(player));
    _members = List.of(latest);
  }

  List<String> get orderedPlayers {
    final seen = <String>{};
    return [
      for (final name in _members)
        if (selected.contains(name) && seen.add(name)) name,
    ];
  }
}
