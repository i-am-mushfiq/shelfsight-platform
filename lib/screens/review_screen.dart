import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'package:image_picker/image_picker.dart';

import '../models/field_models.dart';
import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import 'audit_upload_screen.dart';

class ReviewScreen extends StatefulWidget {
  const ReviewScreen({
    super.key,
    required this.storeName,
    required this.storeTypeName,
    required this.visitId,
    required this.photos,
    this.spheres = const [],
  });
  final String storeName;
  final String storeTypeName;
  final String visitId;
  final List<CapturedPhoto> photos;

  /// 360° spheres already uploaded and stitched (they are captures on the server).
  final List<Map<String, dynamic>> spheres;
  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  final ImagePicker _picker = ImagePicker();
  late final List<CapturedPhoto> _photos = [...widget.photos];

  Future<void> _addPhoto() async {
    final photo = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 88,
      maxWidth: 2400,
    );
    if (photo == null || !mounted) return;
    // A new section usually belongs to the rack photographed last.
    final last = _photos.lastOrNull;
    setState(() => _photos.add(
      CapturedPhoto(path: photo.path, categoryId: last?.categoryId, categoryName: last?.categoryName),
    ));
  }

  Future<void> _retake(int index) async {
    final photo = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 88,
      maxWidth: 2400,
    );
    if (photo != null && mounted) setState(() => _photos[index] = _photos[index].withPath(photo.path));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t('Your photos')),
            Text(
              t('Check they are clear, then send them'),
              style: TextStyle(
                fontSize: AppFontSize.sm,
                color: AppColors.inkMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              color: AppColors.surfaceAlt,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(Icons.storefront_outlined),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.storeName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: AppFontSize.lg,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  widget.storeTypeName,
                                  style: const TextStyle(
                                    fontSize: AppFontSize.sm,
                                    color: AppColors.inkMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          StatusPill(label: '${_photos.length + widget.spheres.length} photos'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFECFDF5),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: const Color(0xFFA7F3D0)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.verified_rounded,
                          color: AppColors.emeraldDark,
                          size: 26,
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                t('Photos look good'),
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.emeraldDark,
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                t('Not blurry or too dark. You can still take any photo again.'),
                                style: TextStyle(
                                  fontSize: AppFontSize.md,
                                  height: 1.4,
                                  color: AppColors.emeraldDark,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  for (final sphere in widget.spheres)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Card(
                        child: ListTile(
                          leading: const Icon(Icons.threesixty_rounded, color: AppColors.emeraldDark),
                          title: Text(t('360° photo sphere'), style: TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(
                            '${(sphere['sphere'] as Map?)?['frames'] ?? '?'} photos · '
                            '${(sphere['sphere'] as Map?)?['stitched'] == false ? 'side by side' : 'stitched'} · uploaded',
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 18),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _photos.length + 1,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: .72,
                        ),
                    itemBuilder: (context, index) {
                      if (index == _photos.length) {
                        return _AddPhotoCard(onTap: _addPhoto);
                      }
                      return _PhotoCard(
                        photo: _photos[index],
                        onRetake: () => _retake(index),
                        onDelete: () => setState(() => _photos.removeAt(index)),
                      );
                    },
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: AppColors.border)),
              ),
              child: PrimaryButton(
                label: t('Send photos'),
                onPressed: _photos.isEmpty && widget.spheres.isEmpty
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => AuditUploadScreen(
                            storeName: widget.storeName,
                            visitId: widget.visitId,
                            photos: List.unmodifiable(_photos),
                            sphereCaptureIds: [for (final s in widget.spheres) s['id'] as String],
                          ),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhotoCard extends StatelessWidget {
  const _PhotoCard({
    required this.photo,
    required this.onRetake,
    required this.onDelete,
  });
  final CapturedPhoto photo;
  final VoidCallback onRetake;
  final VoidCallback onDelete;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(15),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.file(File(photo.path), fit: BoxFit.cover),
                  Align(
                    alignment: Alignment.topLeft,
                    child: Padding(
                  padding: EdgeInsets.all(8),
                      child: StatusPill(
                        label: t('Selected'),
                        icon: Icons.check_circle_outline_rounded,
                        color: Colors.white,
                        background: AppColors.emeraldDark,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            photo.rackLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 3),
          Text(
            t('Checked when sent'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppFontSize.sm,
              fontWeight: FontWeight.w600,
              color: AppColors.inkMuted,
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton.filledTonal(
                onPressed: onRetake,
                icon: const Icon(Icons.refresh_rounded, size: 18),
              ),
              const SizedBox(width: 4),
              IconButton.filledTonal(
                onPressed: onDelete,
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  color: AppColors.red,
                  size: 18,
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _AddPhotoCard extends StatelessWidget {
  const _AddPhotoCard({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(24),
    child: Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border, width: 2),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.add_a_photo_outlined, size: 34, color: AppColors.inkMuted),
          SizedBox(height: 12),
          Text(t('Add section'), style: TextStyle(fontWeight: FontWeight.w600)),
          SizedBox(height: 4),
          Text(
            t('Capture another photo'),
            style: TextStyle(fontSize: AppFontSize.sm, color: AppColors.inkMuted),
          ),
        ],
      ),
    ),
  );
}
