import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'debug_log.dart';

/// Shelf recognition on the phone, with no server: the same steps as the server's visual
/// lookup, on phone-sized models bundled in assets/recognition/ (see
/// tools/build_on_device_models.py):
///
///   find    a SKU-110K YOLO11n detector boxes every product on the shelf;
///   name    each box is fingerprinted with a MobileCLIP image encoder and compared with the
///           fingerprints of the Square Food pack shots (computed on the laptop and bundled);
///           the best product must look alike and share the pack shot's colours;
///   read    the same fingerprint is compared with brand names written on packs, so a
///           competitor that prints its name is named;
///
/// No training: every model is used as published. Results use the shape of the server's
/// /v2/live/detect response, so screens can use either.
class OnDeviceRecognizer {
  OnDeviceRecognizer._();
  static final OnDeviceRecognizer instance = OnDeviceRecognizer._();

  OrtSession? _detector;
  OrtSession? _embedder;
  late RecognitionCatalog _catalog;
  Future<void>? _loading;

  bool get loaded => _detector != null;

  /// The error from the last failed load, if any.
  Object? loadError;

  /// A failed load is logged and retried on the next call instead of failing forever.
  Future<void> load() => _loading ??= _load().catchError((Object e, StackTrace st) {
        loadError = e;
        _loading = null;
        RecognitionLog.error('model load', e, st);
        throw e;
      });

  Future<void> _load() async {
    final watch = Stopwatch()..start();
    RecognitionLog.log('load: start');
    final ort = OnnxRuntime();
    try {
      RecognitionLog.log('load: ORT platform ${await ort.getPlatformVersion()}');
    } catch (e) {
      RecognitionLog.log('load: ORT platform version unavailable ($e)');
    }
    final catalogText = await rootBundle.loadString('assets/recognition/catalog.json');
    RecognitionLog.log('load: catalog.json ${catalogText.length} chars (${watch.elapsedMilliseconds} ms)');
    _catalog = RecognitionCatalog.fromJson(jsonDecode(catalogText) as Map<String, dynamic>);
    final c = _catalog;
    RecognitionLog.log('load: catalog ${c.products.length} products, ${c.viewProduct.length} views, '
        'dim ${c.dim}, input ${c.size}px, detector "${c.detectorName}", embedder "${c.embedderName}"');
    RecognitionLog.log('load: thresholds clean box=${c.clean.box} accept=${c.clean.accept} other=${c.clean.other} | '
        'screen box=${c.screen.box} accept=${c.screen.accept} other=${c.screen.other}');
    // XNNPACK (optimised ARM kernels) where available, plain CPU otherwise.
    final options = OrtSessionOptions(intraOpNumThreads: 4, providers: [OrtProvider.XNNPACK, OrtProvider.CPU]);
    Future<OrtSession> open(String asset) async {
      final t = Stopwatch()..start();
      RecognitionLog.log('load: opening $asset');
      OrtSession session;
      try {
        session = await ort.createSessionFromAsset(asset, options: options);
      } catch (e, st) {
        RecognitionLog.error('open $asset with XNNPACK+CPU', e, st);
        RecognitionLog.log('load: retrying $asset with CPU only');
        session = await ort.createSessionFromAsset(asset,
            options: OrtSessionOptions(intraOpNumThreads: 4, providers: [OrtProvider.CPU]));
      }
      RecognitionLog.log('load: $asset ready in ${t.elapsedMilliseconds} ms, '
          'inputs ${session.inputNames}, outputs ${session.outputNames}');
      try {
        RecognitionLog.log('load:   input info ${await session.getInputInfo()}');
        RecognitionLog.log('load:   output info ${await session.getOutputInfo()}');
      } catch (e) {
        RecognitionLog.log('load:   tensor info unavailable ($e)');
      }
      return session;
    }

    _detector = await open('assets/recognition/detector.onnx');
    _embedder = await open('assets/recognition/embedder.onnx');
    loadError = null;
    RecognitionLog.log('load: done in ${watch.elapsedMilliseconds} ms');
  }


  /// Whether shelf photos are taken of a screen (the demo shows shelf images on a monitor):
  /// moire is smoothed and the screen-photo thresholds apply. One setting for every camera.
  static final ValueNotifier<bool> screenPhotos = ValueNotifier(true);

  /// Recognises the products in one photo (JPEG or PNG bytes). [maxPacks] keeps only the
  /// largest packs, so live frames stay quick; saved photos look at every pack.
  /// [allowedSkus] limits naming to these products, as the server does for a photo tagged
  /// with a category: a pack is named among that category's products or reported as other.
  Future<Map<String, dynamic>> recognize(
    Uint8List bytes, {
    bool screenPhoto = false,
    int? maxPacks,
    Set<String>? allowedSkus,
  }) async {
    final call = ++_calls;
    RecognitionLog.log('#$call recognize: ${bytes.length} bytes, screenPhoto=$screenPhoto, maxPacks=$maxPacks, '
        'allowedSkus=${allowedSkus?.length ?? 'all'}');
    try {
      return await _recognize(call, bytes, screenPhoto: screenPhoto, maxPacks: maxPacks, allowedSkus: allowedSkus);
    } catch (e, st) {
      RecognitionLog.error('#$call recognize', e, st);
      rethrow;
    }
  }

  int _calls = 0;

  Future<Map<String, dynamic>> _recognize(
    int call,
    Uint8List bytes, {
    required bool screenPhoto,
    int? maxPacks,
    Set<String>? allowedSkus,
  }) async {
    await load();
    final started = DateTime.now();
    final stage = Stopwatch()..start();
    void step(String what) {
      RecognitionLog.log('#$call $what (${stage.elapsedMilliseconds} ms)');
      stage.reset();
    }

    final c = _catalog;
    final allowed = allowedSkus == null
        ? null
        : {for (var i = 0; i < c.products.length; i++) if (allowedSkus.contains(c.products[i].sku)) i};
    final t = screenPhoto ? c.screen : c.clean;
    final refs = screenPhoto ? c.screenReferences : c.cleanReferences;
    final image = await RgbaImage.decode(bytes, maxSide: 1280);
    step('decoded ${image.sourceWidth}x${image.sourceHeight} -> ${image.width}x${image.height}');
    image.stretchColours();
    if (t.demoire) image.removeMoire();
    step('preprocessed (demoire=${t.demoire})');
    var boxes = await _detect(image, t.box, call);
    step('detector: ${boxes.length} boxes after suppression (min score ${t.box})');
    if (maxPacks != null && boxes.length > maxPacks) {
      boxes = (boxes.toList()..sort((a, b) => b.area.compareTo(a.area))).sublist(0, maxPacks);
    }
    final crops = [for (final b in boxes) image.crop(b.x0, b.y0, b.x1, b.y1)];
    final features = await _embed(crops);
    step('embedder: ${features.length} fingerprints');
    var dropped = 0;
    final looks = <Map<String, dynamic>>[];
    for (var i = 0; i < boxes.length; i++) {
      final f = features[i];
      // 1. Pack shots: best view per product, and its colours.
      final best = <int, double>{};
      for (var v = 0; v < c.viewProduct.length; v++) {
        final s = _dot(f, c.viewEmbeddings, v * c.dim, c.dim);
        final p = c.viewProduct[v];
        if (allowed != null && !allowed.contains(p)) continue;
        if (s > (best[p] ?? -2)) best[p] = s;
      }
      final product = best.isEmpty ? null : best.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
      final similarity = product == null ? -1.0 : best[product]!;
      final hist = crops[i].colourHistogram();
      var colour = 0.0;
      for (var v = 0; v < c.viewProduct.length; v++) {
        if (c.viewProduct[v] != product) continue;
        colour = math.max(colour, 1 - bhattacharyya(hist, c.viewColours, v * c.colourSize, c.colourSize));
      }
      // 2. Shelf-pack references: closest known Square pack, closest known other pack, and
      //    whether the nearest references are fragments rather than packs.
      final ref = refs.lookup(f, c.dim);
      if (ref.fragmentVote >= t.fragmentVote) {
        dropped++;
        continue;
      }
      // 3. Brand names printed in Latin script.
      final (brand, brandP) = c.readBrand(f);
      final brandProduct = brand == null ? null : c.brandProduct[brand]!;
      final competitor = brandProduct != null && !c.products[brandProduct].isOwn &&
              (allowed == null || allowed.contains(brandProduct))
          ? brand
          : null;
      final box = boxes[i].normalised(image.width, image.height);
      final score = similarity + t.packWeight * colour + t.referenceWeight * (ref.square - ref.other);
      final ours = _sigmoid((score - t.accept) / .08);
      final evidence = {
        'similarity': _round3(similarity), 'colour': _round3(colour), 'detector': _round3(boxes[i].score),
        'score': _round3(score), 'accept': t.accept, 'reference_square': _round3(ref.square),
        'reference_other': _round3(ref.other), 'fragment_vote': _round3(ref.fragmentVote),
        'brand_read': brand, 'brand_read_probability': _round3(brandP), 'brand_read_competitor': competitor != null,
        'best_product': product == null ? null : c.products[product].sku, 'screen_photo': screenPhoto,
      };
      if (i < 8) {
        RecognitionLog.log('#$call   box $i det=${_round3(boxes[i].score)} '
            'best=${product == null ? '-' : c.products[product].sku} sim=${_round3(similarity)} '
            'col=${_round3(colour)} score=${_round3(score)}/${t.accept} brand=$brand(${_round3(brandP)})');
      }
      if (competitor != null && brandP >= t.brandRead) {
        looks.add(_look(box, c.brandProduct[competitor]!, math.min(.99, brandP), 'brand', evidence));
      } else if (product != null && score >= t.accept) {
        looks.add(_look(box, product, math.min(.99, ours), 'visual', evidence));
      } else if (boxes[i].score >= t.other) {
        looks.add(_look(box, null, math.max(.5, math.min(.95, 1 - ours)), 'visual', {...evidence, 'not_ours': true}));
      }
    }
    RecognitionLog.log('#$call result: ${looks.length} detections '
        '(${looks.where((l) => l['product'] != null).length} named, $dropped dropped as fragments) '
        'in ${DateTime.now().difference(started).inMilliseconds} ms');
    return _response(looks, image, DateTime.now().difference(started).inMilliseconds);
  }

  static double _round3(double v) => (v * 1000).round() / 1000;

  Map<String, dynamic> _look(List<double> box, int? product, double confidence, String method,
      Map<String, dynamic> evidence) => {
    'product': product,
    'evidence': evidence,
    'confidence': double.parse(confidence.toStringAsFixed(3)),
    'method': method,
    'box': {'x': box[0], 'y': box[1], 'width': box[2], 'height': box[3]},
  };

  /// The same shape as the server's live lookup response.
  Map<String, dynamic> _response(List<Map<String, dynamic>> looks, RgbaImage image, int ms) {
    final products = <String, Map<String, dynamic>>{};
    final detections = <Map<String, dynamic>>[];
    for (final look in looks) {
      final index = look['product'] as int?;
      final p = index == null ? null : _catalog.products[index];
      final name = p?.name ?? 'Not Square';
      detections.add({
        'product_id': p?.sku, 'sku': p?.sku, 'name': name, 'brand': p?.brand,
        'manufacturer': p?.manufacturer, 'is_own': p?.isOwn ?? false,
        'confidence': look['confidence'], 'method': look['method'], 'box': look['box'], 'polygon': const [],
        'evidence': look['evidence'],
      });
      final entry = products.putIfAbsent(p?.sku ?? 'other', () => {
        'product_id': p?.sku, 'name': name, 'brand': p?.brand, 'is_own': p?.isOwn ?? false,
        'facings': 0, 'best_confidence': 0.0,
      });
      entry['facings'] = (entry['facings'] as int) + 1;
      entry['best_confidence'] = math.max(entry['best_confidence'] as double, look['confidence'] as double);
    }
    final summary = products.values.toList()
      ..sort((a, b) => (b['facings'] as int).compareTo(a['facings'] as int));
    return {
      'width': image.width, 'height': image.height, 'latency_ms': ms, 'detections': detections,
      'source_width': image.sourceWidth, 'source_height': image.sourceHeight,
      'summary': {
        'facings': detections.length,
        'own_facings': detections.where((d) => d['is_own'] == true).length,
        'products': summary,
      },
      'matcher': 'on-device: ${_catalog.detectorName} + ${_catalog.embedderName}',
      'note': 'Recognised on this phone.',
    };
  }

  Future<List<_Box>> _detect(RgbaImage image, double minScore, int call) async {
    const size = 640;
    final scale = size / math.max(image.width, image.height);
    final w = (image.width * scale).round(), h = (image.height * scale).round();
    final padX = (size - w) ~/ 2, padY = (size - h) ~/ 2;
    final input = Float32List(3 * size * size)..fillRange(0, 3 * size * size, 114 / 255);
    final small = image.resized(w, h); // area average, as the thresholds were tuned with
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final o = (y * w + x) * 4;
        final i = (y + padY) * size + x + padX;
        input[i] = small.pixels[o] / 255;
        input[size * size + i] = small.pixels[o + 1] / 255;
        input[2 * size * size + i] = small.pixels[o + 2] / 255;
      }
    }
    final tensor = await OrtValue.fromList(input, [1, 3, size, size]);
    final outputs = await _detector!.run({'images': tensor});
    final first = outputs.values.first;
    final raw = (await first.asFlattenedList()).cast<num>();
    var maxScore = 0.0, above = 0;
    for (var i = 4; i < raw.length; i += 6) {
      final s = raw[i].toDouble();
      if (s > maxScore) maxScore = s;
      if (s >= minScore) above++;
    }
    RecognitionLog.log('#$call   detector outputs ${outputs.keys.toList()} shape ${first.shape}: '
        '${raw.length} values, max score ${_round3(maxScore)}, $above at or over $minScore');
    await tensor.dispose();
    for (final value in outputs.values) {
      await value.dispose();
    }
    final boxes = <_Box>[];
    for (var i = 0; i + 5 < raw.length; i += 6) {
      final score = raw[i + 4].toDouble();
      if (score < minScore) continue;
      boxes.add(_Box(
        ((raw[i] - padX) / scale).clamp(0, image.width.toDouble()).toDouble(),
        ((raw[i + 1] - padY) / scale).clamp(0, image.height.toDouble()).toDouble(),
        ((raw[i + 2] - padX) / scale).clamp(0, image.width.toDouble()).toDouble(),
        ((raw[i + 3] - padY) / scale).clamp(0, image.height.toDouble()).toDouble(),
        score,
      ));
    }
    return _suppress(boxes, image.width * image.height.toDouble());
  }

  /// One box per pack: drop tiny and frame-filling boxes, and parts inside a better box.
  List<_Box> _suppress(List<_Box> boxes, double frame) {
    boxes.sort((a, b) => b.score.compareTo(a.score));
    final kept = <_Box>[];
    for (final b in boxes) {
      final area = b.area;
      if (area < .002 * frame || area > .85 * frame || b.x1 - b.x0 < 8 || b.y1 - b.y0 < 8) continue;
      final clear = kept.every((k) {
        final inter = math.max(0, math.min(b.x1, k.x1) - math.max(b.x0, k.x0)) *
            math.max(0, math.min(b.y1, k.y1) - math.max(b.y0, k.y0));
        return inter / (area + k.area - inter) <= .3 && inter / math.min(area, k.area) <= .6;
      });
      if (clear) kept.add(b);
    }
    return kept;
  }

  int _embedBatch = 16;

  Future<List<Float32List>> _embed(List<RgbaImage> crops) async {
    final c = _catalog;
    final s = c.size;
    final result = <Float32List>[];
    var start = 0;
    while (start < crops.length) {
      final batch = crops.sublist(start, math.min(crops.length, start + _embedBatch));
      final input = Float32List(batch.length * 3 * s * s);
      for (var n = 0; n < batch.length; n++) {
        batch[n].writeClipInput(input, n * 3 * s * s, s, c.mean, c.std);
      }
      final tensor = await OrtValue.fromList(input, [batch.length, 3, s, s]);
      final outputs = await _embedder!.run({'pixels': tensor});
      final raw = (await outputs.values.first.asFlattenedList()).cast<num>();
      RecognitionLog.log('  embedder batch ${batch.length}: shape ${outputs.values.first.shape}, '
          '${raw.length} values (expected ${batch.length * c.dim})');
      await tensor.dispose();
      for (final value in outputs.values) {
        await value.dispose();
      }
      if (raw.length < batch.length * c.dim) {
        if (batch.length == 1) throw StateError('Embedder returned ${raw.length} values, expected ${c.dim}');
        // Some phones' runtimes return one row for a batch: embed one crop per run from now on.
        RecognitionLog.log('  embedder ignored the batch; falling back to one crop per run');
        _embedBatch = 1;
        continue;
      }
      start += batch.length;
      for (var n = 0; n < batch.length; n++) {
        final f = Float32List(c.dim);
        var norm = 0.0;
        for (var d = 0; d < c.dim; d++) {
          f[d] = raw[n * c.dim + d].toDouble();
          norm += f[d] * f[d];
        }
        norm = math.sqrt(norm);
        for (var d = 0; d < c.dim; d++) {
          f[d] /= norm;
        }
        result.add(f);
      }
    }
    return result;
  }
}

double _dot(Float32List a, Float32List b, int offset, int n) {
  var s = 0.0;
  for (var i = 0; i < n; i++) {
    s += a[i] * b[offset + i];
  }
  return s;
}

/// OpenCV's Bhattacharyya distance for two L1-normalised histograms.
double bhattacharyya(Float32List h, Float32List table, int offset, int n) {
  var s = 0.0;
  for (var i = 0; i < n; i++) {
    s += math.sqrt(h[i] * table[offset + i]);
  }
  return math.sqrt(math.max(0, 1 - s));
}

double _sigmoid(double x) => 1 / (1 + math.exp(-x));

class _Box {
  _Box(this.x0, this.y0, this.x1, this.y1, this.score);
  final double x0, y0, x1, y1, score;
  double get area => (x1 - x0) * (y1 - y0);
  List<double> normalised(int w, int h) => [x0 / w, y0 / h, (x1 - x0) / w, (y1 - y0) / h];
}

/// An RGBA image in memory, decoded with the engine's own (fast, native) decoder.
class RgbaImage {
  RgbaImage(this.pixels, this.width, this.height, {int? sourceWidth, int? sourceHeight})
    : sourceWidth = sourceWidth ?? width,
      sourceHeight = sourceHeight ?? height;
  final Uint8List pixels;
  final int width, height;

  /// Size of the photo before it was scaled down for recognition.
  final int sourceWidth, sourceHeight;

  /// Decodes at full size, then scales down by area averaging (as the thresholds were tuned
  /// with), so the result does not depend on the platform decoder's own resampling.
  static Future<RgbaImage> decode(Uint8List bytes, {required int maxSide}) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final image = (await codec.getNextFrame()).image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final full = RgbaImage(data!.buffer.asUint8List(), image.width, image.height);
    image.dispose();
    final scale = maxSide / math.max(full.width, full.height);
    if (scale >= 1) return full;
    final small = full.resized((full.width * scale).round(), (full.height * scale).round());
    return RgbaImage(small.pixels, small.width, small.height, sourceWidth: full.width, sourceHeight: full.height);
  }

  /// Area-average resize.
  RgbaImage resized(int w, int h) {
    final out = Uint8List(w * h * 4);
    final cellX = width / w, cellY = height / h;
    for (var y = 0; y < h; y++) {
      final ys = (y * cellY).floor(), ye = math.max(ys + 1, ((y + 1) * cellY).floor()).clamp(1, height);
      for (var x = 0; x < w; x++) {
        final xs = (x * cellX).floor(), xe = math.max(xs + 1, ((x + 1) * cellX).floor()).clamp(1, width);
        var r = 0, g = 0, b = 0, n = 0;
        for (var sy = ys; sy < ye; sy++) {
          var o = (sy * width + xs) * 4;
          for (var sx = xs; sx < xe; sx++, o += 4) {
            r += pixels[o];
            g += pixels[o + 1];
            b += pixels[o + 2];
            n++;
          }
        }
        final d = (y * w + x) * 4;
        out[d] = r ~/ n;
        out[d + 1] = g ~/ n;
        out[d + 2] = b ~/ n;
        out[d + 3] = 255;
      }
    }
    return RgbaImage(out, w, h);
  }

  /// Per-channel stretch from the 1st to the 99th percentile: removes a screen's colour cast
  /// and restores contrast (nearly a no-op on a well-exposed photo).
  void stretchColours() {
    final total = width * height;
    // Percentile as NumPy computes it (linear between the two nearest ranks).
    double percentile(List<int> counts, double q) {
      final rank = q * (total - 1);
      int valueAt(int r) {
        var seen = 0;
        for (var v = 0; v < 256; v++) {
          seen += counts[v];
          if (seen > r) return v;
        }
        return 255;
      }

      final lo = valueAt(rank.floor()), hi = valueAt(rank.ceil());
      return lo + (hi - lo) * (rank - rank.floor());
    }

    for (var c = 0; c < 3; c++) {
      final counts = List<int>.filled(256, 0);
      for (var i = c; i < pixels.length; i += 4) {
        counts[pixels[i]]++;
      }
      final low = percentile(counts, .01), high = percentile(counts, .99);
      if (high - low < 20) continue;
      final lut = Uint8List(256);
      for (var v = 0; v < 256; v++) {
        lut[v] = ((v - low) * 255 / (high - low)).clamp(0, 255).floor();
      }
      for (var i = c; i < pixels.length; i += 4) {
        pixels[i] = lut[pixels[i]];
      }
    }
  }

  /// The server's upload checks (ai_service/engine.py _quality): resolution, blur (variance
  /// of the Laplacian) and exposure. Blur is measured on the scaled-down image.
  Map<String, dynamic> quality() {
    final n = width * height;
    final gray = Float32List(n);
    var sum = 0.0;
    for (var i = 0, o = 0; i < n; i++, o += 4) {
      gray[i] = .299 * pixels[o] + .587 * pixels[o + 1] + .114 * pixels[o + 2];
      sum += gray[i];
    }
    var lapSum = 0.0, lapSq = 0.0, count = 0;
    for (var y = 1; y < height - 1; y++) {
      for (var x = 1; x < width - 1; x++) {
        final i = y * width + x;
        final v = gray[i - width] + gray[i + width] + gray[i - 1] + gray[i + 1] - 4 * gray[i];
        lapSum += v;
        lapSq += v * v;
        count++;
      }
    }
    final mean = count == 0 ? 0.0 : lapSum / count;
    final blur = count == 0 ? 0.0 : lapSq / count - mean * mean;
    final brightness = n == 0 ? 0.0 : sum / n;
    final warnings = <String>[
      if (math.min(sourceWidth, sourceHeight) < 720) 'Image resolution is below the recommended 720px minimum.',
      if (blur < 65) 'Image may be blurry.',
      if (brightness < 45) 'Image is too dark.' else if (brightness > 220) 'Image may be overexposed.',
    ];
    return {
      'width': sourceWidth,
      'height': sourceHeight,
      'blur_score': (blur * 100).round() / 100,
      'brightness': (brightness * 100).round() / 100,
      'acceptable': warnings.isEmpty,
      'warnings': warnings,
    };
  }

  /// Moire and pixel-grid smoothing for photos of a screen, as the server does it: in YCrCb,
  /// colour blurred strongly and brightness lightly (OpenCV GaussianBlur, reflect-101 borders).
  void removeMoire() {
    final side = math.max(width, height);
    final chroma = math.max(1.5, side / 600), luma = math.max(.8, side / 1600);
    final n = width * height;
    final y = Float32List(n), cr = Float32List(n), cb = Float32List(n);
    for (var i = 0, o = 0; i < n; i++, o += 4) {
      final r = pixels[o].toDouble(), g = pixels[o + 1].toDouble(), b = pixels[o + 2].toDouble();
      final yy = .299 * r + .587 * g + .114 * b;
      y[i] = yy;
      cr[i] = (r - yy) * .713 + 128;
      cb[i] = (b - yy) * .564 + 128;
    }
    _blur(y, luma);
    _blur(cr, chroma);
    _blur(cb, chroma);
    for (var i = 0, o = 0; i < n; i++, o += 4) {
      final yy = y[i], dr = cr[i] - 128, db = cb[i] - 128;
      pixels[o] = (yy + 1.403 * dr).round().clamp(0, 255);
      pixels[o + 1] = (yy - .714 * dr - .344 * db).round().clamp(0, 255);
      pixels[o + 2] = (yy + 1.773 * db).round().clamp(0, 255);
    }
  }

  void _blur(Float32List channel, double sigma) {
    final radius = math.max(1, (sigma * 3).ceil());
    final kernel = Float32List(2 * radius + 1);
    var sum = 0.0;
    for (var k = -radius; k <= radius; k++) {
      kernel[k + radius] = math.exp(-k * k / (2 * sigma * sigma));
      sum += kernel[k + radius];
    }
    for (var k = 0; k < kernel.length; k++) {
      kernel[k] /= sum;
    }
    int reflect(int i, int n) => i < 0 ? -i : (i >= n ? 2 * n - 2 - i : i);
    final tmp = Float32List(channel.length);
    for (var yy = 0; yy < height; yy++) {
      final row = yy * width;
      for (var x = 0; x < width; x++) {
        var acc = 0.0;
        for (var k = -radius; k <= radius; k++) {
          acc += kernel[k + radius] * channel[row + reflect(x + k, width)];
        }
        tmp[row + x] = acc;
      }
    }
    for (var yy = 0; yy < height; yy++) {
      for (var x = 0; x < width; x++) {
        var acc = 0.0;
        for (var k = -radius; k <= radius; k++) {
          acc += kernel[k + radius] * tmp[reflect(yy + k, height) * width + x];
        }
        channel[yy * width + x] = acc;
      }
    }
  }

  RgbaImage crop(double x0, double y0, double x1, double y1) {
    final left = x0.floor().clamp(0, width - 1), top = y0.floor().clamp(0, height - 1);
    final w = math.max(2, (x1 - left).ceil().clamp(1, width - left)), h = math.max(2, (y1 - top).ceil().clamp(1, height - top));
    final out = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      final sy = math.min(height - 1, top + y);
      final from = (sy * width + left) * 4;
      final len = math.min(w, width - left) * 4;
      out.setRange(y * w * 4, y * w * 4 + len, pixels, from);
    }
    return RgbaImage(out, w, h);
  }

  /// Pads to a white square and resizes (area average) into a CLIP input tensor at [offset].
  void writeClipInput(Float32List out, int offset, int size, List<double> mean, List<double> std) {
    final side = math.max(width, height);
    final left = (side - width) / 2, top = (side - height) / 2;
    final cell = side / size;
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        var r = 0.0, g = 0.0, b = 0.0, n = 0;
        final ys = (y * cell).floor(), ye = math.max(ys + 1, ((y + 1) * cell).floor());
        final xs = (x * cell).floor(), xe = math.max(xs + 1, ((x + 1) * cell).floor());
        // Average every source pixel in the cell (as OpenCV's area resize), sampling every
        // other pixel only for very large crops.
        final stepY = math.max(1, (ye - ys) ~/ 8), stepX = math.max(1, (xe - xs) ~/ 8);
        for (var sy = ys; sy < ye; sy += stepY) {
          for (var sx = xs; sx < xe; sx += stepX) {
            final px = sx - left, py = sy - top;
            if (px < 0 || py < 0 || px >= width || py >= height) {
              r += 255;
              g += 255;
              b += 255;
            } else {
              final o = (py.floor() * width + px.floor()) * 4;
              r += pixels[o];
              g += pixels[o + 1];
              b += pixels[o + 2];
            }
            n++;
          }
        }
        final i = y * size + x;
        out[offset + i] = (r / n / 255 - mean[0]) / std[0];
        out[offset + size * size + i] = (g / n / 255 - mean[1]) / std[1];
        out[offset + 2 * size * size + i] = (b / n / 255 - mean[2]) / std[2];
      }
    }
  }

  /// Hue/saturation histogram (18 x 8, L1-normalised) of the coloured part, as OpenCV computes
  /// it: on the crop averaged down to 128 x 128 (area resize), then HSV.
  Float32List colourHistogram() {
    const side = 128;
    final hist = Float32List(18 * 8);
    var total = 0.0;
    final cellX = width / side, cellY = height / side;
    for (var y = 0; y < side; y++) {
      final ys = (y * cellY).floor(), ye = math.max(ys + 1, ((y + 1) * cellY).floor()).clamp(1, height);
      for (var x = 0; x < side; x++) {
        final xs = (x * cellX).floor(), xe = math.max(xs + 1, ((x + 1) * cellX).floor()).clamp(1, width);
        var rs = 0, gs = 0, bs = 0, n = 0;
        for (var sy = ys; sy < ye; sy++) {
          for (var sx = xs; sx < xe; sx++) {
            final o = (sy * width + sx) * 4;
            rs += pixels[o];
            gs += pixels[o + 1];
            bs += pixels[o + 2];
            n++;
          }
        }
        final r = (rs / n).round(), g = (gs / n).round(), b = (bs / n).round();
        final v = math.max(r, math.max(g, b)), mn = math.min(r, math.min(g, b));
        final s = v == 0 ? 0 : ((v - mn) * 255 / v).round();
        if (!(v < 245 || s > 20)) continue;
        double h;
        if (v == mn) {
          h = 0;
        } else if (v == r) {
          h = 60.0 * (g - b) / (v - mn);
        } else if (v == g) {
          h = 120 + 60.0 * (b - r) / (v - mn);
        } else {
          h = 240 + 60.0 * (r - g) / (v - mn);
        }
        if (h < 0) h += 360;
        final hb = math.min(17, (h / 2).round() ~/ 10), sb = math.min(7, s ~/ 32);
        hist[hb * 8 + sb] += 1;
        total += 1;
      }
    }
    if (total > 0) {
      for (var i = 0; i < hist.length; i++) {
        hist[i] /= total;
      }
    }
    return hist;
  }
}

class RecognitionProduct {
  RecognitionProduct(this.sku, this.name, this.brand, this.manufacturer, this.isOwn);
  final String sku, name, brand, manufacturer;
  final bool isOwn;
}

class RecognitionThresholds {
  RecognitionThresholds(Map<String, dynamic> j)
    : box = (j['box'] as num).toDouble(),
      other = (j['other'] as num).toDouble(),
      brandRead = (j['brand_read'] as num).toDouble(),
      packWeight = (j['pack_weight'] as num).toDouble(),
      referenceWeight = (j['reference_weight'] as num).toDouble(),
      accept = (j['accept'] as num).toDouble(),
      fragmentVote = (j['fragment_vote'] as num).toDouble(),
      demoire = j['demoire'] == true;
  final double box, other, brandRead, packWeight, referenceWeight, accept, fragmentVote;
  final bool demoire;
}

/// What the nearest labelled shelf packs say about one crop.
class ReferenceMatch {
  const ReferenceMatch(this.square, this.other, this.fragmentVote);
  final double square, other, fragmentVote;
}

/// Labelled packs from demo shelves (Square, other brand, or fragment / background), looked up
/// by fingerprint: no training, the same kind of lookup as the pack shots.
class ShelfReferences {
  ShelfReferences(Map<String, dynamic> j)
    : embeddings = decodeHalfFloats(j['embeddings'] as String),
      labels = j['labels'] as String,
      k = (j['k'] as num).toInt();
  final Float32List embeddings;
  final String labels;
  final int k;

  static const _square = 0x53, _other = 0x4F, _fragment = 0x58; // S, O, X

  ReferenceMatch lookup(Float32List feature, int dim) {
    var square = -2.0, other = -2.0;
    final sims = Float32List(labels.length);
    for (var i = 0; i < labels.length; i++) {
      final s = _dot(feature, embeddings, i * dim, dim);
      sims[i] = s;
      final label = labels.codeUnitAt(i);
      if (label == _square && s > square) square = s;
      if (label == _other && s > other) other = s;
    }
    final order = List<int>.generate(labels.length, (i) => i)..sort((a, b) => sims[b].compareTo(sims[a]));
    var fragment = 0.0, all = 0.0;
    for (final i in order.take(k)) {
      all += sims[i];
      if (labels.codeUnitAt(i) == _fragment) fragment += sims[i];
    }
    return ReferenceMatch(square, other, all == 0 ? 0 : fragment / all);
  }
}

class RecognitionCatalog {
  RecognitionCatalog.fromJson(Map<String, dynamic> j)
    : products = [
        for (final p in (j['products'] as List).cast<Map<String, dynamic>>())
          RecognitionProduct(p['sku'] as String, p['name'] as String, p['brand'] as String, p['manufacturer'] as String,
              p['is_own'] as bool),
      ],
      viewProduct = ((j['views'] as Map)['product'] as List).cast<int>(),
      viewEmbeddings = decodeHalfFloats(((j['views'] as Map)['embeddings']) as String),
      viewColours = decodeHalfFloats(((j['views'] as Map)['colours']) as String),
      dim = ((j['embedder'] as Map)['dim'] as num).toInt(),
      size = ((j['embedder'] as Map)['size'] as num).toInt(),
      mean = ((j['embedder'] as Map)['mean'] as List).map((v) => (v as num).toDouble()).toList(),
      std = ((j['embedder'] as Map)['std'] as List).map((v) => (v as num).toDouble()).toList(),
      embedderName = (j['embedder'] as Map)['name'] as String,
      detectorName = (j['detector'] as Map)['name'] as String,
      brandNames = (((j['brands'] as Map)['names']) as List).cast<String>(),
      brandEmbeddings = decodeHalfFloats(((j['brands'] as Map)['embeddings']) as String),
      brandBias = ((j['brands'] as Map)['bias'] as List).map((v) => (v as num).toDouble()).toList(),
      brandProduct = (((j['brands'] as Map)['product']) as Map).map((k, v) => MapEntry(k as String, (v as num).toInt())),
      clean = RecognitionThresholds((j['thresholds'] as Map)['clean'] as Map<String, dynamic>),
      screen = RecognitionThresholds((j['thresholds'] as Map)['screen'] as Map<String, dynamic>),
      cleanReferences = ShelfReferences((j['references'] as Map)['clean'] as Map<String, dynamic>),
      screenReferences = ShelfReferences((j['references'] as Map)['screen'] as Map<String, dynamic>);

  final List<RecognitionProduct> products;
  final List<int> viewProduct;
  final Float32List viewEmbeddings, viewColours, brandEmbeddings;
  final int dim, size;
  final List<double> mean, std, brandBias;
  final String embedderName, detectorName;
  final List<String> brandNames;
  final Map<String, int> brandProduct;
  final RecognitionThresholds clean, screen;
  final ShelfReferences cleanReferences, screenReferences;
  int get colourSize => 18 * 8;

  /// The brand whose printed name the crop reads as, and its probability; null for "Bengali writing".
  (String?, double) readBrand(Float32List feature) {
    final prompts = brandNames.length + 1;
    final logits = List<double>.generate(prompts, (i) => 100 * _dot(feature, brandEmbeddings, i * dim, dim) - brandBias[i]);
    final top = logits.reduce(math.max);
    final exps = logits.map((l) => math.exp(l - top)).toList();
    final sum = exps.reduce((a, b) => a + b);
    var best = 0;
    for (var i = 1; i < prompts; i++) {
      if (exps[i] > exps[best]) best = i;
    }
    return (best < brandNames.length ? brandNames[best] : null, exps[best] / sum);
  }
}

/// Little-endian float16 values (base64) as float32.
Float32List decodeHalfFloats(String b64) {
  final bytes = base64Decode(b64);
  final data = ByteData.sublistView(bytes);
  final out = Float32List(bytes.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final h = data.getUint16(i * 2, Endian.little);
    final sign = (h >> 15) & 1, exp = (h >> 10) & 0x1f, frac = h & 0x3ff;
    double v;
    if (exp == 0) {
      v = frac / 1024 * math.pow(2, -14);
    } else if (exp == 31) {
      v = frac == 0 ? double.infinity : double.nan;
    } else {
      v = (1 + frac / 1024) * math.pow(2, exp - 15);
    }
    out[i] = sign == 1 ? -v : v;
  }
  return out;
}
