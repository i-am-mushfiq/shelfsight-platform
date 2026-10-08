import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

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

  static const String baseUrl = String.fromEnvironment(
    'SHELFSIGHT_API_URL',
    defaultValue: 'https://shelfsight-api-lqqn.onrender.com',
  );

  http.Client _client = http.Client();
  String? _token;

  /// Tests replace the transport with a fake; production code never calls this.
  @visibleForTesting
  set httpClient(http.Client client) => _client = client;

  bool get signedIn => _token != null;
  void signOut() => _token = null;

  Map<String, String> get _headers => {
    'Accept': 'application/json',
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

  Future<Map<String, dynamic>> suggestedOrder(String outletId) async =>
      (await _get('/v2/outlets/$outletId/suggested-order')) as Map<String, dynamic>;

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

  // --- field ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> startVisit({
    required String clientVisitId,
    required String outletId,
    double? lat,
    double? lng,
  }) async =>
      (await _post('/v2/visits', {
        'client_visit_id': clientVisitId,
        'outlet_id': outletId,
        'lat': ?lat,
        'lng': ?lng,
      })) as Map<String, dynamic>;

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
