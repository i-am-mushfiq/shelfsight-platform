import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/l10n.dart';

/// Thrown for any failed platform call. [retryable] is true for network
/// failures and 5xx/429, which the upload queue retries later.
class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode, this.retryable = false});
  final String message;
  final int? statusCode;
  final bool retryable;
  @override
  String toString() => message;
}

class AuthUser {
  const AuthUser({
    required this.id,
    required this.employeeId,
    required this.name,
    required this.role,
    required this.territory,
    required this.dataOrigin,
  });

  final String id;
  final String employeeId;
  final String name;
  final String role;
  final String territory;
  final String dataOrigin;

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
    id: json['id'] as String,
    employeeId: json['employee_id'] as String,
    name: json['name'] as String,
    role: json['role'] as String,
    territory: json['territory'] as String? ?? '',
    dataOrigin: json['data_origin'] as String? ?? 'production',
  );
}

/// Client for the ShelfSight platform API (/v2). One instance per app run.
class PlatformApi {
  PlatformApi._();
  static final PlatformApi instance = PlatformApi._();

  /// The address the app was built with; the server address field on the sign-in screen
  /// overrides it (saved on the phone), so a demo laptop's IP needs no rebuild.
  static const String defaultBaseUrl = String.fromEnvironment(
    'SHELFSIGHT_API_URL',
    defaultValue: 'https://shelfsight-api-lqqn.onrender.com',
  );
  static String baseUrl = defaultBaseUrl;

  static Future<File> _serverFile() async =>
      File('${(await getApplicationDocumentsDirectory()).path}/server_address.txt');

  /// Restores a saved server address. Called once at start-up.
  static Future<void> loadServerAddress() async {
    try {
      final file = await _serverFile();
      if (await file.exists()) {
        final saved = (await file.readAsString()).trim();
        if (saved.isNotEmpty) baseUrl = saved;
      }
    } catch (_) {
      // No storage (tests) or unreadable file: keep the built-in address.
    }
  }

  /// Accepts "192.168.0.103", "192.168.0.103:8000" or a full URL. A bare address gets
  /// http:// and, without a port, :8000 (the demo server's port).
  static String normalizeServerAddress(String input) {
    var value = input.trim();
    while (value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    if (value.isEmpty) return defaultBaseUrl;
    if (!value.contains('://')) {
      value = 'http://$value';
      final uri = Uri.tryParse(value);
      if (uri != null && !uri.hasPort) value = '$value:8000';
    }
    return value;
  }

  /// Switches server (signing out, since a token is only valid on its own server) and saves it.
  Future<String> setServerAddress(String input) async {
    final value = normalizeServerAddress(input);
    if (Uri.tryParse(value)?.host.isEmpty ?? true) {
      throw const ApiException('That is not a valid server address.');
    }
    baseUrl = value;
    _token = null;
    try {
      final file = await _serverFile();
      if (value == defaultBaseUrl) {
        if (await file.exists()) await file.delete();
      } else {
        await file.writeAsString(value);
      }
    } catch (_) {
      // Not saved: it still applies until the app closes.
    }
    return value;
  }

  /// Reachability check for the server address field.
  Future<String> ping(String address) async {
    final value = normalizeServerAddress(address);
    final body = await _send(
      () => _client.get(Uri.parse('$value/health'), headers: const {'Accept': 'application/json'}),
      timeout: const Duration(seconds: 8),
    );
    final provider = body is Map ? body['vision_provider'] : null;
    return provider == null ? 'Server reachable' : 'Server reachable · recognition: $provider';
  }

  http.Client _client = http.Client();
  String? _token;

  /// Tests replace the transport with a fake; production code never calls this.
  @visibleForTesting
  set httpClient(http.Client client) => _client = client;

  bool get signedIn => _token != null;
  void signOut() => _token = null;

  Map<String, String> get _headers => {
    'Accept': 'application/json',
    // Text the server writes (briefs, order reasons, recommendations) comes in this language.
    'Accept-Language': isBangla ? 'bn' : 'en',
    if (_token != null) 'Authorization': 'Bearer $_token',
  };

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Future<dynamic> _send(
    Future<http.Response> Function() call, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    http.Response response;
    try {
      response = await call().timeout(timeout);
    } on SocketException {
      throw const ApiException(
        'No connection to the ShelfSight server.',
        retryable: true,
      );
    } on TimeoutException {
      throw const ApiException(
        'The server is taking too long. Try again shortly.',
        retryable: true,
      );
    } on HttpException catch (error) {
      throw ApiException(error.message, retryable: true);
    }
    final ok = response.statusCode >= 200 && response.statusCode < 300;
    dynamic body;
    try {
      body = response.body.isEmpty ? null : jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      body = null;
    }
    if (ok) return body;
    final detail = body is Map && body['detail'] is String
        ? body['detail'] as String
        : 'Request failed (${response.statusCode}).';
    if (response.statusCode == 401) _token = null;
    throw ApiException(
      detail,
      statusCode: response.statusCode,
      retryable: response.statusCode >= 500 || response.statusCode == 429,
    );
  }

  Future<dynamic> _get(String path, [Map<String, String>? query]) =>
      _send(() => _client.get(_uri(path, query), headers: _headers));

  Future<dynamic> _post(String path, [Object? body, Duration? timeout]) =>
      _send(
        () => _client.post(
          _uri(path),
          headers: {..._headers, 'Content-Type': 'application/json'},
          body: jsonEncode(body ?? const {}),
        ),
        timeout: timeout ?? const Duration(seconds: 60),
      );

  Future<dynamic> _put(String path, Object body) => _send(
    () => _client.put(
      _uri(path),
      headers: {..._headers, 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    ),
  );

  // --- auth -------------------------------------------------------------------------

  Future<AuthUser> login(String employeeId, String password) async {
    // Free hosting can be asleep: allow a long first request.
    final body = await _send(
      () => _client.post(
        _uri('/v2/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'employee_id': employeeId.trim(), 'password': password}),
      ),
      timeout: const Duration(seconds: 90),
    ) as Map<String, dynamic>;
    _token = body['access_token'] as String;
    return AuthUser.fromJson(body['user'] as Map<String, dynamic>);
  }

  // --- outlets & intelligence ---------------------------------------------------------

  Future<List<Map<String, dynamic>>> outlets() async =>
      ((await _get('/v2/outlets')) as List).cast<Map<String, dynamic>>();

  Future<Map<String, dynamic>> outlet(String outletId) async =>
      (await _get('/v2/outlets/$outletId')) as Map<String, dynamic>;

  /// Registers a shop found in the field. It starts unverified and assigned to the officer.
  Future<Map<String, dynamic>> registerOutlet({
    required String clientOutletId,
    required String name,
    required String storeTypeId,
    String? ownerName,
    String? phone,
    String? address,
    double? lat,
    double? lng,
  }) async =>
      (await _post('/v2/outlets', {
        'client_outlet_id': clientOutletId,
        'name': name,
        'store_type_id': storeTypeId,
        'owner_name': ?ownerName,
        'phone': ?phone,
        'address': ?address,
        'lat': ?lat,
        'lng': ?lng,
      })) as Map<String, dynamic>;

  Future<Map<String, dynamic>> refreshIntelligence(String outletId) async =>
      (await _post('/v2/outlets/$outletId/intelligence:refresh')) as Map<String, dynamic>;

  Future<void> recommendationFeedback(
    String recommendationId,
    String decision, {
    int? modifiedQuantity,
    String? note,
  }) => _post('/v2/recommendations/$recommendationId/feedback', {
    'decision': decision,
    'modified_quantity': ?modifiedQuantity,
    'note': ?note,
  });

  Future<Map<String, dynamic>> callBrief(String outletId) async =>
      (await _get('/v2/outlets/$outletId/call-brief')) as Map<String, dynamic>;

  Future<Map<String, dynamic>> suggestedOrder(String outletId, {String? visitId}) async =>
      (await _get('/v2/outlets/$outletId/suggested-order', {'visit_id': ?visitId}))
          as Map<String, dynamic>;

  Future<Map<String, dynamic>> order(String orderId) async =>
      (await _get('/v2/orders/$orderId')) as Map<String, dynamic>;

  Future<Map<String, dynamic>> updateOrder(
    String orderId,
    List<Map<String, dynamic>> lines, {
    String? note,
  }) async =>
      (await _put('/v2/orders/$orderId', {'lines': lines, 'note': ?note})) as Map<String, dynamic>;

  Future<Map<String, dynamic>> confirmOrder(String orderId) async =>
      (await _post('/v2/orders/$orderId/confirm')) as Map<String, dynamic>;

  Future<Map<String, dynamic>> cancelOrder(String orderId, String reason) async =>
      (await _post('/v2/orders/$orderId/cancel', {'reason': reason})) as Map<String, dynamic>;

  Future<Map<String, dynamic>> createOrder(
    String outletId,
    String clientOrderId,
    List<Map<String, dynamic>> lines, {
    String? visitId,
  }) async =>
      (await _post('/v2/outlets/$outletId/orders', {
        'client_order_id': clientOrderId,
        'visit_id': ?visitId,
        'lines': lines,
      })) as Map<String, dynamic>;

  Future<List<Map<String, dynamic>>> products({bool? own}) async =>
      ((await _get('/v2/catalog/products', {if (own != null) 'own': '$own'})) as List)
          .cast<Map<String, dynamic>>();

  Future<List<Map<String, dynamic>>> categories() async =>
      ((await _get('/v2/catalog/categories')) as List).cast<Map<String, dynamic>>();

  /// The store types an officer chooses from at the start of a visit, in display order.
  Future<List<Map<String, dynamic>>> storeTypes() async =>
      ((await _get('/v2/catalog/store-types')) as List).cast<Map<String, dynamic>>();

  // --- field ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> startVisit({
    required String clientVisitId,
    required String outletId,
    String? storeTypeId,
    double? lat,
    double? lng,
  }) async =>
      (await _post('/v2/visits', {
        'client_visit_id': clientVisitId,
        'outlet_id': outletId,
        'store_type_id': ?storeTypeId,
        'lat': ?lat,
        'lng': ?lng,
      })) as Map<String, dynamic>;

  Future<Map<String, dynamic>> visitReport(String visitId) async =>
      (await _get('/v2/visits/$visitId/report')) as Map<String, dynamic>;

  Future<List<Map<String, dynamic>>> visits() async =>
      ((await _get('/v2/visits')) as List).cast<Map<String, dynamic>>();

  Future<Map<String, dynamic>> visit(String visitId) async =>
      (await _get('/v2/visits/$visitId')) as Map<String, dynamic>;

  Future<Map<String, dynamic>> uploadCapture({
    required String visitId,
    required String filePath,
    required String clientCaptureId,
    String? area,
    String? categoryId,
    DateTime? capturedAt,
  }) async {
    final request = http.MultipartRequest('POST', _uri('/v2/visits/$visitId/captures'))
      ..headers.addAll(_headers)
      ..fields['client_capture_id'] = clientCaptureId;
    if (area != null) request.fields['area'] = area;
    if (categoryId != null) request.fields['category_id'] = categoryId;
    if (capturedAt != null) {
      request.fields['captured_at'] = capturedAt.toUtc().toIso8601String();
    }
    request.files.add(
      await http.MultipartFile.fromPath('image', filePath, contentType: _mediaType(filePath)),
    );
    return (await _send(
      () async => http.Response.fromStream(await _client.send(request)),
      timeout: const Duration(minutes: 3),
    )) as Map<String, dynamic>;
  }

  /// Looks up catalogue products in one camera frame. Nothing is stored on the server.
  Future<Map<String, dynamic>> liveDetect(String filePath, {String? categoryId}) async {
    final request = http.MultipartRequest('POST', _uri('/v2/live/detect'))..headers.addAll(_headers);
    if (categoryId != null) request.fields['category_id'] = categoryId;
    request.files.add(await http.MultipartFile.fromPath('frame', filePath, contentType: _mediaType(filePath)));
    return (await _send(
      () async => http.Response.fromStream(await _client.send(request)),
      timeout: const Duration(seconds: 15),
    )) as Map<String, dynamic>;
  }

  /// Uploads the frames of a 360° photo sphere; the server stitches and analyses them.
  Future<Map<String, dynamic>> uploadSphere({
    required String visitId,
    required List<String> framePaths,
    required List<double> yaws,
    required String clientCaptureId,
    String? categoryId,
  }) async {
    final request = http.MultipartRequest('POST', _uri('/v2/visits/$visitId/spheres'))
      ..headers.addAll(_headers)
      ..fields['client_capture_id'] = clientCaptureId
      ..fields['yaws'] = jsonEncode(yaws);
    if (categoryId != null) request.fields['category_id'] = categoryId;
    for (final path in framePaths) {
      request.files.add(await http.MultipartFile.fromPath('frames', path, contentType: _mediaType(path)));
    }
    return (await _send(
      () async => http.Response.fromStream(await _client.send(request)),
      timeout: const Duration(minutes: 3),
    )) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> capture(String captureId) async =>
      (await _get('/v2/captures/$captureId')) as Map<String, dynamic>;

  Future<Map<String, dynamic>> reviewDetection(
    String detectionId,
    String action, {
    String? label,
    String? productId,
    String? reason,
  }) async =>
      (await _post('/v2/detections/$detectionId/review', {
        'action': action,
        'label': ?label,
        'product_id': ?productId,
        'reason': ?reason,
      })) as Map<String, dynamic>;

  Future<Map<String, dynamic>> submitVisit(String visitId) async =>
      (await _post('/v2/visits/$visitId/submit', null, const Duration(minutes: 2)))
          as Map<String, dynamic>;

  /// Authorised image download (captures and annotated images are not public).
  Future<Uint8List> imageBytes(String path) async {
    try {
      final response = await _client
          .get(_uri(path), headers: _headers)
          .timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) {
        throw ApiException('Image unavailable (${response.statusCode}).');
      }
      return response.bodyBytes;
    } on SocketException {
      throw const ApiException('No connection.', retryable: true);
    }
  }

  // --- analytics -------------------------------------------------------------------------

  Future<Map<String, dynamic>> overview({String groupBy = 'territory'}) async =>
      (await _get('/v2/analytics/overview', {'group_by': groupBy})) as Map<String, dynamic>;

  Future<Map<String, dynamic>> competition({String groupBy = 'channel'}) async =>
      (await _get('/v2/analytics/competition', {'group_by': groupBy})) as Map<String, dynamic>;

  MediaType _mediaType(String path) => switch (path.toLowerCase().split('.').last) {
    'png' => MediaType('image', 'png'),
    'webp' => MediaType('image', 'webp'),
    _ => MediaType('image', 'jpeg'),
  };
}

/// Random id generated on the device so retries are idempotent on the server.
String newClientId() {
  final random = Random.secure();
  return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}
