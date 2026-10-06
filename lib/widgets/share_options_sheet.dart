import 'package:flutter/material.dart';

enum ShareOption { apps, gallery }

/// 分享入口的二选一：系统分享或保存到本地相册。
Future<ShareOption?> showShareOptionsSheet(
  BuildContext context, {
  required bool canSaveToGallery,
}) {
  return showModalBottomSheet<ShareOption>(
    context: context,
    showDragHandle: true,
    builder: (BuildContext context) {
      final ColorScheme colors = Theme.of(context).colorScheme;
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              key: const Key('share-option-apps'),
              leading: Icon(Icons.ios_share_rounded, color: colors.primary),
              title: const Text('分享给其他应用'),
              onTap: () => Navigator.pop(context, ShareOption.apps),
            ),
            if (canSaveToGallery)
              ListTile(
                key: const Key('share-option-gallery'),
                leading: Icon(
                  Icons.photo_library_outlined,
                  color: colors.primary,
                ),
                title: const Text('保存到本地相册'),
                onTap: () => Navigator.pop(context, ShareOption.gallery),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}
