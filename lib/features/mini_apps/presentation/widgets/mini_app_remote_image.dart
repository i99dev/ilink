import 'package:flutter/material.dart';
import '../../../../kernel/storage/local_first_image.dart';

/// Images resolve from disk offline; optional downloads use the shared guard.
void clearMiniAppRemoteImageCache() {}

class MiniAppRemoteImage extends StatelessWidget {
  const MiniAppRemoteImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.fallback,
  });
  final String? url;
  final BoxFit fit;
  final Widget? fallback;
  @override
  Widget build(BuildContext context) {
    final placeholder = fallback ?? const Icon(Icons.image_outlined);
    if (url == null || url!.trim().isEmpty) return placeholder;
    return LocalFirstImage(
      imageUrl: url!,
      fit: fit,
      placeholder: (_, _) => placeholder,
      errorWidget: (_, _, _) => placeholder,
    );
  }
}
