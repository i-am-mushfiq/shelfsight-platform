import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../recognition/on_device.dart';
import 'field_logic.dart';

typedef Recognize =
    Future<Json> Function(Uint8List bytes, {bool screenPhoto, int? maxPacks, Set<String>? allowedSkus});

/// A panorama of sphere frames placed side by side: the image, and for each frame (in the
/// order given) its left edge and width as fractions of the panorama's width.
class Panorama {
  const Panorama(this.bytes, this.contentType, this.placement, this.width, this.height);
  final Uint8List bytes;
  final String contentType;
  final List<(double, double)> placement;
  final int width, height;
}

class _Fail implements Exception {
  const _Fail(this.status, this.detail);
  final int status;
  final String detail;
}

class _Request {
  _Request(this.method, this.segments, this.query, this.headers, this.json, this.fields, this.files);
  final String method;
  final List<String> segments;
  final Map<String, String> query;
  final Map<String, String> headers;
  final Json json;
  final Map<String, String> fields;
  final Map<String, List<(String, Uint8List)>> files;

  String path(int i) => i < segments.length ? segments[i] : '';
  bool route(String method, List<String> pattern) {
    if (this.method != method || pattern.length != segments.length) return false;
    for (var i = 0; i < pattern.length; i++) {
      if (pattern[i] != '*' && pattern[i] != segments[i]) return false;
    }
    return true;
  }
}

class _Response {
  const _Response(this.status, this.body, [this.bytes, this.contentType]);
  final int status;
  final Object? body;
  final Uint8List? bytes;
  final String? contentType;
}

/// The ShelfSight server, inside the app, for demonstrations with no server at all.
///
/// [PlatformApi] sends its requests here instead of over the network when the server
/// address is "On this phone", and gets the same answers in the same shapes:
///
/// * demo data the server would hold — users, shops, their order history and intelligence,
///   pre-call briefs, catalogue, store types, must-stock lists, shelf rules — comes from a
///   snapshot of the demo server's database (assets/demo/snapshot.json, made by
///   tools/export_offline_demo.py);
/// * what changes during a demo — shops registered, visits, photos, reviews, orders,
///   recommendation decisions — is kept on the phone and survives restarts;
/// * shelf photos, photo spheres and Live scan are recognised on the phone
///   ([OnDeviceRecognizer]); visit reports, share of shelf, placement checks, automatic
///   orders, recommendations and dashboards are worked out here with the server's rules
///   ([field_logic.dart]).
class OfflineBackend extends http.BaseClient {
  OfflineBackend({
    Future<Json> Function()? snapshot,
    Recognize? recognize,
    Future<Directory> Function()? storage,
    Future<Json> Function(Uint8List bytes)? inspect,
    Future<Panorama> Function(List<Uint8List> frames)? compose,
  }) : _loadSnapshot = snapshot ?? _bundledSnapshot,
       _recognize = recognize ?? OnDeviceRecognizer.instance.recognize,
       _storage = storage ?? _documents,
       _inspect = inspect ?? _inspectImage,
       _compose = compose ?? _sideBySide;

  static OfflineBackend instance = OfflineBackend();

  final Future<Json> Function() _loadSnapshot;
  final Recognize _recognize;
  final Future<Directory> Function() _storage;
  final Future<Json> Function(Uint8List bytes) _inspect;
  final Future<Panorama> Function(List<Uint8List> frames) _compose;

  static const _reviewThreshold = .75;
  static const _gpsWarningMeters = 150;
  static const _duplicateRadiusMeters = 50;
  static const _editWindow = Duration(hours: 24);
  static const _model = {
    'version_id': 'on-device-1',
    'version': 'sku110k-yolo11n + mobileclip-s1',
    'provider': 'on-device',
  };
  static const _portfolioSources = {'portfolio.core_assortment', 'portfolio.peer_benchmark', 'portfolio.target_mix'};

  late Json _snap;
  late Json _state;
  late Directory _dir;
  Future<void>? _ready;
  Future<void> _saving = Future.value();
  Future<void> _analysis = Future.value();

  Future<void> ready() => _ready ??= _load();

  static Future<Json> _bundledSnapshot() async =>
      compute(_decode, await rootBundle.loadString('assets/demo/snapshot.json'));

  static Json _decode(String text) => jsonDecode(text) as Json;

  static Future<Directory> _documents() async =>
      Directory('${(await getApplicationDocumentsDirectory()).path}/offline_demo');

  Future<void> _load() async {
    _snap = await _loadSnapshot();
    _dir = await _storage();
    await Directory('${_dir.path}/images').create(recursive: true);
    final file = File('${_dir.path}/state.json');
    _state = file.existsSync() ? jsonDecode(await file.readAsString()) as Json : _emptyState();
    for (final key in _emptyState().keys) {
      _state.putIfAbsent(key, () => <String, dynamic>{});
    }
    // Photos that were being analysed when the app closed.
    for (final c in _captures.values) {
      if (c['status'] == 'uploaded' || c['status'] == 'analysing') _queueAnalysis(c['id'] as String);
    }
  }

  static Json _emptyState() => {
    'outlets': <String, dynamic>{},
    'channel_of': <String, dynamic>{},
    'visits': <String, dynamic>{},
    'captures': <String, dynamic>{},
    'orders': <String, dynamic>{},
    'recs': <String, dynamic>{},
    'intel': <String, dynamic>{},
  };

  /// Forgets everything done on this phone: back to the demo data as shipped.
  Future<void> reset() async {
    await ready();
    await _analysis;
    _state = _emptyState();
    final images = Directory('${_dir.path}/images');
    if (images.existsSync()) images.deleteSync(recursive: true);
    await images.create(recursive: true);
    await _save();
  }

  Future<void> _save() {
    final text = jsonEncode(_state);
    return _saving = _saving.then((_) async {
      final file = File('${_dir.path}/state.json');
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      await tmp.rename(file.path);
    });
  }

  // --- transport ---------------------------------------------------------------------------------

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await ready();
    final segments = request.url.pathSegments.where((s) => s.isNotEmpty).toList();
    Json json = const {};
    final fields = <String, String>{};
    final files = <String, List<(String, Uint8List)>>{};
    if (request is http.Request && request.body.isNotEmpty) {
      final decoded = jsonDecode(request.body);
      if (decoded is Map<String, dynamic>) json = decoded;
    } else if (request is http.MultipartRequest) {
      fields.addAll(request.fields);
      for (final file in request.files) {
        files.putIfAbsent(file.field, () => []).add((file.filename ?? 'image.jpg', await file.finalize().toBytes()));
      }
    }
    final headers = {for (final e in request.headers.entries) e.key.toLowerCase(): e.value};
    _Response response;
    try {
      response = await _route(_Request(request.method, segments, request.url.queryParameters, headers, json, fields, files));
    } on _Fail catch (fail) {
      response = _Response(fail.status, {'detail': fail.detail});
    }
    final bytes = response.bytes ?? utf8.encode(jsonEncode(response.body));
    return http.StreamedResponse(
      Stream.value(bytes),
      response.status,
      contentLength: bytes.length,
      request: request,
      headers: {'content-type': response.contentType ?? 'application/json'},
    );
  }

  Future<_Response> _route(_Request r) async {
    if (r.route('GET', ['health'])) {
      return const _Response(200, {'status': 'ok', 'service': 'shelfsight-on-phone', 'vision_provider': 'on-device'});
    }
    if (r.route('POST', ['v2', 'auth', 'login'])) return _Response(200, _login(r.json));
    final user = _user(r);
    final ok = _Response.new;
    if (r.route('GET', ['v2', 'auth', 'me'])) return ok(200, user);
    // Shops and intelligence.
    if (r.route('GET', ['v2', 'outlets'])) return ok(200, _outlets(user, r.query['q']));
    if (r.route('POST', ['v2', 'outlets'])) return _register(user, r.json);
    if (r.route('GET', ['v2', 'outlets', '*'])) return ok(200, _summary(_scoped(user, r.path(2))));
    if (r.route('POST', ['v2', 'outlets', '*', 'intelligence:refresh'])) {
      final id = _scoped(user, r.path(2));
      final intel = _analyze(id);
      await _save();
      return ok(200, intel);
    }
    if (r.route('GET', ['v2', 'outlets', '*', 'recommendations'])) {
      final status = r.query['status'] ?? 'open';
      final recs = _recs(_scoped(user, r.path(2))).where((x) => status == 'all' || x['status'] == status).toList();
      return ok(200, _sortRecs(recs));
    }
    if (r.route('POST', ['v2', 'recommendations', '*', 'feedback'])) return ok(200, await _feedback(user, r.path(2), r.json));
    if (r.route('GET', ['v2', 'outlets', '*', 'call-brief'])) return ok(200, _brief(_scoped(user, r.path(2))));
    // Orders.
    if (r.route('GET', ['v2', 'outlets', '*', 'suggested-order'])) {
      return ok(200, _suggestionOut(_scoped(user, r.path(2)), r.query['visit_id']));
    }
    if (r.route('POST', ['v2', 'outlets', '*', 'orders'])) return _createOrder(user, _scoped(user, r.path(2)), r.json);
    if (r.route('GET', ['v2', 'outlets', '*', 'orders'])) {
      final id = _scoped(user, r.path(2));
      final orders = _orders.values.cast<Json>().where((o) => o['outlet_id'] == id).toList()
        ..sort((a, b) => (b['created_at'] as String).compareTo(a['created_at'] as String));
      return ok(200, [for (final o in orders) _orderOut(o)]);
    }
    if (r.route('GET', ['v2', 'orders', '*'])) return ok(200, _orderOut(_order(user, r.path(2))));
    if (r.route('PUT', ['v2', 'orders', '*'])) return ok(200, await _updateOrder(user, r.path(2), r.json));
    if (r.route('POST', ['v2', 'orders', '*', 'confirm'])) return ok(200, await _confirmOrder(user, r.path(2)));
    if (r.route('POST', ['v2', 'orders', '*', 'cancel'])) return ok(200, await _cancelOrder(user, r.path(2), r.json));
    // Catalogue.
    if (r.route('GET', ['v2', 'catalog', 'products'])) {
      final own = r.query['own'];
      return ok(200, [
        for (final p in _catalog['products'] as List)
          if (own == null || '${p['is_own']}' == own) p,
      ]);
    }
    if (r.route('GET', ['v2', 'catalog', 'categories'])) return ok(200, _catalog['categories']);
    if (r.route('GET', ['v2', 'catalog', 'store-types'])) return ok(200, _catalog['store_types']);
    if (r.route('GET', ['v2', 'catalog', 'manufacturers'])) return ok(200, _snap['manufacturers']);
    if (r.route('GET', ['v2', 'catalog', 'brands'])) return ok(200, _snap['brands']);
    // Visits, photos, review.
    if (r.route('POST', ['v2', 'visits'])) return _startVisit(user, r.json);
    if (r.route('GET', ['v2', 'visits'])) return ok(200, _visitList(user, int.tryParse(r.query['limit'] ?? '') ?? 50));
    if (r.route('GET', ['v2', 'visits', '*'])) {
      final visit = _visit(user, r.path(2));
      final captures = _visitCaptures(visit['id'] as String);
      final (all, verified) = _summaries(visit['id'] as String);
      return ok(200, {
        ..._visitOut(visit),
        'captures': [for (final c in captures) _captureOut(c)],
        'measurements': [
          for (final s in [all, verified])
            if (s.totalFacings > 0) ...[
              {'metric': 'share_of_shelf', 'basis': s.basis, 'value': s.shareOfShelf, 'numerator': s.ownFacings,
                  'denominator': s.totalFacings, 'range': s.range, 'unknown_facings': s.unknownFacings,
                  'model_versions': [_model['version_id']]},
              if (s.distinctSkus > 0)
                {'metric': 'share_of_assortment', 'basis': s.basis, 'value': s.shareOfAssortment,
                    'numerator': s.distinctOwnSkus, 'denominator': s.distinctSkus, 'range': s.range,
                    'unknown_facings': s.unknownFacings, 'model_versions': [_model['version_id']]},
            ],
        ],
      });
    }
    if (r.route('POST', ['v2', 'visits', '*', 'captures'])) return _uploadCapture(user, r.path(2), r);
    if (r.route('POST', ['v2', 'visits', '*', 'spheres'])) return _uploadSphere(user, r.path(2), r);
    if (r.route('POST', ['v2', 'visits', '*', 'submit'])) return ok(200, await _submit(user, r.path(2)));
    if (r.route('GET', ['v2', 'visits', '*', 'report'])) return ok(200, _report(_visit(user, r.path(2))));
    if (r.route('GET', ['v2', 'captures', '*'])) return ok(200, _captureOut(_capture(user, r.path(2)), detections: true));
    if (r.route('GET', ['v2', 'captures', '*', 'image'])) {
      final capture = _capture(user, r.path(2));
      final file = File('${_dir.path}/images/${capture['file']}');
      if (!file.existsSync()) throw const _Fail(404, 'Image not found');
      return _Response(200, null, await file.readAsBytes(), capture['content_type'] as String? ?? 'image/jpeg');
    }
    if (r.route('GET', ['v2', 'inferences', '*', 'annotated'])) throw const _Fail(404, 'Annotated image not found');
    if (r.route('POST', ['v2', 'detections', '*', 'review'])) return ok(200, await _review(user, r.path(2), r.json));
    if (r.route('POST', ['v2', 'live', 'detect'])) {
      final frame = r.files['frame']?.first.$2;
      if (frame == null) throw const _Fail(422, 'Send a frame');
      return ok(200, await _recognize(frame, screenPhoto: OnDeviceRecognizer.screenPhotos.value, maxPacks: 16,
          allowedSkus: _allowedSkus(r.fields['category_id'])));
    }
    // Dashboards.
    if (r.route('GET', ['v2', 'analytics', 'overview'])) {
      return ok(200, _overview(user, r.query['group_by'] ?? 'territory'));
    }
    if (r.route('GET', ['v2', 'analytics', 'competition'])) {
      return ok(200, _competition(user, r.query['group_by'] ?? 'channel', r.query['basis'] ?? 'all'));
    }
    throw _Fail(404, 'Not available without a server: ${r.method} /${r.segments.join('/')}');
  }

  // --- data access ---------------------------------------------------------------------------------

  Json get _catalog => _snap['catalog'] as Json;
  Map<String, dynamic> get _products => _snap['products'] as Json;
  Map<String, dynamic> get _channels => _snap['channels'] as Json;
  Map<String, dynamic> get _visits => _state['visits'] as Json;
  Map<String, dynamic> get _captures => _state['captures'] as Json;
  Map<String, dynamic> get _orders => _state['orders'] as Json;
  String get _origin => _snap['data_origin'] as String? ?? 'synthetic';

  late final Map<String, Json> _productMap = _products.cast<String, Json>();
  late final Map<String, Json> _bySku = {for (final p in _productMap.values) p['sku'] as String: p};
  late final Map<String, Json> _manufacturers = {
    for (final m in (_snap['manufacturers'] as List).cast<Json>()) m['id'] as String: m,
  };
  late final Map<String, Json> _brands = {for (final b in (_snap['brands'] as List).cast<Json>()) b['id'] as String: b};
  late final Set<String> _own = {for (final m in _manufacturers.values) if (m['is_own'] == true) m['id'] as String};
  late final Map<String, List<String>> _descendants = {
    for (final e in (_snap['category_descendants'] as Json).entries) e.key: (e.value as List).cast<String>(),
  };
  late final Map<String, String> _brandOf = {
    for (final p in _productMap.values) p['id'] as String: p['brand_id'] as String,
  };
  List<Json> get _core => (_snap['core'] as List).cast<Json>();
  List<Json> get _rules => (_snap['placement_rules'] as List).cast<Json>();

  static String _id() {
    final random = math.Random.secure();
    return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  static String _now() => DateTime.now().toUtc().toIso8601String();
  static String _today() => DateTime.now().toIso8601String().substring(0, 10);
  static T _copy<T>(T value) => jsonDecode(jsonEncode(value)) as T;

  Json _login(Json body) {
    final employee = '${body['employee_id'] ?? ''}'.trim().toUpperCase();
    final entry = (_snap['users'] as Json)[employee] as Json?;
    if (entry == null || entry['password'] != body['password']) {
      throw const _Fail(401, 'Employee ID or password is incorrect');
    }
    return {
      'access_token': 'offline:$employee',
      'token_type': 'bearer',
      'expires_at': DateTime.now().toUtc().add(const Duration(hours: 12)).toIso8601String(),
      'user': entry['user'],
    };
  }

  Json _user(_Request r) {
    final token = (r.headers['authorization'] ?? '').replaceFirst('Bearer ', '');
    final entry = token.startsWith('offline:') ? (_snap['users'] as Json)[token.substring(8)] as Json? : null;
    if (entry == null) throw const _Fail(401, 'Not signed in');
    return entry['user'] as Json;
  }

  Json _userEntry(Json user) => (_snap['users'] as Json)[user['employee_id']] as Json;
  bool _officer(Json user) => user['role'] == 'sales_officer';

  /// Shops this user may see: assigned ones (officers), the whole area (others), and shops
  /// registered on this phone.
  List<String> _scope(Json user) => [
    ...(_userEntry(user)['outlet_ids'] as List).cast<String>(),
    for (final o in (_state['outlets'] as Json).values)
      if (!_officer(user) || o['registered_by'] == user['id']) o['summary']['id'] as String,
  ];

  String _scoped(Json user, String outletId) {
    if (!_scope(user).contains(outletId)) throw const _Fail(404, 'Outlet not found');
    return outletId;
  }

  Json _outlet(String id) =>
      ((_state['outlets'] as Json)[id] ?? (_snap['outlets'] as Json)[id]) as Json? ?? (throw const _Fail(404, 'Outlet not found'));

  String _channelOf(String outletId) => (_state['channel_of'] as Json)[outletId] as String? ?? _outlet(outletId)['channel_id'] as String;

  Json _channelRef(String? id) {
    final c = _channels[id] as Json?;
    return {'id': c?['id'], 'code': c?['code'], 'name': c?['name'], 'icon': c?['icon']};
  }

  // --- shops ---------------------------------------------------------------------------------------

  Json _summary(String id) {
    final record = _outlet(id);
    final channel = _channels[_channelOf(id)] as Json;
    final visits = _visits.values.cast<Json>().where((v) => v['outlet_id'] == id).map((v) => v['started_at'] as String);
    final last = visits.isEmpty ? record['summary']['last_visit_at'] : visits.reduce((a, b) => a.compareTo(b) > 0 ? a : b);
    return {
      ...(record['summary'] as Json),
      'channel': channel['name'], 'channel_code': channel['code'], 'channel_id': channel['id'],
      'channel_icon': channel['icon'], 'last_visit_at': last,
      'open_recommendations': _recs(id).where((x) => x['status'] == 'open').length,
    };
  }

  List<Json> _outlets(Json user, String? q) {
    final rows = [for (final id in _scope(user)) _summary(id)];
    final query = q?.toLowerCase();
    return rows
        .where((o) => query == null || '${o['name']} ${o['code']}'.toLowerCase().contains(query))
        .toList()
      ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
  }

  Future<_Response> _register(Json user, Json body) async {
    final clientId = body['client_outlet_id'] as String? ?? '';
    final name = (body['name'] as String? ?? '').trim();
    if (clientId.length < 8 || name.length < 2) throw const _Fail(422, 'Enter the shop name');
    final code = 'F-${clientId.substring(0, math.min(10, clientId.length)).toUpperCase()}';
    final outlets = _state['outlets'] as Json;
    for (final o in outlets.values.cast<Json>()) {
      if (o['summary']['code'] == code) {
        if (o['registered_by'] != user['id']) throw const _Fail(409, 'client_outlet_id already used');
        return _Response(200, {..._summary(o['summary']['id'] as String), 'possible_duplicates': [], 'replayed': true});
      }
    }
    final storeType = _channels[body['store_type_id']] as Json?;
    if (storeType == null || storeType['is_store_type'] != true) throw const _Fail(422, 'Unknown store type');
    final template = (_snap['outlet_templates'] as Json)[storeType['id']] as Json?;
    if (template == null) throw const _Fail(422, 'Unknown store type');
    final id = _id();
    // The template is a new shop of this store type on the demo server: give it this shop's
    // id, and its recommendations ids of their own.
    var text = jsonEncode(template).replaceAll(_snap['template_outlet_id'] as String, id);
    for (final rec in (template['intelligence']['recommendations'] as List).cast<Json>()) {
      text = text.replaceAll(rec['id'] as String, _id());
    }
    final record = jsonDecode(text) as Json;
    final lat = (body['lat'] as num?)?.toDouble(), lng = (body['lng'] as num?)?.toDouble();
    final duplicates = <Json>[];
    if (lat != null && lng != null) {
      for (final other in _scope(user)) {
        final o = _outlet(other);
        final olat = (o['lat'] as num?)?.toDouble(), olng = (o['lng'] as num?)?.toDouble();
        if (olat == null || olng == null) continue;
        final meters = distanceM(lat, lng, olat, olng);
        if (meters <= _duplicateRadiusMeters) {
          duplicates.add({'id': other, 'code': o['summary']['code'], 'name': o['summary']['name'],
              'meters': (meters * 10).round() / 10});
        }
      }
    }
    final entry = _userEntry(user);
    final territory = (_snap['territories'] as Json)[entry['territory_id']] as Json?;
    record
      ..['summary'] = {
        'id': id, 'code': code, 'name': name, 'name_bn': body['name_bn'], 'address': body['address'],
        'lat': lat, 'lng': lng, 'channel': storeType['name'], 'channel_code': storeType['code'],
        'channel_id': storeType['id'], 'channel_icon': storeType['icon'], 'territory': user['territory'] ?? '',
        'class_code': null, 'class_label': null, 'last_visit_at': null, 'open_recommendations': 0,
        'is_verified': false, 'data_origin': _origin,
      }
      ..['code'] = code
      ..['address'] = body['address']
      ..['is_verified'] = false
      ..['lat'] = lat
      ..['lng'] = lng
      ..['territory_id'] = entry['territory_id']
      ..['channel_id'] = storeType['id']
      ..['registered_by'] = user['id']
      ..['client_outlet_id'] = clientId
      ..['owner_name'] = body['owner_name']
      ..['phone'] = body['phone']
      ..['analytics'] = {
        'monthly_value_bdt': 0.0,
        'scores': {for (final s in (record['intelligence']['scores'] as List).cast<Json>()) s['dimension']: s['value']},
        'groups': {
          'territory': [entry['territory_id'], territory?['name'] ?? user['territory']],
          'channel': [storeType['id'], storeType['name']],
          'officer': [user['id'], user['name']],
          'distributor': ['none', 'Unassigned'],
          'outlet': [id, name],
        },
      };
    (record['intelligence']['outlet'] as Json)
      ..['name'] = name
      ..['code'] = code;
    outlets[id] = record;
    await _save();
    duplicates.sort((a, b) => (a['meters'] as num).compareTo(b['meters'] as num));
    return _Response(201, {..._summary(id), 'possible_duplicates': duplicates.take(5).toList(), 'replayed': false});
  }

  // --- recommendations and intelligence ------------------------------------------------------------

  /// The shop's recommendations as this phone knows them (decisions included).
  List<Json> _recs(String outletId) {
    final all = _state['recs'] as Json;
    final existing = all[outletId] as List?;
    if (existing != null) return existing.cast<Json>();
    final recs = [
      for (final rec in (_copy(_outlet(outletId)['intelligence']['recommendations']) as List).cast<Json>())
        rec
          ..['product_id'] = (rec['product'] as Map?)?['id']
          ..['updated_at'] = rec['created_at'],
    ];
    all[outletId] = recs;
    return recs;
  }

  List<Json> _sortRecs(List<Json> recs) => recs
    ..sort((a, b) {
      final p = (a['priority'] as int).compareTo(b['priority'] as int);
      return p != 0 ? p : (b['confidence'] as num).compareTo(a['confidence'] as num);
    });

  /// services/intelligence.py sync_recommendations: upsert open recommendations by dedupe key,
  /// supersede stale ones from the sources that ran; decided ones are history.
  List<Json> _syncRecs(String outletId, List<Json> drafts, Set<String> sourcesRun, String? visitId) {
    final existing = _recs(outletId);
    final openByKey = {for (final r in existing) if (r['status'] == 'open') r['dedupe_key']: r};
    final decidedByKey = {
      for (final r in existing) if (r['status'] == 'accepted' || r['status'] == 'modified') r['dedupe_key']: r,
    };
    final cooldown = DateTime.now().toUtc().subtract(const Duration(days: 30));
    final rejected = {
      for (final r in existing)
        if (r['status'] == 'rejected' && DateTime.parse(r['updated_at'] as String).isAfter(cooldown)) r['dedupe_key'],
    };
    final seen = <Object?>{};
    final result = <Json>[];
    for (final draft in drafts) {
      final key = draft['dedupe_key'];
      seen.add(key);
      if (rejected.contains(key)) continue;
      final decided = decidedByKey[key];
      if (decided != null) {
        result.add(decided);
        continue;
      }
      var rec = openByKey[key];
      if (rec == null) {
        rec = {'id': _id(), 'dedupe_key': key, 'type': draft['type'], 'status': 'open', 'created_at': _now(),
            'data_origin': _origin};
        existing.add(rec);
      }
      final productId = draft['product_id'] as String? ?? (draft['product'] as Map?)?['id'] as String?;
      final product = productId == null ? null : _productMap[productId];
      final ruleSets = _outlet(outletId)['intelligence']['rule_sets'];
      rec
        ..['visit_id'] = visitId ?? rec['visit_id']
        ..['product_id'] = productId
        ..['product'] = product == null ? null : {'id': product['id'], 'sku': product['sku'], 'name': product['name']}
        ..['action'] = draft['action']
        ..['reason'] = draft['reason']
        ..['evidence'] = {...(draft['evidence'] as Json), 'rule_sets': ruleSets}
        ..['expected_impact'] = draft['expected_impact']
        ..['suggested_quantity'] = draft['suggested_quantity']
        ..['confidence'] = draft['confidence']
        ..['priority'] = draft['priority']
        ..['source'] = draft['source']
        ..['generator_version'] = 'recommendations-1.0'
        ..['disclaimer'] = 'Recommendation, not fact: based on the evidence shown.'
        ..['updated_at'] = _now();
      result.add(rec);
    }
    for (final entry in openByKey.entries) {
      if (!seen.contains(entry.key) && sourcesRun.contains(entry.value['source'])) {
        entry.value
          ..['status'] = 'superseded'
          ..['updated_at'] = _now();
      }
    }
    return _sortRecs(result);
  }

  /// services/intelligence.py analyze + persist: the shop's intelligence from its order history
  /// (snapshot) and the shelf of its latest analysed visit on this phone.
  Json _analyze(String outletId, {String? visitId}) {
    final record = _outlet(outletId);
    final intel = _copy(record['intelligence']) as Json;
    final channelId = _channelOf(outletId);
    final path = (_channels[channelId] as Json)['path'] as String;
    final visit = _latestShelfVisit(outletId);
    ShelfSummary? all, verified;
    var placement = <Json>[], presence = <Json>[];
    if (visit != null) {
      final facings = _facings(visit['id'] as String);
      all = summarize(facings, _own, 'all');
      verified = summarize(facings, _own, 'verified');
      placement = evaluatePlacement(_rules, facings, path, _brandOf, _own, _descendants);
      presence = presenceByManufacturer(all, _productMap, _manufacturers);
    }
    final summary = verified != null && verified.verifiedRatio >= .8 ? verified : all;
    final compliance = complianceScore(placement);
    final target = ownShareTarget(_rules, path);
    final core = applicableCore(_core, channelId, record['class_id'] as String?);
    final scores = (intel['scores'] as List).cast<Json>();
    intel['scores'] = [
      scores.first,
      ...shelfScores(summary, core, target, compliance, placement.where((p) => p['status'] != 'not_evaluable').length),
      scores.last,
    ];
    final drafts = [
      ...(record['portfolio_recommendations'] as List).cast<Json>(),
      if (visit != null)
        ...shelfDrafts(outletId, visit['id'] as String, placement, summary, presence, target, [_model['version_id']!]),
    ];
    final sources = {..._portfolioSources, if (visit != null) ...{'placement.rules', 'competitor.share_of_shelf'}};
    intel
      ..['as_of'] = _today()
      ..['latest_visit'] = visit == null
          ? null
          : {'id': visit['id'], 'started_at': visit['started_at'], 'model_versions': [_model['version_id']]}
      ..['shelf'] = visit == null ? null : {'all': all!.toJson(), 'verified': verified!.toJson()}
      ..['placement'] = {'score': compliance, 'results': placement}
      ..['competition'] = {...(intel['competition'] as Json), 'presence': presence}
      ..['recommendations'] = _syncRecs(outletId, drafts, sources, visitId ?? visit?['id'] as String?);
    (intel['outlet'] as Json)['channel_id'] = channelId;
    (_state['intel'] as Json)[outletId] = {
      'scores': {for (final s in (intel['scores'] as List).cast<Json>()) s['dimension']: s['value']},
    };
    return intel;
  }

  Future<Json> _feedback(Json user, String recId, Json body) async {
    for (final outletId in _scope(user)) {
      for (final rec in _recs(outletId)) {
        if (rec['id'] != recId) continue;
        final decision = body['decision'] as String?;
        if (!const {'accepted', 'modified', 'rejected'}.contains(decision)) throw const _Fail(422, 'Unknown decision');
        if (!const {'open', 'accepted', 'modified'}.contains(rec['status'])) {
          throw _Fail(409, 'Recommendation is ${rec['status']}');
        }
        if (decision == 'modified' && body['modified_quantity'] == null) {
          throw const _Fail(422, 'modified requires modified_quantity');
        }
        rec
          ..['status'] = decision
          ..['updated_at'] = _now()
          ..['feedback'] = {'decision': decision, 'modified_quantity': body['modified_quantity'], 'note': body['note']};
        if (decision == 'modified') rec['suggested_quantity'] = body['modified_quantity'];
        await _save();
        return {'id': rec['id'], 'status': rec['status']};
      }
    }
    throw const _Fail(404, 'Recommendation not found');
  }

  Json _brief(String outletId) {
    final record = _outlet(outletId);
    final brief = record['brief'] as Json;
    final local = _orders.values.cast<Json>().where((o) => o['outlet_id'] == outletId && o['status'] == 'confirmed').toList()
      ..sort((a, b) => (b['created_at'] as String).compareTo(a['created_at'] as String));
    final lastOrders = [
      for (final o in local)
        {
          'id': o['id'], 'order_date': o['order_date'], 'lines': (o['items'] as List).length, 'value': _orderValue(o),
          'products': [
            for (final i in (o['items'] as List).cast<Json>().take(6)) _productMap[i['product_id']]?['name'] ?? i['product_id'],
          ],
        },
      ...(brief['last_orders'] as List).cast<Json>(),
    ].take(3).toList();
    return {
      'data_origin': _origin,
      ...buildBrief(
        outlet: {'id': outletId, 'name': record['summary']['name'], 'channel': (_channels[_channelOf(outletId)] as Json)['name']},
        classification: record['classification'] as Json?,
        lastOrders: lastOrders,
        recommendations: _recs(outletId).where((x) => x['status'] == 'open').toList(),
        promotions: (brief['promotions'] as List).cast<Json>(),
        competitorNotes: (brief['competitor_notes'] as List).cast<Json>(),
      ),
    };
  }

  // --- visits --------------------------------------------------------------------------------------

  Json _visitOut(Json v) => {
    'id': v['id'], 'client_visit_id': v['client_visit_id'], 'outlet_id': v['outlet_id'], 'user_id': v['user_id'],
    'status': v['status'], 'started_at': v['started_at'], 'ended_at': v['ended_at'],
    'distance_from_outlet_m': v['distance_from_outlet_m'],
    'location_warning': ((v['distance_from_outlet_m'] as num?) ?? 0) > _gpsWarningMeters,
    'store_type': v['store_type_id'] == null ? null : _channelRef(v['store_type_id'] as String),
    'previous_store_type': v['previous_store_type_id'] == null ? null : _channelRef(v['previous_store_type_id'] as String),
    'data_origin': v['data_origin'],
  };

  Future<_Response> _startVisit(Json user, Json body) async {
    final outletId = _scoped(user, body['outlet_id'] as String? ?? '');
    final clientId = body['client_visit_id'] as String? ?? '';
    for (final v in _visits.values.cast<Json>()) {
      if (v['client_visit_id'] != clientId) continue;
      if (v['outlet_id'] != outletId || v['user_id'] != user['id']) throw const _Fail(409, 'client_visit_id already used');
      return _Response(201, _visitOut(v));
    }
    final storeTypeId = body['store_type_id'] as String?;
    if (storeTypeId != null && (_channels[storeTypeId] as Json?)?['is_store_type'] != true) {
      throw const _Fail(422, 'Unknown store type');
    }
    final record = _outlet(outletId);
    final lat = (body['lat'] as num?)?.toDouble(), lng = (body['lng'] as num?)?.toDouble();
    final olat = (record['lat'] as num?)?.toDouble(), olng = (record['lng'] as num?)?.toDouble();
    final distance = lat != null && lng != null && olat != null && olng != null
        ? (distanceM(lat, lng, olat, olng) * 10).round() / 10
        : null;
    String? previous;
    final current = _channelOf(outletId);
    if (storeTypeId != null && storeTypeId != current) {
      // The officer at the shop knows best what kind of shop it is: the shop's store type follows.
      previous = current;
      (_state['channel_of'] as Json)[outletId] = storeTypeId;
    }
    final visit = {
      'id': _id(), 'client_visit_id': clientId, 'outlet_id': outletId, 'user_id': user['id'], 'status': 'open',
      'started_at': body['started_at'] ?? _now(), 'ended_at': null, 'distance_from_outlet_m': distance,
      'lat': lat, 'lng': lng, 'store_type_id': storeTypeId ?? current, 'previous_store_type_id': previous,
      'data_origin': _origin,
    };
    _visits[visit['id'] as String] = visit;
    await _save();
    return _Response(201, _visitOut(visit));
  }

  Json _visit(Json user, String visitId, {bool write = false}) {
    final visit = _visits[visitId] as Json?;
    if (visit == null) throw const _Fail(404, 'Visit not found');
    _scoped(user, visit['outlet_id'] as String);
    if (write && visit['user_id'] != user['id']) {
      throw const _Fail(403, 'Only the officer who started the visit can change it');
    }
    return visit;
  }

  List<Json> _visitCaptures(String visitId) =>
      _captures.values.cast<Json>().where((c) => c['visit_id'] == visitId).toList()
        ..sort((a, b) => (a['uploaded_at'] as String).compareTo(b['uploaded_at'] as String));

  /// The facings of a visit's analysed (not duplicate) photos, after review.
  List<Facing> _facings(String visitId) => [
    for (final c in _visitCaptures(visitId))
      if (c['status'] == 'analysed' && c['duplicate_of'] == null)
        for (final d in (c['detections'] as List? ?? const []).cast<Json>())
          Facing(
            id: d['id'] as String,
            captureId: c['id'] as String,
            label: d['verification'] == 'rejected' ? 'rejected' : d['final']['label'] as String,
            productId: d['final']['product_id'] as String?,
            manufacturerId: d['final']['manufacturer_id'] as String?,
            confidence: (d['predicted']['confidence'] as num).toDouble(),
            verified: d['verification'] == 'confirmed' || d['verification'] == 'corrected',
            yCenter: (d['box']['y'] as num).toDouble() + (d['box']['height'] as num).toDouble() / 2,
            shelfRow: d['shelf_row'] as int?,
            shelfRowsTotal: d['shelf_rows_total'] as int?,
            categoryId: _productMap[d['final']['product_id']]?['category_id'] as String? ?? c['category_id'] as String?,
          ),
  ];

  (ShelfSummary, ShelfSummary) _summaries(String visitId) {
    final facings = _facings(visitId);
    return (summarize(facings, _own, 'all'), summarize(facings, _own, 'verified'));
  }

  /// The latest visit to the shop whose photos gave a share of shelf (intelligence.py).
  Json? _latestShelfVisit(String outletId, {String basis = 'all'}) {
    final visits = _visits.values.cast<Json>().where((v) => v['outlet_id'] == outletId).toList()
      ..sort((a, b) => (b['started_at'] as String).compareTo(a['started_at'] as String));
    for (final v in visits.take(10)) {
      if (summarize(_facings(v['id'] as String), _own, basis).totalFacings > 0) return v;
    }
    return null;
  }

  ShelfStock? _stock(String visitId) => shelfStock(
    visitId,
    [for (final c in _visitCaptures(visitId)) if (c['status'] == 'analysed' && c['duplicate_of'] == null) c],
    _facings(visitId),
    _descendants,
  );

  List<Json> _visitList(Json user, int limit) {
    final scope = _scope(user).toSet();
    final visits = _visits.values.cast<Json>().where((v) =>
        scope.contains(v['outlet_id']) && (!_officer(user) || v['user_id'] == user['id'])).toList()
      ..sort((a, b) => (b['started_at'] as String).compareTo(a['started_at'] as String));
    return [
      for (final v in visits.take(math.min(limit, 200)))
        () {
          final (all, verified) = _summaries(v['id'] as String);
          return {
            ..._visitOut(v),
            'outlet_name': _outlet(v['outlet_id'] as String)['summary']['name'],
            'photos': _visitCaptures(v['id'] as String).length,
            'share_of_shelf': {
              for (final s in [all, verified])
                if (s.totalFacings > 0) s.basis: {'value': s.shareOfShelf, 'facings': s.totalFacings, 'range': s.range},
            },
          };
        }(),
    ];
  }

  // --- photos --------------------------------------------------------------------------------------

  Json _captureOut(Json c, {bool detections = false}) {
    final dets = (c['detections'] as List? ?? const []).cast<Json>();
    final inference = c['inference'] as Json?;
    return {
      'id': c['id'], 'client_capture_id': c['client_capture_id'], 'visit_id': c['visit_id'], 'status': c['status'],
      'area': c['area'], 'category_id': c['category_id'], 'quality': c['quality'],
      'quality_acceptable': c['quality']?['acceptable'] ?? true, 'duplicate_of': c['duplicate_of'],
      'width': c['width'], 'height': c['height'], 'uploaded_at': c['uploaded_at'],
      'image_url': '/v2/captures/${c['id']}/image',
      'inference': inference == null
          ? null
          : {...inference, 'detections_total': dets.length, 'needs_review': dets.where((d) => d['needs_review'] == true).length},
      'data_origin': c['data_origin'], 'kind': c['kind'] ?? 'photo', 'sphere': c['sphere'],
      if (detections && inference != null) 'detections': dets,
    };
  }

  Json _capture(Json user, String captureId) {
    final capture = _captures[captureId] as Json?;
    if (capture == null) throw const _Fail(404, 'Capture not found');
    _visit(user, capture['visit_id'] as String);
    return capture;
  }

  Json _openVisit(Json user, String visitId, String? categoryId) {
    final visit = _visit(user, visitId, write: true);
    if (visit['status'] != 'open') throw const _Fail(409, 'Visit is already submitted');
    if (categoryId != null && !(_snap['category_names'] as Json).containsKey(categoryId)) {
      throw const _Fail(422, 'Unknown category');
    }
    return visit;
  }

  Json? _existingCapture(String visitId, String clientId) {
    for (final c in _captures.values.cast<Json>()) {
      if (c['client_capture_id'] != clientId) continue;
      if (c['visit_id'] != visitId) throw const _Fail(409, 'client_capture_id already used for another visit');
      return c;
    }
    return null;
  }

  /// Products a photo tagged with [categoryId] can show: that category and its sub-categories.
  Set<String>? _allowedSkus(String? categoryId) {
    if (categoryId == null || categoryId.isEmpty) return null;
    final scope = {...?_descendants[categoryId], categoryId};
    return {for (final p in _productMap.values) if (scope.contains(p['category_id'])) p['sku'] as String};
  }

  static String _fingerprint(Uint8List bytes) {
    var hash = 0x811c9dc5;
    for (final b in bytes) {
      hash = ((hash ^ b) * 0x01000193) & 0xffffffff;
    }
    return '${bytes.length}-${hash.toRadixString(16)}';
  }

  Future<_Response> _uploadCapture(Json user, String visitId, _Request r) async {
    final clientId = r.fields['client_capture_id'] ?? '';
    final categoryId = r.fields['category_id'];
    final visit = _openVisit(user, visitId, categoryId);
    final existing = _existingCapture(visitId, clientId);
    if (existing != null) return _Response(200, {..._captureOut(existing), 'replayed': true});
    final upload = r.files['image']?.first;
    if (upload == null) throw const _Fail(422, 'Send an image');
    final (name, bytes) = upload;
    Json quality;
    try {
      quality = await _inspect(bytes);
    } catch (_) {
      throw const _Fail(422, 'Unable to decode image');
    }
    final fingerprint = _fingerprint(bytes);
    final duplicate = _visitCaptures(visitId).where((c) => c['fingerprint'] == fingerprint).firstOrNull;
    final id = _id();
    final png = name.toLowerCase().endsWith('.png');
    final file = '$id.${png ? 'png' : 'jpg'}';
    await File('${_dir.path}/images/$file').writeAsBytes(bytes, flush: true);
    final capture = {
      'id': id, 'client_capture_id': clientId, 'visit_id': visitId, 'outlet_id': visit['outlet_id'],
      'status': duplicate != null ? 'duplicate' : 'uploaded', 'area': r.fields['area'], 'category_id': categoryId,
      'quality': quality, 'duplicate_of': duplicate?['id'], 'width': quality['width'], 'height': quality['height'],
      'uploaded_at': _now(), 'captured_at': r.fields['captured_at'], 'data_origin': _origin, 'kind': 'photo',
      'sphere': null, 'file': file, 'content_type': png ? 'image/png' : 'image/jpeg', 'fingerprint': fingerprint,
      'screen_photo': OnDeviceRecognizer.screenPhotos.value,
    };
    _captures[id] = capture;
    await _save();
    if (duplicate == null) _queueAnalysis(id);
    return _Response(201, {..._captureOut(capture), 'replayed': false});
  }

  Future<_Response> _uploadSphere(Json user, String visitId, _Request r) async {
    final clientId = r.fields['client_capture_id'] ?? '';
    final categoryId = r.fields['category_id'];
    final visit = _openVisit(user, visitId, categoryId);
    final existing = _existingCapture(visitId, clientId);
    if (existing != null) return _Response(200, {..._captureOut(existing), 'replayed': true});
    final frames = r.files['frames'] ?? const [];
    if (frames.length < 2 || frames.length > 36) throw const _Fail(422, 'Send between 2 and 36 frames');
    List<double>? yaws;
    try {
      final raw = r.fields['yaws'];
      yaws = raw == null ? null : [for (final v in jsonDecode(raw) as List) (v as num).toDouble()];
    } catch (_) {
      throw const _Fail(422, 'yaws must be a JSON list of numbers');
    }
    // Frames in the order they were taken around the circle.
    final order = List<int>.generate(frames.length, (i) => i);
    double? yawSpan;
    if (yaws != null && yaws.length == frames.length) {
      order.sort((a, b) => yaws![a].compareTo(yaws[b]));
      yawSpan = yaws.reduce(math.max) - yaws.reduce(math.min);
    }
    final sorted = [for (final i in order) frames[i].$2];
    Panorama panorama;
    try {
      panorama = await _compose(sorted);
    } catch (_) {
      throw const _Fail(422, 'A frame is not a readable image');
    }
    final id = _id();
    final extension = panorama.contentType == 'image/png' ? 'png' : 'jpg';
    await File('${_dir.path}/images/$id.$extension').writeAsBytes(panorama.bytes, flush: true);
    final frameFiles = <String>[];
    for (var i = 0; i < sorted.length; i++) {
      final file = '$id-frame$i.jpg';
      await File('${_dir.path}/images/$file').writeAsBytes(sorted[i], flush: true);
      frameFiles.add(file);
    }
    final horizontal = math.min(360.0, yawSpan != null ? yawSpan + 60 : 60 * sorted.length * .7);
    final capture = {
      'id': id, 'client_capture_id': clientId, 'visit_id': visitId, 'outlet_id': visit['outlet_id'],
      'status': 'uploaded', 'area': '360° photo sphere', 'category_id': categoryId,
      'quality': {'width': panorama.width, 'height': panorama.height, 'acceptable': true, 'warnings': <String>[]},
      'duplicate_of': null, 'width': panorama.width, 'height': panorama.height, 'uploaded_at': _now(),
      'data_origin': _origin, 'kind': 'sphere',
      'sphere': {
        'kind': 'sphere', 'frames': sorted.length, 'frames_joined': sorted.length, 'stitched': false,
        'yaw_span': yawSpan, 'horizontal_degrees': (horizontal * 10).round() / 10,
        'vertical_degrees': (math.min(170.0, horizontal * panorama.height / panorama.width) * 10).round() / 10,
        'note': 'Frames placed side by side on this phone, each recognised on its own.',
      },
      'file': '$id.$extension', 'content_type': panorama.contentType, 'frame_files': frameFiles,
      'frame_placement': [for (final (left, width) in panorama.placement) [left, width]],
      'screen_photo': OnDeviceRecognizer.screenPhotos.value,
    };
    _captures[id] = capture;
    await _save();
    _queueAnalysis(id);
    return _Response(201, {..._captureOut(capture), 'replayed': false});
  }

  void _queueAnalysis(String captureId) {
    _analysis = _analysis.then((_) => _analyse(captureId)).catchError((Object _) {});
  }

  /// Waits for photos already sent to be recognised (tests, and the reset).
  Future<void> idle() async {
    await ready();
    await _analysis;
  }

  Future<void> _analyse(String captureId) async {
    final c = _captures[captureId] as Json?;
    if (c == null || (c['status'] != 'uploaded' && c['status'] != 'analysing')) return;
    c['status'] = 'analysing';
    final started = DateTime.now();
    final screen = c['screen_photo'] as bool? ?? true;
    final allowed = _allowedSkus(c['category_id'] as String?);
    try {
      final looks = <Json>[];
      final frames = (c['frame_files'] as List?)?.cast<String>();
      if (frames == null) {
        final bytes = await File('${_dir.path}/images/${c['file']}').readAsBytes();
        looks.addAll(((await _recognize(bytes, screenPhoto: screen, allowedSkus: allowed))['detections'] as List).cast<Json>());
      } else {
        // A sphere: each frame recognised on its own, its boxes placed where the frame sits.
        final placement = (c['frame_placement'] as List).cast<List>();
        for (var i = 0; i < frames.length; i++) {
          final bytes = await File('${_dir.path}/images/${frames[i]}').readAsBytes();
          final left = (placement[i][0] as num).toDouble(), width = (placement[i][1] as num).toDouble();
          final result = await _recognize(bytes, screenPhoto: screen, allowedSkus: allowed);
          for (final d in (result['detections'] as List).cast<Json>()) {
            final box = d['box'] as Json;
            looks.add({
              ...d,
              'box': {
                'x': left + (box['x'] as num) * width, 'y': box['y'],
                'width': (box['width'] as num) * width, 'height': box['height'],
              },
              'evidence': {...?(d['evidence'] as Json?), 'frame': i},
            });
          }
        }
      }
      c
        ..['detections'] = _detections(looks)
        ..['inference'] = {
          'id': _id(), 'status': 'succeeded', 'latency_ms': DateTime.now().difference(started).inMilliseconds,
          'cost_usd': 0.0,
          'warnings': [
            'Packs are named on this phone by visual similarity to pack shots of the Square Food catalogue; '
                'close variants of one design can be confused, and a pack that resembles none of them is reported as not ours.',
          ],
          'error': null, 'model': _model, 'annotated_url': null,
        }
        ..['status'] = 'analysed';
      if (frames != null) {
        for (final f in frames) {
          final file = File('${_dir.path}/images/$f');
          if (file.existsSync()) file.deleteSync();
        }
        c.remove('frame_files');
      }
    } catch (error) {
      c
        ..['status'] = 'failed'
        ..['inference'] = {
          'id': _id(), 'status': 'failed', 'latency_ms': DateTime.now().difference(started).inMilliseconds,
          'cost_usd': 0.0, 'warnings': <String>[], 'error': '$error', 'model': _model, 'annotated_url': null,
        };
    }
    await _save();
  }

  /// Recogniser results as stored detections (vision/pipeline.py run_inference).
  List<Json> _detections(List<Json> looks) {
    final (rows, total) = assignShelfRows(
      [for (final l in looks) ((l['box']['y'] as num) + (l['box']['height'] as num) / 2).toDouble()],
      [for (final l in looks) (l['box']['height'] as num).toDouble()],
    );
    return [
      for (var i = 0; i < looks.length; i++)
        () {
          final look = looks[i];
          final product = _bySku[look['product_id']];
          final label = product == null ? 'competitor' : (product['is_own'] == true ? 'own' : 'competitor');
          final confidence = (look['confidence'] as num).toDouble();
          final named = {'label': label, 'product_id': product?['id'], 'manufacturer_id': product?['manufacturer_id']};
          return {
            'id': _id(),
            'box': look['box'],
            'shelf_row': rows[i],
            'shelf_rows_total': total,
            'predicted': {...named, 'confidence': confidence},
            'final': named,
            'needs_review': label == 'unknown' || confidence < _reviewThreshold,
            'verification': null,
            'evidence': {'method': look['method'], ...?(look['evidence'] as Json?)},
          };
        }(),
    ];
  }

  Future<Json> _review(Json user, String detectionId, Json body) async {
    for (final c in _captures.values.cast<Json>()) {
      for (final d in (c['detections'] as List? ?? const []).cast<Json>()) {
        if (d['id'] != detectionId) continue;
        _visit(user, c['visit_id'] as String);
        final action = body['action'] as String?;
        if (!const {'confirm', 'correct', 'reject'}.contains(action)) {
          throw const _Fail(422, 'action must be one of [confirm, correct, reject]');
        }
        final fin = d['final'] as Json;
        var label = fin['label'], product = fin['product_id'], manufacturer = fin['manufacturer_id'];
        if (action == 'correct') {
          final productId = body['product_id'] as String?;
          final newLabel = body['label'] as String?;
          if (productId != null) {
            final p = _productMap[productId] ?? (throw const _Fail(422, 'Unknown product'));
            product = p['id'];
            manufacturer = p['manufacturer_id'];
            label = _own.contains(manufacturer) ? 'own' : 'competitor';
          } else if (const {'own', 'competitor', 'unknown'}.contains(newLabel)) {
            label = newLabel;
            product = null;
            manufacturer = newLabel == 'own' ? (_own.isEmpty ? null : _own.first) : null;
          } else {
            throw const _Fail(422, 'correct requires product_id or label (own | competitor | unknown)');
          }
        }
        if (action == 'reject') {
          d['verification'] = 'rejected';
        } else {
          final predicted = d['predicted'] as Json;
          final changed = label != predicted['label'] || product != predicted['product_id'];
          d['verification'] = changed ? 'corrected' : 'confirmed';
          d['final'] = {'label': label, 'product_id': product, 'manufacturer_id': manufacturer};
        }
        d['needs_review'] = false;
        await _save();
        return {'correction_id': _id(), ...d};
      }
    }
    throw const _Fail(404, 'Detection not found');
  }

  // --- submit, report and orders -------------------------------------------------------------------

  Future<Json> _submit(Json user, String visitId) async {
    final visit = _visit(user, visitId, write: true);
    if (_visitCaptures(visitId).any((c) => c['status'] == 'uploaded' || c['status'] == 'analysing')) {
      throw const _Fail(409, 'Some photos are still being analysed');
    }
    if (visit['status'] == 'open') {
      visit
        ..['status'] = 'submitted'
        ..['ended_at'] = _now();
    }
    final outletId = visit['outlet_id'] as String;
    final intel = _analyze(outletId, visitId: visitId);
    _autoOrder(visit);
    await _save();
    final report = _report(visit);
    return {'visit': _visitOut(visit), 'intelligence': intel, 'order': report['order'], 'report': report};
  }

  (int, Map<String, int>) _policy(String outletId) {
    final channelId = _channelOf(outletId);
    final channel = _channels[channelId] as Json;
    return shelfPolicy(
      applicableCore(_core, channelId, _outlet(outletId)['class_id'] as String?),
      _rules,
      channel['path'] as String,
      channel['units_per_facing'] as int? ?? 3,
    );
  }

  (List<Json>, ShelfStock?, int) _suggest(String outletId, String? visitId, Set<String> statuses) {
    final record = _outlet(outletId);
    if (visitId == null) {
      // The latest audit of the last week (services/ordering.py latest_shelf_visit).
      final since = DateTime.now().toUtc().subtract(const Duration(days: 7));
      final recent = _visits.values.cast<Json>().where((v) =>
          v['outlet_id'] == outletId && DateTime.parse(v['started_at'] as String).isAfter(since) &&
          _visitCaptures(v['id'] as String).any((c) => c['status'] == 'analysed')).toList()
        ..sort((a, b) => (b['started_at'] as String).compareTo(a['started_at'] as String));
      visitId = recent.firstOrNull?['id'] as String?;
    }
    final stock = visitId == null ? null : _stock(visitId);
    final (unitsPerFacing, targets) = _policy(outletId);
    final lines = suggestOrder(
      history: record['history'] as Json,
      products: _productMap,
      recommendations: _recs(outletId),
      promoted: (record['promoted_product_ids'] as List).cast<String>().toSet(),
      shelf: stock,
      unitsPerFacing: unitsPerFacing,
      targetFacings: targets,
      statuses: statuses,
    );
    return (lines, stock, unitsPerFacing);
  }

  Json _suggestionOut(String outletId, String? visitId) {
    if (visitId != null && (_visits[visitId] as Json?)?['outlet_id'] != outletId) throw const _Fail(404, 'Visit not found');
    final (lines, stock, unitsPerFacing) = _suggest(outletId, visitId, const {'open', 'accepted', 'modified'});
    return {
      'data_origin': _origin,
      'generator_version': _snap['order_generator_version'],
      'lines': [
        for (final l in lines) {...l, 'reasons': [for (final s in (l['sources'] as List).cast<Json>()) explainSource(s)]},
      ],
      'total_value': round2(lines.fold<double>(0, (s, l) => s + (l['quantity'] as int) * (l['unit_price'] as num))),
      'shelf_evidence': stock == null
          ? null
          : {'visit_id': stock.visitId, 'categories_photographed': stock.coveredCategories.length,
              'verified_ratio': stock.verifiedRatio},
      'units_per_facing': unitsPerFacing,
      'note': 'Suggestion only. The officer decides the final order; differences are tracked.',
    };
  }

  Json? _visitOrder(Json visit) {
    final orders = _orders.values.cast<Json>().where((o) =>
        (o['external_ref'] == 'AUTO-${visit['id']}' || o['visit_id'] == visit['id']) && o['status'] != 'cancelled').toList()
      ..sort((a, b) => (a['created_at'] as String).compareTo(b['created_at'] as String));
    return orders.firstOrNull;
  }

  /// services/ordering.py create_auto_order: the order the shelf calls for, confirmed at once.
  void _autoOrder(Json visit) {
    if (_visitOrder(visit) != null || _orders.values.any((o) => o['external_ref'] == 'AUTO-${visit['id']}')) return;
    final outletId = visit['outlet_id'] as String;
    final (lines, stock, unitsPerFacing) = _suggest(outletId, visit['id'] as String, const {'accepted', 'modified'});
    final priced = lines.where((l) => _productMap[l['product_id']]!['trade_price'] != null).toList();
    if (priced.isEmpty) return;
    final id = _id();
    _orders[id] = {
      'id': id, 'outlet_id': outletId, 'visit_id': visit['id'], 'user_id': visit['user_id'], 'source': 'auto',
      'status': 'confirmed', 'external_ref': 'AUTO-${visit['id']}', 'order_date': _today(), 'created_at': _now(),
      'data_origin': _origin,
      'meta': {
        'generator_version': _snap['order_generator_version'], 'mode': 'confirm', 'shelf_visit_id': stock?.visitId,
        'units_per_facing': unitsPerFacing,
        'skipped_without_trade_price': [for (final l in lines) if (!priced.contains(l)) l['sku']],
      },
      'items': [
        for (final l in priced)
          () {
            final price = round2(_productMap[l['product_id']]!['trade_price'] as num);
            final sources = (l['sources'] as List).cast<Json>();
            return {
              'id': _id(), 'product_id': l['product_id'], 'quantity': l['quantity'], 'unit_price': price,
              'line_value': round2(price * (l['quantity'] as int)), 'suggested_quantity': l['quantity'],
              'recommendation_id': sources.where((s) => s['source'] == 'recommendation').firstOrNull?['recommendation_id'],
              'sources': sources,
            };
          }(),
      ],
    };
  }

  static double _orderValue(Json order) =>
      round2((order['items'] as List).cast<Json>().fold<double>(0, (s, i) => s + (i['line_value'] as num)));

  bool _editable(Json order) =>
      const {'app', 'auto'}.contains(order['source']) &&
      const {'draft', 'confirmed'}.contains(order['status']) &&
      DateTime.now().toUtc().difference(DateTime.parse(order['created_at'] as String)) <= _editWindow;

  Json _orderOut(Json order) => {
    'id': order['id'], 'outlet_id': order['outlet_id'], 'visit_id': order['visit_id'], 'user_id': order['user_id'],
    'source': order['source'], 'status': order['status'], 'external_ref': order['external_ref'],
    'order_date': order['order_date'], 'created_at': order['created_at'], 'value': _orderValue(order),
    'lines': [
      for (final item in (order['items'] as List).cast<Json>())
        () {
          final product = _productMap[item['product_id']];
          final sources = (item['sources'] as List? ?? const []).cast<Json>();
          return {
            'id': item['id'], 'product_id': item['product_id'], 'sku': product?['sku'],
            'name': product?['name'] ?? item['product_id'], 'brand': product?['brand_name'],
            'quantity': item['quantity'], 'unit_price': item['unit_price'], 'line_value': item['line_value'],
            'suggested_quantity': item['suggested_quantity'], 'recommendation_id': item['recommendation_id'],
            'sources': sources, 'reasons': [for (final s in sources) explainSource(s)],
          };
        }(),
    ],
    'meta': order['meta'] ?? const {}, 'editable': _editable(order), 'data_origin': order['data_origin'],
  };

  Json _order(Json user, String orderId) {
    final order = _orders[orderId] as Json?;
    if (order == null) throw const _Fail(404, 'Order not found');
    _scoped(user, order['outlet_id'] as String);
    return order;
  }

  void _editableOr409(Json user, Json order) {
    if (_officer(user) && order['user_id'] != user['id']) {
      throw const _Fail(403, 'Only the officer who placed the order can change it');
    }
    if (!_editable(order)) {
      throw _Fail(409, 'Order can no longer be changed (${order['source']}, ${order['status']}, edit window 24 h)');
    }
  }

  List<Json> _items(String outletId, List<Json> lines, [Map<String, Json> previous = const {}]) {
    final seen = <String>{};
    final recIds = {for (final r in _recs(outletId)) r['id']};
    return [
      for (final line in lines)
        () {
          final productId = line['product_id'] as String;
          if (!seen.add(productId)) throw _Fail(422, 'Product $productId appears twice');
          final product = _productMap[productId];
          if (product == null || product['is_own'] != true || product['is_active'] != true) {
            throw _Fail(422, 'Product $productId cannot be ordered');
          }
          if (line['recommendation_id'] != null && !recIds.contains(line['recommendation_id'])) {
            throw const _Fail(422, 'Recommendation does not belong to this outlet');
          }
          if (product['trade_price'] == null) throw _Fail(422, 'No trade price configured for ${product['sku']}');
          final quantity = line['quantity'] as int;
          if (quantity < 1) throw const _Fail(422, 'Quantity must be at least 1');
          final before = previous[productId];
          final price = round2((before?['unit_price'] ?? product['trade_price']) as num);
          return {
            'id': _id(), 'product_id': productId, 'quantity': quantity, 'unit_price': price,
            'line_value': round2(price * quantity),
            'suggested_quantity': before != null ? before['suggested_quantity'] : line['suggested_quantity'],
            'recommendation_id': before?['recommendation_id'] ?? line['recommendation_id'],
            'sources': before != null ? before['sources'] : (line['sources'] ?? const []),
          };
        }(),
    ];
  }

  Future<_Response> _createOrder(Json user, String outletId, Json body) async {
    final ref = 'APP-${body['client_order_id']}';
    for (final o in _orders.values.cast<Json>()) {
      if (o['external_ref'] == ref) return _Response(201, {'id': o['id'], 'status': o['status'], 'replayed': true});
    }
    final visitId = body['visit_id'] as String?;
    if (visitId != null && (_visits[visitId] as Json?)?['outlet_id'] != outletId) {
      throw const _Fail(422, 'Visit does not belong to this outlet');
    }
    final lines = (body['lines'] as List? ?? const []).cast<Json>();
    if (lines.isEmpty) throw const _Fail(422, 'Add at least one product');
    final id = _id();
    final order = {
      'id': id, 'outlet_id': outletId, 'visit_id': visitId, 'user_id': user['id'], 'source': 'app',
      'status': 'confirmed', 'external_ref': ref, 'order_date': _today(), 'created_at': _now(), 'data_origin': _origin,
      'meta': {'generator_version': null}, 'items': _items(outletId, lines),
    };
    _orders[id] = order;
    await _save();
    return _Response(201, {'id': id, 'status': 'confirmed', 'replayed': false, 'value': _orderValue(order)});
  }

  Future<Json> _updateOrder(Json user, String orderId, Json body) async {
    final order = _order(user, orderId);
    _editableOr409(user, order);
    final lines = (body['lines'] as List? ?? const []).cast<Json>();
    if (lines.isEmpty) throw const _Fail(422, 'Add at least one product');
    final previous = {for (final i in (order['items'] as List).cast<Json>()) i['product_id'] as String: i};
    order
      ..['items'] = _items(order['outlet_id'] as String, lines, previous)
      ..['meta'] = {...(order['meta'] as Json? ?? const {}), 'edited': true, 'edit_note': body['note']};
    await _save();
    return _orderOut(order);
  }

  Future<Json> _confirmOrder(Json user, String orderId) async {
    final order = _order(user, orderId);
    if (order['status'] == 'confirmed') return _orderOut(order);
    _editableOr409(user, order);
    order['status'] = 'confirmed';
    await _save();
    return _orderOut(order);
  }

  Future<Json> _cancelOrder(Json user, String orderId, Json body) async {
    final order = _order(user, orderId);
    if (order['status'] == 'cancelled') return _orderOut(order);
    _editableOr409(user, order);
    final reason = '${body['reason'] ?? ''}';
    if (reason.trim().length < 3) throw const _Fail(422, 'Give a reason');
    order
      ..['status'] = 'cancelled'
      ..['meta'] = {...(order['meta'] as Json? ?? const {}), 'cancel_reason': reason, 'cancelled_by': user['id']};
    await _save();
    return _orderOut(order);
  }

  /// services/reports.py build_visit_report.
  Json _report(Json visit) {
    final visitId = visit['id'] as String, outletId = visit['outlet_id'] as String;
    final record = _outlet(outletId);
    final officer = (_snap['users'] as Json).values.cast<Json>().map((e) => e['user'] as Json)
        .where((u) => u['id'] == visit['user_id']).firstOrNull;
    Json? channel(String? id) {
      final c = _channels[id] as Json?;
      return c == null ? null : {'id': c['id'], 'code': c['code'], 'name': c['name'], 'name_bn': c['name_bn'], 'icon': c['icon']};
    }

    final categoryNames = (_snap['category_names'] as Json).cast<String, String>();
    final captures = _visitCaptures(visitId);
    final warnings = <String>{
      for (final c in captures) ...((c['quality']?['warnings'] as List?) ?? const []).cast<String>(),
      for (final c in captures) ...((c['inference']?['warnings'] as List?) ?? const []).cast<String>(),
    };
    final analysed = captures.where((c) => c['inference']?['status'] == 'succeeded');
    final photos = {
      'total': captures.length,
      'analysed': captures.where((c) => c['status'] == 'analysed').length,
      'failed': captures.where((c) => c['status'] == 'failed').length,
      'duplicates': captures.where((c) => c['duplicate_of'] != null).length,
      'items': [
        for (final c in captures)
          {'id': c['id'], 'status': c['status'], 'category': categoryNames[c['category_id']],
              'image_url': '/v2/captures/${c['id']}/image', 'annotated_url': null},
      ],
      'models': [if (analysed.isNotEmpty) {'provider': _model['provider'], 'version': _model['version']}],
      'cost_usd': 0.0,
    };

    final facings = _facings(visitId);
    final all = summarize(facings, _own, 'all'), verified = summarize(facings, _own, 'verified');
    final headline = all.totalFacings > 0 && verified.totalFacings > 0 && all.verifiedRatio >= .8 ? verified : all;
    final live = facings.where((f) => f.label != 'rejected' && (headline.basis == 'all' || f.verified)).toList();
    final total = live.length;
    final byBrand = <String, int>{};
    final byCategory = <String, Map<String, int>>{};
    for (final f in live) {
      final product = _productMap[f.productId];
      if (product != null) byBrand[product['brand_id'] as String] = (byBrand[product['brand_id']] ?? 0) + 1;
      final side = f.label == 'own' || f.label == 'competitor' ? f.label : 'unknown';
      final counts = byCategory.putIfAbsent(f.categoryId ?? '', () => {'own': 0, 'competitor': 0, 'unknown': 0});
      counts[side] = counts[side]! + 1;
    }
    double? share(int count) => total == 0 ? null : round4(count / total);
    final shelf = {
      'basis': headline.basis,
      'all': all.toJson(),
      'verified': verified.toJson(),
      'share_of_shelf': headline.shareOfShelf,
      'range': headline.range,
      'total_facings': headline.totalFacings,
      'own_facings': headline.ownFacings,
      'competitor_facings': headline.competitorFacings,
      'unknown_facings': headline.unknownFacings,
      'verified_ratio': all.verifiedRatio,
      'model_versions': facings.isEmpty ? <String>[] : [_model['version_id']],
      'by_manufacturer': [
        for (final e in headline.facingsByManufacturer.entries)
          {'id': e.key, 'name': _manufacturers[e.key]?['name'] ?? e.key, 'is_own': _manufacturers[e.key]?['is_own'] ?? false,
              'facings': e.value, 'share': share(e.value)},
      ]..sort((a, b) => (b['facings'] as int).compareTo(a['facings'] as int)),
      'by_brand': [
        for (final e in byBrand.entries)
          if (_brands.containsKey(e.key))
            () {
              final maker = _manufacturers[_brands[e.key]!['manufacturer_id']];
              return {'id': e.key, 'name': _brands[e.key]!['name'], 'manufacturer': maker?['name'],
                  'is_own': maker?['is_own'] ?? false, 'facings': e.value, 'share': share(e.value)};
            }(),
      ]..sort((a, b) => (b['facings'] as int).compareTo(a['facings'] as int)),
      'by_product': [
        for (final e in headline.facingsByProduct.entries)
          if (_productMap.containsKey(e.key))
            () {
              final p = _productMap[e.key]!;
              return {'id': e.key, 'sku': p['sku'], 'name': p['name'], 'brand': p['brand_name'],
                  'manufacturer': p['manufacturer_name'], 'is_own': p['is_own'], 'category': p['category_name'],
                  'facings': e.value, 'share': share(e.value)};
            }(),
      ]..sort((a, b) {
        final own = (a['is_own'] == true ? 0 : 1).compareTo(b['is_own'] == true ? 0 : 1);
        return own != 0 ? own : (b['facings'] as int).compareTo(a['facings'] as int);
      }),
      'by_category': [
        for (final e in byCategory.entries)
          () {
            final sum = e.value.values.fold<int>(0, (a, b) => a + b);
            return {'id': e.key.isEmpty ? null : e.key, 'name': categoryNames[e.key] ?? 'Mixed / not identified',
                ...e.value, 'total': sum, 'own_share': sum == 0 ? null : round4(e.value['own']! / sum)};
          }(),
      ]..sort((a, b) => (b['total'] as int).compareTo(a['total'] as int)),
    };

    final channelId = _channelOf(outletId);
    final stock = _stock(visitId);
    final core = applicableCore(_core, channelId, record['class_id'] as String?);
    final placement = facings.isEmpty
        ? <Json>[]
        : evaluatePlacement(_rules, facings, (_channels[channelId] as Json)['path'] as String, _brandOf, _own, _descendants);
    final recs = _sortRecs([
      for (final r in _recs(outletId))
        if (r['visit_id'] == visitId && const {'open', 'accepted', 'modified'}.contains(r['status'])) r,
    ]);
    final order = _visitOrder(visit) ??
        _orders.values.cast<Json>().where((o) => o['external_ref'] == 'AUTO-$visitId').firstOrNull;
    final classification = record['classification'] as Json?;
    final report = {
      'data_origin': visit['data_origin'],
      'generated_at': _now(),
      'visit': {
        'id': visitId, 'status': visit['status'], 'started_at': visit['started_at'], 'ended_at': visit['ended_at'],
        'distance_from_outlet_m': visit['distance_from_outlet_m'],
        'officer': officer == null ? null : {'id': officer['id'], 'name': officer['name'], 'employee_id': officer['employee_id']},
      },
      'outlet': {
        'id': outletId, 'code': record['code'], 'name': record['summary']['name'], 'address': record['address'],
        'is_verified': record['is_verified'],
        'class': classification == null ? null : {'code': classification['code'], 'label': classification['label']},
      },
      'store_type': channel(visit['store_type_id'] as String? ?? channelId),
      'previous_store_type': channel(visit['previous_store_type_id'] as String?),
      'photos': photos,
      'shelf': shelf,
      'availability': [
        for (final a in coreAvailability(core, _productMap, stock))
          {...a, 'product': {'id': a['product_id'], 'sku': _productMap[a['product_id']]!['sku'],
              'name': _productMap[a['product_id']]!['name']}},
      ],
      'placement': {'score': complianceScore(placement), 'rule_set': _snap['placement_rule_set'], 'results': placement},
      'recommendations': recs,
      'order': order == null ? null : _orderOut(order),
      'warnings': warnings.toList()..sort(),
    };
    report['summary_text'] = reportSummaryText(report);
    return report;
  }

  // --- dashboards (api/analytics.py) ---------------------------------------------------------------

  List<String> _activeScope(Json user) => _scope(user);

  (String, String) _groupOf(String outletId, String groupBy) {
    if (groupBy == 'channel') {
      final channel = _channels[_channelOf(outletId)] as Json;
      return (channel['id'] as String, channel['name'] as String);
    }
    final groups = (_outlet(outletId)['analytics'] as Json)['groups'] as Json;
    final key = (groups[groupBy] ?? groups['outlet']) as List;
    return (key[0] as String, key[1] as String);
  }

  Json _overview(Json user, String groupBy) {
    const groupsAllowed = {'territory', 'channel', 'distributor', 'officer', 'outlet'};
    if (!groupsAllowed.contains(groupBy)) throw const _Fail(422, 'Unknown group_by');
    const months = 90 / 30.44;
    final since90 = DateTime.now().toUtc().subtract(const Duration(days: 90));
    final since30 = DateTime.now().toUtc().subtract(const Duration(days: 30));
    final groups = <String, Json>{};
    for (final id in _activeScope(user)) {
      final record = _outlet(id);
      final facts = record['analytics'] as Json;
      final (groupId, label) = _groupOf(id, groupBy);
      final g = groups.putIfAbsent(groupId, () => {
        'id': groupId, 'label': label, 'outlets': 0, 'monthly_value_bdt': 0.0, 'visited_30d': 0, 'audited': 0,
        'own_facings': 0.0, 'total_facings': 0.0, 'open_recommendations': 0, 'opportunity_bdt_per_month': 0.0,
        '_scores': <String, List<double>>{},
      });
      final local = _orders.values.cast<Json>().where((o) =>
          o['outlet_id'] == id && o['status'] == 'confirmed' && DateTime.parse(o['created_at'] as String).isAfter(since90));
      g['outlets'] = (g['outlets'] as int) + 1;
      g['monthly_value_bdt'] = (g['monthly_value_bdt'] as double) + (facts['monthly_value_bdt'] as num).toDouble() +
          local.fold<double>(0, (s, o) => s + _orderValue(o)) / months;
      if (_visits.values.any((v) => v['outlet_id'] == id && DateTime.parse(v['started_at'] as String).isAfter(since30))) {
        g['visited_30d'] = (g['visited_30d'] as int) + 1;
      }
      final visit = _latestShelfVisit(id);
      if (visit != null) {
        final s = summarize(_facings(visit['id'] as String), _own, 'all');
        g['audited'] = (g['audited'] as int) + 1;
        g['own_facings'] = (g['own_facings'] as double) + s.ownFacings;
        g['total_facings'] = (g['total_facings'] as double) + s.totalFacings;
      }
      g['open_recommendations'] = (g['open_recommendations'] as int) + _recs(id).where((r) => r['status'] == 'open').length;
      final scores = ((_state['intel'] as Json)[id]?['scores'] ?? facts['scores']) as Json;
      for (final e in scores.entries) {
        if (e.value != null) (g['_scores'] as Map<String, List<double>>).putIfAbsent(e.key, () => []).add((e.value as num).toDouble());
      }
    }
    final rows = <Json>[];
    for (final g in groups.values) {
      final dims = g.remove('_scores') as Map<String, List<double>>;
      final opportunity = dims.remove('opportunity') ?? const [];
      final total = g['total_facings'] as double;
      g
        ..['opportunity_bdt_per_month'] = round2(opportunity.fold<double>(0, (a, b) => a + b))
        ..['scores'] = {
          for (final e in dims.entries)
            e.key: {'mean': (10 * e.value.reduce((a, b) => a + b) / e.value.length).round() / 10, 'outlets_scored': e.value.length},
        }
        ..['share_of_shelf'] = total > 0 ? round4((g['own_facings'] as double) / total) : null
        ..['monthly_value_bdt'] = round2(g['monthly_value_bdt'] as double)
        ..['coverage_30d'] = (g['outlets'] as int) > 0 ? ((g['visited_30d'] as int) / (g['outlets'] as int) * 1000).round() / 1000 : 0.0;
      rows.add(g);
    }
    rows.sort((a, b) => (b['monthly_value_bdt'] as double).compareTo(a['monthly_value_bdt'] as double));
    return {
      'data_origin': _origin, 'group_by': groupBy, 'window_days': 90,
      'notes': {
        'share_of_shelf': 'facings-weighted, latest audit per outlet, all detections (see /competition for basis)',
        'scores': 'mean of latest per-outlet dimension scores; outlets without data are excluded, not zeroed',
      },
      'groups': rows,
    };
  }

  Json _competition(Json user, String groupBy, String basis) {
    final ids = _activeScope(user);
    final groups = <String, Json>{};
    var audited = 0;
    for (final id in ids) {
      final visit = _latestShelfVisit(id, basis: basis);
      if (visit == null) continue;
      audited++;
      final s = summarize(_facings(visit['id'] as String), _own, basis);
      final (groupId, label) = _groupOf(id, groupBy);
      final g = groups.putIfAbsent(groupId, () => {
        'id': groupId, 'label': label, 'outlets_audited': 0, 'total_facings': 0.0, 'own_facings': 0.0,
        '_by': <String, double>{},
      });
      g['outlets_audited'] = (g['outlets_audited'] as int) + 1;
      g['total_facings'] = (g['total_facings'] as double) + s.totalFacings;
      g['own_facings'] = (g['own_facings'] as double) + s.ownFacings;
      final by = g['_by'] as Map<String, double>;
      s.facingsByManufacturer.forEach((m, n) => by[m] = (by[m] ?? 0) + n);
    }
    final rows = <Json>[];
    for (final g in groups.values) {
      final by = g.remove('_by') as Map<String, double>;
      final total = g['total_facings'] as double;
      final identified = by.values.fold<double>(0, (a, b) => a + b);
      g
        ..['share_of_shelf_own'] = total > 0 ? round4((g['own_facings'] as double) / total) : null
        ..['unidentified_share'] = total > 0 ? round4(1 - identified / total) : null
        ..['manufacturers'] = ([
          for (final e in by.entries)
            {'id': e.key, 'name': _manufacturers[e.key]?['name'] ?? e.key, 'is_own': _manufacturers[e.key]?['is_own'] ?? false,
                'facings': e.value, 'share_of_shelf': round4(e.value / total)},
        ]..sort((a, b) => (b['facings'] as double).compareTo(a['facings'] as double)));
      rows.add(g);
    }
    rows.sort((a, b) => (b['total_facings'] as double).compareTo(a['total_facings'] as double));
    return {
      'data_origin': _origin, 'basis': basis, 'group_by': groupBy, 'outlets_in_scope': ids.length,
      'outlets_audited': audited,
      'caveat': "Competitor shares are only as good as recognition; 'unidentified_share' is facings with no manufacturer.",
      'groups': rows,
    };
  }

  // --- images --------------------------------------------------------------------------------------

  static Future<Json> _inspectImage(Uint8List bytes) async =>
      (await RgbaImage.decode(bytes, maxSide: 1280)).quality();

  /// Sphere frames placed side by side at one height (the server's fallback when frames
  /// cannot be stitched), as a PNG made with the phone's own image engine.
  static Future<Panorama> _sideBySide(List<Uint8List> frames) async {
    const side = 800;
    final small = <ui.Image>[];
    for (final bytes in frames) {
      final codec = await ui.instantiateImageCodec(bytes);
      final full = (await codec.getNextFrame()).image;
      final scale = math.min(1.0, side / math.max(full.width, full.height));
      final w = (full.width * scale).round(), h = (full.height * scale).round();
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawImageRect(
        full,
        ui.Rect.fromLTWH(0, 0, full.width.toDouble(), full.height.toDouble()),
        ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      small.add(await recorder.endRecording().toImage(w, h));
      full.dispose();
      codec.dispose();
    }
    final height = small.map((i) => i.height).reduce(math.min);
    final widths = [for (final i in small) (i.width * height / i.height).round()];
    final total = widths.reduce((a, b) => a + b);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final placement = <(double, double)>[];
    var left = 0;
    for (var i = 0; i < small.length; i++) {
      canvas.drawImageRect(
        small[i],
        ui.Rect.fromLTWH(0, 0, small[i].width.toDouble(), small[i].height.toDouble()),
        ui.Rect.fromLTWH(left.toDouble(), 0, widths[i].toDouble(), height.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      placement.add((left / total, widths[i] / total));
      left += widths[i];
    }
    final image = await recorder.endRecording().toImage(total, height);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    for (final i in small) {
      i.dispose();
    }
    return Panorama(png!.buffer.asUint8List(), 'image/png', placement, total, height);
  }
}
