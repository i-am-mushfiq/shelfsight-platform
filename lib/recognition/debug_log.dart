import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Debug trace of on-device recognition: every line goes to logcat (tag "flutter", prefix
/// "[vision]") and to a ring buffer shown in the app (Profile → Recognition log), so a
/// failure can be read without a cable.
class RecognitionLog {
  RecognitionLog._();

  static const _max = 400;
  static final ValueNotifier<List<String>> lines = ValueNotifier(const []);

  static void log(String message) {
    final now = DateTime.now();
    final stamp = '${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
    final line = '$stamp $message';
    debugPrint('[vision] $line');
    final next = [...lines.value, line];
    lines.value = next.length > _max ? next.sublist(next.length - _max) : next;
  }

  static void error(String where, Object error, [StackTrace? stack]) {
    log('ERROR in $where: ${error.runtimeType}: $error');
    if (stack != null) {
      for (final frame in stack.toString().split('\n').take(12)) {
        if (frame.trim().isNotEmpty) log('    $frame');
      }
    }
  }

  static void clear() => lines.value = const [];

  static String _two(int v) => v.toString().padLeft(2, '0');
}

class RecognitionLogScreen extends StatelessWidget {
  const RecognitionLogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recognition log'),
        actions: [
          IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: RecognitionLog.lines.value.join('\n')));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Log copied.')));
              }
            },
          ),
          IconButton(tooltip: 'Clear', icon: const Icon(Icons.delete_outline), onPressed: RecognitionLog.clear),
        ],
      ),
      body: ValueListenableBuilder<List<String>>(
        valueListenable: RecognitionLog.lines,
        builder: (context, lines, _) => lines.isEmpty
            ? const Center(child: Text('Nothing logged yet. Take a photo or start Live scan.'))
            : ListView.builder(
                reverse: true,
                padding: const EdgeInsets.all(12),
                itemCount: lines.length,
                itemBuilder: (context, i) {
                  final line = lines[lines.length - 1 - i];
                  return SelectableText(
                    line,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: line.contains('ERROR') ? Colors.red : null,
                    ),
                  );
                },
              ),
      ),
    );
  }
}
