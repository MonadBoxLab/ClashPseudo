// Actual minimal Go contributor wire format.
Map<String, dynamic> sourceContributorWire({
  String kind = 'plugin',
  String id = 'plugin',
  int revision = 3,
  String name = 'Loaded plugin',
  String? role,
  String path = '/proxies/0',
}) => {
  'kind': kind,
  'id': id,
  'revision': revision,
  'name': name,
  'role': ?role,
  'path': path,
};

Map<String, dynamic> definitionProvenanceWire(
  Iterable<Map<String, dynamic>> contributors,
) => {
  'contributors': [
    for (final source in contributors) Map<String, dynamic>.of(source),
  ],
};
