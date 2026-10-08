import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../theme/app_theme.dart';
import '../widgets/app_widgets.dart';
import 'audit_upload_screen.dart';

class ReviewScreen extends StatefulWidget {
  const ReviewScreen({
    super.key,
    required this.storeName,
    required this.visitId,
    required this.categoryId,
    required this.categoryName,
    required this.imagePaths,
  });
  final String storeName;
  final String visitId;
  final String categoryId;
  final String categoryName;
  final List<String> imagePaths;
  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  final ImagePicker _picker = ImagePicker();
  late final List<String> _photos = [...widget.imagePaths];

  Future<void> _addPhoto() async {
    final photo = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 88,
      maxWidth: 2400,
    );
    if (photo != null && mounted) setState(() => _photos.add(photo.path));
  }

  Future<void> _retake(int index) async {
    final photo = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 88,
      maxWidth: 2400,
    );
    if (photo != null && mounted) setState(() => _photos[index] = photo.path);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Review photos'),
            Text(
              'Step 3 of 3  •  Quality check',
              style: TextStyle(
                fontSize: 12,
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
                                    fontWeight: FontWeight.w800,
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                const Text(
                                  'Food & Beverage',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppColors.inkMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          StatusPill(label: '${_photos.length} photos'),
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
                    child: const Row(
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
                                'Ready to analyze',
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.emeraldDark,
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                'Basic blur and exposure checks passed. You can still retake any photo.',
                                style: TextStyle(
                                  fontSize: 13,
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
                        index: index,
                        imagePath: _photos[index],
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
                label: 'Upload and analyse',
                icon: Icons.auto_awesome_rounded,
                onPressed: _photos.isEmpty
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => AuditUploadScreen(
                            storeName: widget.storeName,
                            visitId: widget.visitId,
                            categoryId: widget.categoryId,
                            categoryName: widget.categoryName,
                            imagePaths: List.unmodifiable(_photos),
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
    required this.index,
    required this.imagePath,
    required this.onRetake,
    required this.onDelete,
  });
  final int index;
  final String imagePath;
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
                  Image.file(File(imagePath), fit: BoxFit.cover),
                  const Align(
                    alignment: Alignment.topLeft,
                    child: Padding(
                  padding: EdgeInsets.all(8),
                      child: StatusPill(
                        label: 'Selected',
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
            [
              'Left section',
              'Center section',
              'Right section',
              'Extra section',
            ][index % 4],
            maxLines: 1,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 3),
          const Text(
            'Quality checked during analysis',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
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
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.add_a_photo_outlined, size: 34, color: AppColors.inkMuted),
          SizedBox(height: 12),
          Text('Add section', style: TextStyle(fontWeight: FontWeight.w800)),
          SizedBox(height: 4),
          Text(
            'Capture another photo',
            style: TextStyle(fontSize: 12, color: AppColors.inkMuted),
          ),
        ],
      ),
    ),
  );
}
