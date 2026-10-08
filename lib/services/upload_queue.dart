import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'platform_api.dart';

enum UploadState { queued, uploading, uploaded, rejected }

/// One photo waiting to reach the server. Persisted, so it survives app restarts.
class QueuedCapture {
  QueuedCapture({
    required this.clientCaptureId,
    required this.visitId,
    required this.filePath,
    required this.capturedAt,
    this.area,
    this.categoryId,
    this.state = UploadState.queued,
    this.attempts = 0,
    this.captureId,
    this.error,
    this.duplicateOf,
    this.qualityWarnings = const [],
  });

  final String clientCaptureId;
  final String visitId;
  final String filePath;
  final DateTime capturedAt;
  final String? area;
  final String? categoryId;
  UploadState state;
  int attempts;
  String? captureId;
  String? error;
  String? duplicateOf;
  List<String> qualityWarnings;

  Map<String, dynamic> toJson() => {
    'client_capture_id': clientCaptureId,
    'visit_id': visitId,
    'file_path': filePath,
    'captured_at': capturedAt.toIso8601String(),
    'area': area,
    'category_id': categoryId,
    'state': state.name,
    'attempts': attempts,
    'capture_id': captureId,
    'error': error,
    'duplicate_of': duplicateOf,
    'quality_warnings': qualityWarnings,
  };

  factory QueuedCapture.fromJson(Map<String, dynamic> json) => QueuedCapture(
    clientCaptureId: json['client_capture_id'] as String,
    visitId: json['visit_id'] as String,
    filePath: json['file_path'] as String,
    capturedAt: DateTime.parse(json['captured_at'] as String),
    area: json['area'] as String?,
    categoryId: json['category_id'] as String?,
    // An upload interrupted by app death is simply queued again: the server
    // deduplicates by client_capture_id.
    state: switch (json['state']) {
      'uploaded' => UploadState.uploaded,
      'rejected' => UploadState.rejected,
      _ => UploadState.queued,
    },
    attempts: json['attempts'] as int? ?? 0,
    captureId: json['capture_id'] as String?,
    error: json['error'] as String?,
    duplicateOf: json['duplicate_of'] as String?,
    qualityWarnings: (json['quality_warnings'] as List? ?? const []).cast<String>(),
  );
}

/// Offline-first upload queue for shelf photos.
///
/// Photos are copied into app storage and recorded in a JSON file before any
/// network call. Uploads are retried with backoff until the server accepts
/// them; ids generated on the device make every retry idempotent.
class UploadQueue extends ChangeNotifier {
  UploadQueue._();
  static final UploadQueue instance = UploadQueue._();

  final List<QueuedCapture> _items = [];
  Directory? _dir;
  Timer? _retryTimer;
  Future<void>? _active;
  bool _draining = false;
  bool _loaded = false;
  bool _storageUnavailable = false;

  List<QueuedCapture> get items => List.unmodifiable(_items);
  List<QueuedCapture> forVisit(String visitId) =>
      _items.where((item) => item.visitId == visitId).toList();
  int get pendingCount => _items
      .where((i) => i.state == UploadState.queued || i.state == UploadState.uploading)
      .length;

  /// Tests point the queue at a temporary folder and start from a clean state.
  @visibleForTesting
  void resetForTest(Directory directory) {
    _retryTimer?.cancel();
    _active = null;
    _items.clear();
    _dir = directory;
    _loaded = false;
    _draining = false;
    _storageUnavailable = false;
  }

  Future<Directory> _directory() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/upload_queue');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return _dir = dir;
  }

  Future<File> _indexFile() async => File('${(await _directory()).path}/queue.json');

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _indexFile();
      if (file.existsSync()) {
        final rows = jsonDecode(await file.readAsString()) as List;
        _items.addAll(
          rows
              .map((row) => QueuedCapture.fromJson(row as Map<String, dynamic>))
              .where((item) => File(item.filePath).existsSync() || item.state != UploadState.queued),
        );
      }
    } on FormatException {
      // A corrupt index must not block the app; photos on disk are untouched.
    } on FileSystemException {
      // Same: start with an empty queue.
    } on MissingPluginException {
      // No app storage on this platform (e.g. widget tests): the queue stays empty.
      _storageUnavailable = true;
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final file = await _indexFile();
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(_items.map((i) => i.toJson()).toList()));
    await tmp.rename(file.path);
  }

  /// Copies the photo into app storage and queues it. Returns immediately.
  Future<QueuedCapture> enqueue({
    required String visitId,
    required String sourcePath,
    String? area,
    String? categoryId,
  }) async {
    await load();
    final id = newClientId();
    final extension = sourcePath.contains('.') ? sourcePath.split('.').last.toLowerCase() : 'jpg';
    final target = '${(await _directory()).path}/$id.$extension';
    await File(sourcePath).copy(target);
    final item = QueuedCapture(
      clientCaptureId: id,
      visitId: visitId,
      filePath: target,
      capturedAt: DateTime.now(),
      area: area,
      categoryId: categoryId,
    );
    _items.add(item);
    await _save();
    notifyListeners();
    unawaited(drain());
    return item;
  }

  /// Uploads everything that is waiting. Safe to call at any time: concurrent
  /// callers share the run already in flight and complete when it does.
  Future<void> drain() => _active ??= _drain().whenComplete(() => _active = null);

  Future<void> _drain() async {
    await load();
    if (_storageUnavailable || _draining || !PlatformApi.instance.signedIn) return;
    _draining = true;
    var retryLater = false;
    try {
      for (final item in _items.where((i) => i.state == UploadState.queued).toList()) {
        item.state = UploadState.uploading;
        item.attempts++;
        notifyListeners();
        try {
          final result = await PlatformApi.instance.uploadCapture(
            visitId: item.visitId,
            filePath: item.filePath,
            clientCaptureId: item.clientCaptureId,
            area: item.area,
            categoryId: item.categoryId,
            capturedAt: item.capturedAt,
          );
          item
            ..state = UploadState.uploaded
            ..captureId = result['id'] as String
            ..duplicateOf = result['duplicate_of'] as String?
            ..qualityWarnings =
                ((result['quality'] as Map?)?['warnings'] as List? ?? const []).cast<String>()
            ..error = null;
        } on ApiException catch (error) {
          if (error.retryable || error.statusCode == 401) {
            item
              ..state = UploadState.queued
              ..error = error.message;
            retryLater = true;
          } else {
            // The server refused this photo (bad image, visit closed): do not retry.
            item
              ..state = UploadState.rejected
              ..error = error.message;
          }
        } on FileSystemException {
          item
            ..state = UploadState.rejected
            ..error = 'Photo file is missing on this device.';
        }
        await _save();
        notifyListeners();
        if (retryLater) break; // connection is down: stop and back off
      }
    } finally {
      _draining = false;
    }
    _retryTimer?.cancel();
    if (retryLater) {
      final attempts = _items
          .where((i) => i.state == UploadState.queued)
          .fold<int>(1, (max, i) => i.attempts > max ? i.attempts : max);
      final seconds = (5 * (1 << (attempts - 1).clamp(0, 6))).clamp(5, 300);
      _retryTimer = Timer(Duration(seconds: seconds), drain);
    }
  }

  /// Removes finished entries for a visit and deletes their local copies.
  Future<void> clearVisit(String visitId) async {
    final done = _items
        .where((i) => i.visitId == visitId && i.state != UploadState.queued && i.state != UploadState.uploading)
        .toList();
    for (final item in done) {
      final file = File(item.filePath);
      if (file.existsSync()) file.deleteSync();
      _items.remove(item);
    }
    await _save();
    notifyListeners();
  }

  /// Drops a photo the server rejected (or the officer no longer wants).
  Future<void> remove(QueuedCapture item) async {
    final file = File(item.filePath);
    if (file.existsSync()) file.deleteSync();
    _items.remove(item);
    await _save();
    notifyListeners();
  }
}
