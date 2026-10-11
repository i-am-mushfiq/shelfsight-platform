import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../recognition/on_device.dart';

/// Camera app-bar switch: photographing shelf images on a screen (the demo set-up) or a real
/// shelf. Recognition on the phone smooths a screen's moire and uses the thresholds tuned for
/// screen photos. One setting, shared by every camera.
class ScreenPhotoToggle extends StatelessWidget {
  const ScreenPhotoToggle({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: OnDeviceRecognizer.screenPhotos,
    builder: (context, screen, _) => IconButton(
      key: const Key('screen-photo-toggle'),
      tooltip: screen ? t('Photographing a screen (tap for a real shelf)') : t('Real shelf (tap for a screen)'),
      onPressed: () {
        OnDeviceRecognizer.screenPhotos.value = !screen;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            duration: const Duration(seconds: 2),
            content: Text(!screen ? t('Set for photos of a screen') : t('Set for a real shelf')),
          ));
      },
      icon: Icon(screen ? Icons.desktop_windows_outlined : Icons.storefront_outlined),
    ),
  );
}
