enum DelayMemberStatus {
  pending,
  running,
  success,
  failed,
  timeout,
  expired,
  cancelled,
}

class DelayMemberResult {
  const DelayMemberResult({
    required this.name,
    this.identity = '',
    this.status = DelayMemberStatus.pending,
    this.delay,
  });
  final String name;
  final String identity;
  final DelayMemberStatus status;
  final int? delay;
}
