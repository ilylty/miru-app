import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:miru_app/models/comic_cache_config.dart';
import 'package:miru_app/utils/miru_storage.dart';

/// 漫画缓存配置的读写封装。
///
/// 存储层用 Hive 的 settings box，值统一序列化成 JSON 字符串，
/// 这样即使历史数据损坏/类型变化也不会让整个设置初始化失败。
class ComicCacheConfigStore {
  /// 配置在 Hive 中的 key。
  static const String storageKey = SettingKey.comicCacheConfig;

  static const String _legacyPrefix = '__miru_comic_cache_config__:';

  /// 配置变更通知：阅读器监听它以便「设置改完立即生效」。
  ///
  /// 用一个自增版本号而不是值对象，避免 UI 层意外持有旧配置。
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 通知所有监听者重新读取配置。
  static void notifyChanged() {
    revision.value++;
  }

  static String encode(ComicCacheConfig config) =>
      '$_legacyPrefix${jsonEncode(config.toMap())}';

  /// 解析任意形态的存储值（JSON 字符串 / Map / null）。
  static ComicCacheConfig decode(dynamic raw) {
    if (raw == null) {
      return const ComicCacheConfig();
    }
    if (raw is Map) {
      return ComicCacheConfig.fromMap(raw);
    }
    if (raw is String) {
      var text = raw.trim();
      if (text.isEmpty) {
        return const ComicCacheConfig();
      }
      if (text.startsWith(_legacyPrefix)) {
        text = text.substring(_legacyPrefix.length);
      }
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) {
          return ComicCacheConfig.fromMap(decoded);
        }
      } catch (_) {
        // 数据损坏时回退到默认值，而不是抛出异常阻塞设置页面。
      }
      return const ComicCacheConfig();
    }
    return const ComicCacheConfig();
  }

  /// 读取当前配置。任何异常都回退到默认值。
  static ComicCacheConfig load() {
    final override = loaderOverride;
    if (override != null) {
      return override();
    }
    try {
      return decode(MiruStorage.getSetting(storageKey));
    } catch (_) {
      return const ComicCacheConfig();
    }
  }

  /// 测试注入点：不依赖 Hive 即可驱动配置读取路径。
  @visibleForTesting
  static ComicCacheConfig Function()? loaderOverride;

  /// 测试注入点：不依赖 Hive 即可驱动配置写入路径。
  @visibleForTesting
  static Future<void> Function(ComicCacheConfig config)? saveOverride;

  /// 写入配置。
  static Future<void> save(ComicCacheConfig config) async {
    final override = saveOverride;
    if (override != null) {
      await override(config);
    } else {
      await MiruStorage.setSetting(storageKey, encode(config));
    }
    notifyChanged();
  }
}
