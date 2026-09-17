import 'dart:io';

import 'package:extended_image/extended_image.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
/// 漫画图片的磁盘缓存工具。
///
/// 复用 `extended_image` 的磁盘缓存目录与命名规则
/// （`<临时目录>/cacheimage/<md5(url)>`），
/// 这样我们预下载的图片会被阅读器直接命中，
/// 不会出现「缓存了一份、渲染又下一份」的双倍流量。
class ComicImageCache {
  ComicImageCache._();

  /// 与 extended_image_library 的 `cacheImageFolderName` 保持一致。
  static const String folderName = cacheImageFolderName;

  /// 图片在缓存目录中的文件名。
  static String keyOf(String url, {String? cacheKey}) =>
      cacheKey ?? keyToMd5(url);

  static Directory? _cachedDir;

  /// 测试注入点：不依赖 path_provider 平台通道。
  @visibleForTesting
  static Directory? directoryOverride;

  /// 磁盘缓存目录（不存在则创建）。
  static Future<Directory> directory() async {
    final override = directoryOverride;
    if (override != null) {
      if (!override.existsSync()) {
        await override.create(recursive: true);
      }
      return override;
    }
    final cached = _cachedDir;
    if (cached != null && cached.existsSync()) {
      return cached;
    }
    final temp = await getTemporaryDirectory();
    final dir = Directory(p.join(temp.path, folderName));
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    _cachedDir = dir;
    return dir;
  }

  /// 该图片是否已经在磁盘缓存中。
  static Future<bool> exists(String url, {String? cacheKey}) async {
    try {
      final dir = await directory();
      return File(p.join(dir.path, keyOf(url, cacheKey: cacheKey))).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// 下载并写入磁盘缓存；已存在时直接返回 true。
  ///
  /// 返回是否成功。失败不会抛异常，交给调用方决定是否重试。
  static Future<bool> download(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) {
      return false;
    }
    final dir = await directory();
    final file = File(p.join(dir.path, keyOf(url)));
    if (file.existsSync() && file.lengthSync() > 0) {
      return true;
    }

    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = timeout;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      headers?.forEach((name, value) {
        request.headers.add(name, value);
      });
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return false;
      }
      final bytes = await consolidateHttpClientResponseBytes(response)
          .timeout(timeout);
      if (bytes.isEmpty) {
        return false;
      }
      // 先写临时文件再 rename，避免写到一半被杀进程留下半张图，
      // 让阅读器把坏文件当缓存命中。
      final temp = File('${file.path}.part');
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(file.path);
      return true;
    } catch (e) {
      debugPrint('comic cache download failed: $url $e');
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// 当前磁盘缓存占用字节数。
  static Future<int> sizeBytes() async {
    try {
      final dir = await directory();
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is File) {
          total += await entity.length();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// 按磁盘上限回收缓存（LRU：优先删最久未使用的文件）。
  ///
  /// [maxBytes] <= 0 表示不限制。返回实际删除的文件数。
  /// 回收时跳过 [protectedUrls] 里的文件（正在读的那一话不能被删掉）。
  static Future<int> trimToLimit(
    int maxBytes, {
    Set<String> protectedUrls = const <String>{},
  }) async {
    if (maxBytes <= 0) {
      return 0;
    }
    try {
      final dir = await directory();
      if (!dir.existsSync()) {
        return 0;
      }
      final protectedNames =
          protectedUrls.map((url) => keyOf(url)).toSet();
      final entries = <({File file, DateTime modified, int size})>[];
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is! File) {
          continue;
        }
        // 跳过写了一半的临时文件（它们不属于有效缓存）。
        if (entity.path.endsWith('.part')) {
          continue;
        }
        final stat = await entity.stat();
        entries.add((
          file: entity,
          modified: stat.modified,
          size: stat.size,
        ));
        total += stat.size;
      }
      if (total <= maxBytes) {
        return 0;
      }
      // 最久未修改（≈ 最久未使用）的先删。
      entries.sort((a, b) => a.modified.compareTo(b.modified));
      var removed = 0;
      for (final entry in entries) {
        if (total <= maxBytes) {
          break;
        }
        if (protectedNames.contains(p.basename(entry.file.path))) {
          continue;
        }
        try {
          await entry.file.delete();
          total -= entry.size;
          removed++;
        } catch (_) {
          // 删除失败（被占用等）就跳过，不影响其它文件。
        }
      }
      return removed;
    } catch (e) {
      debugPrint('comic cache trim failed: $e');
      return 0;
    }
  }

  /// 清理磁盘缓存。
  ///
  /// [olderThan] 为 null 时清空全部；否则只删除修改时间早于该时长的文件。
  static Future<void> clear({Duration? olderThan}) async {
    try {
      final dir = await directory();
      if (!dir.existsSync()) {
        return;
      }
      final now = DateTime.now();
      await for (final entity in dir.list()) {
        if (entity is! File) {
          continue;
        }
        if (olderThan == null) {
          await entity.delete();
          continue;
        }
        final stat = await entity.stat();
        if (now.difference(stat.modified) > olderThan) {
          await entity.delete();
        }
      }
    } catch (e) {
      debugPrint('comic cache clear failed: $e');
    }
  }
}
