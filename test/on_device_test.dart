// The on-device recogniser's own steps (catalogue decoding, image decoding, colour stretch,
// colour histogram, model input), checked against the validated Python reference
// (tools/check_on_device_models.py). The two ONNX model calls are not run here.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsight/recognition/on_device.dart';

void main() {
  final ref = jsonDecode(File('test/fixtures/on_device_reference.json').readAsStringSync()) as Map<String, dynamic>;
  _referenceAndMoireTests(ref);

  test('the bundled catalogue decodes to the numbers Python reads', () {
    final catalog = RecognitionCatalog.fromJson(
      jsonDecode(File('assets/recognition/catalog.json').readAsStringSync()) as Map<String, dynamic>,
    );
    expect(catalog.dim, ref['dim']);
    expect(catalog.viewProduct.length, ref['views']);
    expect(catalog.brandNames.length, ref['brands']);
    final view0 = (ref['view0'] as List).cast<num>();
    for (var i = 0; i < view0.length; i++) {
      expect(catalog.viewEmbeddings[i], closeTo(view0[i], 1e-3));
    }
    // Fingerprints are unit length, so a pack shot matches itself with similarity 1.
    var norm = 0.0;
    for (var i = 0; i < catalog.dim; i++) {
      norm += catalog.viewEmbeddings[i] * catalog.viewEmbeddings[i];
    }
    expect(norm, closeTo(1, 2e-3));
  });

  testWidgets('decoding, colour stretch, histogram and model input match Python', (tester) async {
    await tester.runAsync(() async {
      final image = await RgbaImage.decode(File('test/fixtures/screen_shelf.jpg').readAsBytesSync(), maxSide: 1280);
      expect([image.width, image.height], (ref['size'] as List).cast<int>());
      image.stretchColours();
      final box = (ref['crop'] as List).cast<num>();
      final crop = image.crop(box[0].toDouble(), box[1].toDouble(), box[2].toDouble(), box[3].toDouble());

      // Colour histograms: the same colours, as OpenCV measures them (1 = identical).
      final dart = crop.colourHistogram();
      final python = Float32List.fromList((ref['colours'] as List).map((v) => (v as num).toDouble()).toList());
      final similarity = 1 - bhattacharyya(dart, python, 0, dart.length);
      // Flutter's JPEG decoder differs slightly from OpenCV's (extremes ~4 levels brighter).
      expect(similarity, greaterThan(.85));

      // Model input: the same picture of the pack (correlation of the sampled values).
      final s = 256;
      final input = Float32List(3 * s * s);
      crop.writeClipInput(input, 0, s, const [0, 0, 0], const [1, 1, 1]);
      final stride = ref['clip_stride'] as int;
      final expected = (ref['clip'] as List).cast<num>();
      // Python's reference uses the catalogue's normalisation; undo it from Dart's raw values.
      final catalog = jsonDecode(File('assets/recognition/catalog.json').readAsStringSync()) as Map<String, dynamic>;
      final mean = ((catalog['embedder'] as Map)['mean'] as List).cast<num>();
      final std = ((catalog['embedder'] as Map)['std'] as List).cast<num>();
      final a = <double>[], b = <double>[];
      for (var k = 0; k < expected.length; k++) {
        final i = k * stride;
        final channel = i ~/ (s * s);
        a.add((input[i] - mean[channel]) / std[channel]);
        b.add(expected[k].toDouble());
      }
      expect(_correlation(a, b), greaterThan(.93));
      // ignore: avoid_print
      print('histogram similarity ${similarity.toStringAsFixed(3)}, input correlation ${_correlation(a, b).toStringAsFixed(3)}');
    });
  });
}

void _referenceAndMoireTests(Map<String, dynamic> ref) {
  test('shelf references decode, and a pack finds itself among them', () {
    final catalog = RecognitionCatalog.fromJson(
      jsonDecode(File('assets/recognition/catalog.json').readAsStringSync()) as Map<String, dynamic>,
    );
    final counts = (ref['references'] as Map).cast<String, int>();
    expect(catalog.cleanReferences.labels.length, counts['clean']);
    expect(catalog.screenReferences.labels.length, counts['screen']);
    final refs = catalog.cleanReferences;
    final first = Float32List.sublistView(refs.embeddings, 0, catalog.dim);
    final match = refs.lookup(Float32List.fromList(first), catalog.dim);
    final own = refs.labels[0];
    if (own == 'S') expect(match.square, closeTo(1, 2e-3));
    if (own == 'O') expect(match.other, closeTo(1, 2e-3));
  });

  testWidgets('moire smoothing matches OpenCV', (tester) async {
    await tester.runAsync(() async {
      final image = await RgbaImage.decode(File('test/fixtures/screen_shelf.jpg').readAsBytesSync(), maxSide: 1280);
      image.stretchColours();
      image.removeMoire();
      final box = (ref['crop'] as List).cast<num>();
      final crop = image.crop(box[0].toDouble(), box[1].toDouble(), box[2].toDouble(), box[3].toDouble());
      final mean = [0.0, 0.0, 0.0];
      for (var i = 0; i < crop.pixels.length; i += 4) {
        for (var c = 0; c < 3; c++) {
          mean[c] += crop.pixels[i + c];
        }
      }
      final expected = (ref['moire_crop_mean'] as List).cast<num>();
      for (var c = 0; c < 3; c++) {
        // Within a few levels: Flutter's JPEG decoder differs slightly from OpenCV's.
        expect(mean[c] / (crop.pixels.length / 4), closeTo(expected[c], 6));
      }
      final samples = <double>[];
      for (var y = 0; y < crop.height; y += 7) {
        for (var x = 0; x < crop.width; x += 7) {
          final o = (y * crop.width + x) * 4;
          samples.addAll([crop.pixels[o].toDouble(), crop.pixels[o + 1].toDouble(), crop.pixels[o + 2].toDouble()]);
        }
      }
      final python = (ref['moire_samples'] as List).map((v) => (v as num).toDouble()).toList();
      expect(_correlation(samples, python), greaterThan(.95));
    });
  });
}

double _correlation(List<double> a, List<double> b) {
  final ma = a.reduce((x, y) => x + y) / a.length, mb = b.reduce((x, y) => x + y) / b.length;
  var num = 0.0, da = 0.0, db = 0.0;
  for (var i = 0; i < a.length; i++) {
    num += (a[i] - ma) * (b[i] - mb);
    da += (a[i] - ma) * (a[i] - ma);
    db += (b[i] - mb) * (b[i] - mb);
  }
  return num / math.sqrt(da * db);
}
