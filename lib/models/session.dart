import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../services/platform_api.dart';

enum UserRole { salesOfficer, territoryOfficer }

class UserSession {
  const UserSession({
    required this.id,
    required this.employeeId,
    required this.name,
    required this.role,
    required this.roleCode,
    required this.territory,
    required this.dataOrigin,
  });

  factory UserSession.fromAuth(AuthUser user) => UserSession(
    id: user.id,
    employeeId: user.employeeId,
    name: user.name,
    // Supervisors, brand managers and management share the manager shell for now.
    role: user.role == 'sales_officer' ? UserRole.salesOfficer : UserRole.territoryOfficer,
    roleCode: user.role,
    territory: user.territory,
    dataOrigin: user.dataOrigin,
  );

  final String id;
  final String employeeId;
  final String name;
  final UserRole role;
  final String roleCode;
  final String territory;
  final String dataOrigin;

  bool get isSynthetic => dataOrigin == 'synthetic';

  String get roleLabel => switch (roleCode) {
    'sales_officer' => 'Sales Officer',
    'supervisor' => 'Territory Officer',
    'brand_manager' => 'Brand Manager',
    'management' => 'Management',
    'admin' => 'Administrator',
    _ => roleCode,
  };

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+'));
    return parts.take(2).map((p) => p.isEmpty ? '' : p[0]).join().toUpperCase();
  }
}

/// Holds the signed-in user for the app lifetime.
final ValueNotifier<UserSession?> currentSession = ValueNotifier(null);

/// An outlet as the field app shows it. Built from `/v2/outlets`.
class Shop {
  const Shop({
    required this.id,
    required this.code,
    required this.name,
    required this.area,
    required this.lat,
    required this.lng,
    required this.lastVisit,
    required this.channel,
    this.classLabel,
    this.openRecommendations = 0,
    this.visitedToday = false,
  });

  factory Shop.fromJson(Map<String, dynamic> json) {
    final lastVisitAt = json['last_visit_at'] == null
        ? null
        : DateTime.tryParse(json['last_visit_at'] as String)?.toLocal();
    final now = DateTime.now();
    final today = lastVisitAt != null &&
        lastVisitAt.year == now.year &&
        lastVisitAt.month == now.month &&
        lastVisitAt.day == now.day;
    return Shop(
      id: json['id'] as String,
      code: json['code'] as String,
      name: json['name'] as String,
      area: json['address'] as String? ?? json['territory'] as String? ?? '',
      lat: (json['lat'] as num?)?.toDouble() ?? 0,
      lng: (json['lng'] as num?)?.toDouble() ?? 0,
      lastVisit: _relative(lastVisitAt, now),
      channel: json['channel'] as String? ?? '',
      classLabel: json['class_label'] as String?,
      openRecommendations: json['open_recommendations'] as int? ?? 0,
      visitedToday: today,
    );
  }

  final String id;
  final String code;
  final String name;
  final String area;
  final double lat;
  final double lng;
  final String lastVisit;
  final String channel;
  final String? classLabel;
  final int openRecommendations;
  final bool visitedToday;

  static String _relative(DateTime? at, DateTime now) {
    if (at == null) return 'Never';
    final days = DateTime(now.year, now.month, now.day)
        .difference(DateTime(at.year, at.month, at.day))
        .inDays;
    if (days <= 0) {
      return 'Today, ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    }
    return days == 1 ? 'Yesterday' : '$days days ago';
  }
}

/// SIMULATED position. The app does not read the device GPS yet; swap this for a
/// real location stream (e.g. the geolocator plugin) before field use.
abstract final class SimulatedGps {
  static const lat = 23.79372;
  static const lng = 90.40660;
  static const detectRadiusMeters = 60.0;

  /// Nearest shop within [detectRadiusMeters], else null.
  static ({Shop shop, double meters})? detect(List<Shop> shops) {
    Shop? best;
    var bestDist = double.infinity;
    for (final s in shops) {
      final d = distanceMeters(lat, lng, s.lat, s.lng);
      if (d < bestDist) {
        best = s;
        bestDist = d;
      }
    }
    if (best == null || bestDist > detectRadiusMeters) return null;
    return (shop: best, meters: bestDist);
  }
}

double distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLng = rad(lng2 - lng1);
  final a =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLng / 2), 2);
  return 2 * r * math.asin(math.sqrt(a));
}
