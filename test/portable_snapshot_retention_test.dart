import 'package:flutter_test/flutter_test.dart';
import 'package:docs_grid/features/tools/portable_snapshot_retention.dart';

void main() {
  final now = DateTime.utc(2026, 11, 17, 12);
  VerifiedSnapshotPoint point(int hours, {int documents = 100}) =>
      VerifiedSnapshotPoint(uri: 'snapshot-$hours',
        createdAt: now.subtract(Duration(hours: hours)),
        documentCount: documents, sizeBytes: 100);
  const policy = PortableSnapshotRetention();
  test('empty and fewer than two points are retained', () {
    expect(policy.keep([], now), isEmpty);
    expect(policy.keep([point(9000)], now), {'snapshot-9000'});
    expect(policy.keep([point(9000), point(10000)], now).length, 2);
  });
  test('recent daily and weekly union has no duplicate copies', () {
    final points = List.generate(100, (i) => point(i * 12));
    final kept = policy.keep(points, now);
    for (var i = 0; i < 6; i++) { expect(kept, contains('snapshot-${i * 12}')); }
    expect(kept.length, lessThan(points.length));
    expect(kept, contains('snapshot-168'));
    expect(policy.keep(points.reversed.toList(), now), kept);
  });
  test('future clocks and active restore are protected', () {
    final points = List.generate(100, (i) => point(i * 24));
    points.add(point(-100));
    final kept = policy.keep(points, now, protectedUris: {'snapshot-2376'});
    expect(kept, contains('snapshot--100'));
    expect(kept, contains('snapshot-2376'));
  });
  test('empty reset cannot evict useful old recovery points', () {
    final points = List.generate(100, (i) => point(i, documents: 0));
    points.addAll([point(10000, documents: 1000), point(20000, documents: 900)]);
    final kept = policy.keep(points, now);
    expect(kept, containsAll(['snapshot-10000', 'snapshot-20000']));
  });
  test('cleanup is idempotent and timezone independent', () {
    final points = List.generate(100, (i) => point(i * 24));
    final kept = policy.keep(points, now);
    expect(policy.keep(points.where((p) => kept.contains(p.uri)).toList(), now), kept);
    expect(policy.keep(points, now.toLocal()), kept);
  });
  test('10000 points remain bounded under normal time', () {
    final points = List.generate(10000, (i) => point(i));
    expect(policy.keep(points, now).length, lessThanOrEqualTo(19));
  });
}
