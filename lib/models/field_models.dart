/// A kind of shop the officer picks at the start of a visit. Built from
/// `/v2/catalog/store-types`; the list and its order are configured on the server.
class StoreType {
  const StoreType({
    required this.id,
    required this.code,
    required this.name,
    this.nameBn,
    this.description,
    this.icon,
  });

  factory StoreType.fromJson(Map<String, dynamic> json) => StoreType(
    id: json['id'] as String,
    code: json['code'] as String,
    name: json['name'] as String,
    nameBn: json['name_bn'] as String?,
    description: json['description'] as String?,
    icon: json['icon'] as String?,
  );

  final String id;
  final String code;
  final String name;
  final String? nameBn;
  final String? description;
  final String? icon;
}

/// A shelf photo taken during a visit and the rack (product category) it shows.
/// A null category means a mixed rack: the server identifies every product on it.
class CapturedPhoto {
  const CapturedPhoto({required this.path, this.categoryId, this.categoryName});

  final String path;
  final String? categoryId;
  final String? categoryName;

  String get rackLabel => categoryName ?? 'All products';

  CapturedPhoto withPath(String newPath) =>
      CapturedPhoto(path: newPath, categoryId: categoryId, categoryName: categoryName);
}
