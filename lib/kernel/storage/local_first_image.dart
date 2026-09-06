import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../api/dio_factory.dart';
import '../services/optional_services.dart';

typedef ImageRequest = ({String url, OptionalService service});

/// Cache reads never revalidate online. A download is explicitly authorized,
/// cancellation-aware, and only then committed to the shared disk cache.
final localImageFileProvider = FutureProvider.autoDispose
    .family<File?, ImageRequest>((ref, request) async {
      final enabled = ref.watch(serviceEnabledProvider(request.service));
      final cache = DefaultCacheManager();
      final uri = Uri.tryParse(request.url);
      if (uri?.scheme == 'file') return File.fromUri(uri!);
      final cached = await cache.getFileFromCache(request.url);
      if (cached != null && await cached.file.exists()) return cached.file;
      if (!enabled ||
          !ref.mounted ||
          uri == null ||
          !{'https', 'http'}.contains(uri.scheme)) {
        return null;
      }
      final cancel = CancelToken();
      ref.onDispose(() => cancel.cancel());
      final response = await ref
          .read(dioProvider(DioPurpose.bare))
          .get<List<int>>(
            request.url,
            cancelToken: cancel,
            options: Options(
              responseType: ResponseType.bytes,
              extra: {'optionalService': request.service.name},
            ),
          );
      if (!ref.mounted || cancel.isCancelled || response.data == null) {
        return null;
      }
      return cache.putFile(
        request.url,
        Uint8List.fromList(response.data!),
        fileExtension: uri.path.toLowerCase().endsWith('.svg') ? 'svg' : 'img',
      );
    });

class LocalFirstImage extends ConsumerWidget {
  const LocalFirstImage({
    super.key,
    required this.imageUrl,
    this.service = OptionalService.downloads,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.memCacheWidth,
    this.memCacheHeight,
    this.placeholder,
    this.errorWidget,
  });
  final String imageUrl;
  final OptionalService service;
  final BoxFit fit;
  final double? width, height;
  final int? memCacheWidth, memCacheHeight;
  final Widget Function(BuildContext, String)? placeholder;
  final Widget Function(BuildContext, String, Object)? errorWidget;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(
      localImageFileProvider((url: imageUrl, service: service)),
    );
    Widget fallback() =>
        placeholder?.call(context, imageUrl) ??
        const Icon(Icons.image_outlined);
    final file = result.value;
    if (file == null) {
      return result.hasError
          ? errorWidget?.call(context, imageUrl, result.error!) ?? fallback()
          : fallback();
    }
    if (Uri.tryParse(imageUrl)?.path.toLowerCase().endsWith('.svg') == true) {
      return SvgPicture.file(
        file,
        width: width,
        height: height,
        fit: fit,
        placeholderBuilder: (_) => fallback(),
      );
    }
    return Image.file(
      file,
      fit: fit,
      width: width,
      height: height,
      cacheWidth: memCacheWidth,
      cacheHeight: memCacheHeight,
      errorBuilder: (context, error, _) =>
          errorWidget?.call(context, imageUrl, error) ?? fallback(),
    );
  }
}
