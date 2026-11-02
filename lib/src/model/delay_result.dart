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
    this.error,
    this.raw = const {},
  });
  final String name;
  final String identity;
  final DelayMemberStatus status;
  final int? delay;
  final String? error;
  final Map<String, dynamic> raw;
}
