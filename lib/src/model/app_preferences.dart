enum AppAppearance { system, light, dark }

enum BrandColor { cinnabar, jade, cobalt }

enum AppLanguage { system, zh, en }

enum ApplicationAccess { all, only, except }

class AppPreferences {
  const AppPreferences({
    this.appearance = AppAppearance.system,
    this.brand = BrandColor.cinnabar,
    this.language = AppLanguage.system,
    this.access = ApplicationAccess.all,
    this.packages = const [],
    this.reconnectOnRoutingChange = false,
    this.originalJson,
  });

  final Map<String, Object?>? originalJson;

  final AppAppearance appearance;
  final BrandColor brand;
  final AppLanguage language;
  final ApplicationAccess access;
  final List<String> packages;
  final bool reconnectOnRoutingChange;

  factory AppPreferences.fromJson(Map<String, dynamic> data) {
    final packages = (data['packages'] as List).cast<String>();
    final access = ApplicationAccess.values.byName(data['access'] as String);
    if (packages.any((name) => name.isEmpty || name.trim() != name) ||
        packages.toSet().length != packages.length ||
        (access == ApplicationAccess.only && packages.isEmpty)) {
      throw const FormatException('Invalid application access list');
    }
    return AppPreferences(
      appearance: AppAppearance.values.byName(data['appearance'] as String),
      brand: BrandColor.values.byName(data['brand'] as String),
      language: AppLanguage.values.byName(data['language'] as String),
      access: access,
      packages: List.unmodifiable(packages),
      originalJson: Map.unmodifiable(data),
      reconnectOnRoutingChange:
          data['reconnectOnRoutingChange'] as bool? ?? false,
    );
  }

  Map<String, Object?> toJson() => originalJson == null
      ? {
          'appearance': appearance.name,
          'brand': brand.name,
          'language': language.name,
          'access': access.name,
          'packages': packages,
          'reconnectOnRoutingChange': reconnectOnRoutingChange,
        }
      : {...?originalJson};

  AppPreferences withRoutingReconnect(bool value) =>
      AppPreferences.fromJson({...toJson(), 'reconnectOnRoutingChange': value});

  AppPreferences withAccess(ApplicationAccess access, List<String> packages) =>
      AppPreferences.fromJson({
        ...toJson(),
        'access': access.name,
        'packages': packages,
      });

  AppPreferences withAppearance(String field, String value) {
    if (!const ['appearance', 'brand', 'language'].contains(field)) {
      throw const FormatException('Unknown appearance preference');
    }
    return AppPreferences.fromJson({...toJson(), field: value});
  }
}
