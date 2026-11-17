/// Inputs are admitted only after manifest, bytes and relationships verify.
class VerifiedSnapshotPoint {
  const VerifiedSnapshotPoint({
    required this.uri,
    required this.createdAt,
    required this.documentCount,
    required this.sizeBytes,
  });
  final String uri;
  final DateTime createdAt;
  final int documentCount;
  final int sizeBytes;
}

/// UTC calendar buckets avoid timezone-dependent pruning. Future timestamps
/// are protected, including after a clock rollback. No count-only eviction.
class PortableSnapshotRetention {
  const PortableSnapshotRetention({
    this.recent = 6,
    this.dailyDays = 7,
    this.weeklyWeeks = 4,
  });
  final int recent;
  final int dailyDays;
  final int weeklyWeeks;

  Set<String> keep(
    List<VerifiedSnapshotPoint> points,
    DateTime now, {
    Set<String> protectedUris = const {},
  }) {
    final sorted = [...points]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt) != 0
        ? b.createdAt.compareTo(a.createdAt) : a.uri.compareTo(b.uri));
    final keep = <String>{...protectedUris};
    for (final point in sorted.take(recent < 2 ? 2 : recent)) {
      keep.add(point.uri);
    }
    // Protect the most useful historical recovery point against an empty reset.
    final useful = [...sorted]
      ..sort((a, b) => b.documentCount.compareTo(a.documentCount) != 0
        ? b.documentCount.compareTo(a.documentCount)
        : (b.createdAt.compareTo(a.createdAt) != 0
            ? b.createdAt.compareTo(a.createdAt) : a.uri.compareTo(b.uri)));
    for (final point in useful.take(2)) {
      keep.add(point.uri);
    }
    final utc = now.toUtc();
    final today = DateTime.utc(utc.year, utc.month, utc.day);
    final week = today.subtract(
      Duration(days: today.weekday - DateTime.monday),
    );
    final days = <int>{};
    final weeks = <int>{};
    for (final point in sorted) {
      final at = point.createdAt.toUtc();
      if (at.isAfter(utc)) {
        keep.add(point.uri);
        continue;
      }
      final day = DateTime.utc(at.year, at.month, at.day);
      final age = today.difference(day).inDays;
      final pointWeek = day.subtract(
        Duration(days: day.weekday - DateTime.monday),
      );
      final weekAge = week.difference(pointWeek).inDays ~/ 7;
      if (age >= 0 && age < dailyDays && days.add(age)) keep.add(point.uri);
      if (weekAge >= 0 && weekAge < weeklyWeeks && weeks.add(weekAge))
        keep.add(point.uri);
    }
    return keep;
  }
}
