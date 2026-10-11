import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';

import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import '../widgets/shell_widgets.dart';

class _Lesson {
  const _Lesson(this.title, this.topic, this.seconds, this.summary);
  final String title;
  final String topic;
  final int seconds;
  final String summary;
}

const _lessons = [
  _Lesson(
    'Win the eye-level shelf',
    'Shelf share',
    192,
    'Ask the shopkeeper to move Meril and Sepnil to the middle shelves.',
  ),
  _Lesson(
    'Handle "no space" objections',
    'Negotiation',
    245,
    'Offer a swap plan: remove slow movers, keep fast ones facing out.',
  ),
  _Lesson(
    'Photo tips for accurate counts',
    'Capture',
    128,
    'Stand square to the shelf, keep every row in frame, avoid glare.',
  ),
  _Lesson(
    'Spotting competitor promotions',
    'Competitor',
    174,
    'Note banners and price tags, then flag them in the visit report.',
  ),
];

/// Audio-based sales coaching. Playback is simulated until real audio assets
/// are connected (swap the timer for an audio player package).
class LearnScreen extends StatefulWidget {
  const LearnScreen({super.key});

  @override
  State<LearnScreen> createState() => _LearnScreenState();
}

class _LearnScreenState extends State<LearnScreen> {
  int _current = 0;
  int _elapsed = 0;
  bool _playing = false;
  Timer? _timer;

  _Lesson get _lesson => _lessons[_current];

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _toggle() {
    setState(() => _playing = !_playing);
    _timer?.cancel();
    if (_playing) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_elapsed >= _lesson.seconds) {
          _timer?.cancel();
          setState(() => _playing = false);
          return;
        }
        setState(() => _elapsed++);
      });
    }
  }

  void _select(int i) {
    _timer?.cancel();
    setState(() {
      _current = i;
      _elapsed = 0;
      _playing = false;
    });
    _toggle();
  }

  String _fmt(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return FixedHeaderScrollView(
      title: t('Learn'),
      subtitle: t('Preview · audio not connected yet'),
      slivers: [
        pagePadding([
          Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: StatusPill(
              label: t('Preview only: lesson playback is simulated. Real call coaching is a later milestone.'),
              icon: Icons.info_outline_rounded,
              color: AppColors.amberInk,
              background: AppColors.amberSoft,
            ),
          ),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AppColors.navy,
              borderRadius: BorderRadius.circular(22),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                StatusPill(
                  label: _playing ? 'Now playing' : _lesson.topic,
                  icon: _playing
                      ? Icons.graphic_eq_rounded
                      : Icons.headphones_rounded,
                ),
                const SizedBox(height: 14),
                Text(
                  _lesson.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: AppFontSize.xl,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -.4,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _lesson.summary,
                  style: const TextStyle(color: Color(0xFFB6C2D4), height: 1.4),
                ),
                const SizedBox(height: 18),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _elapsed / _lesson.seconds,
                    minHeight: 6,
                    backgroundColor: Colors.white24,
                    color: AppColors.emerald,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _fmt(_elapsed),
                      style: const TextStyle(color: Colors.white70),
                    ),
                    Text(
                      _fmt(_lesson.seconds),
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                PrimaryButton(
                  label: _playing ? 'Pause' : 'Play lesson',
                  icon: _playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  backgroundColor: AppColors.emerald,
                  foregroundColor: AppColors.navy,
                  onPressed: _toggle,
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          SectionTitle(title: t('Coaching library')),
          const SizedBox(height: 8),
          for (var i = 0; i < _lessons.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SurfaceCard(
                onTap: () => _select(i),
                borderColor: i == _current
                    ? AppColors.emeraldDark
                    : AppColors.border,
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: i == _current
                            ? AppColors.mint
                            : AppColors.surfaceAlt,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        i == _current && _playing
                            ? Icons.graphic_eq_rounded
                            : Icons.play_arrow_rounded,
                        color: AppColors.emeraldDark,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _lessons[i].title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: AppFontSize.lg,
                              color: AppColors.ink,
                            ),
                          ),
                          Text(
                            '${_lessons[i].topic} · ${_fmt(_lessons[i].seconds)}',
                            style: const TextStyle(
                              color: AppColors.inkMuted,
                              fontSize: AppFontSize.md,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ]),
      ],
    );
  }
}
