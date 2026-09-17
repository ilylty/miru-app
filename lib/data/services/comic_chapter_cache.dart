import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:miru_app/utils/miru_storage.dart';

/// 一话的「元数据」缓存条目。
///
/// ★ 这里缓存的是**这一话包含哪些图片 URL**（以及请求所需的 headers），
///   不是图片字节本身 —— 图片字节由 `ComicImageCache` 负责。
///
/// 两者缺一不可：即使所有图片都已经躺在磁盘缓存里，只要不知道「该画哪些
/// URL」，阅读器仍然得先跑一次扩展（QuickJS 求值 + 网络请求 + HTML 解析）
/// 才能拿到 URL 列表。这就是「图片缓存了，但每次进入还是要等很久」的根因。
@immutable
class ComicChapterCacheEntry {
  const ComicChapterCacheEntry({
    required this.chapterUrl,
    required this.urls,
    this.headers,
    this.title = '',
    required this.updatedAt,
  });

  /// 播放列表里该话的 URL。
  ///
  /// 它一旦变化（扩展更新 / 章节被重新发布）就说明缓存的 URL 列表可能已经
  /// 失效，读取时会被当作未命中。
  final String chapterUrl;

  /// 该话的全部图片地址。
  final List<String> urls;

  /// 请求该话图片所需的 headers。
  ///
  /// 注意：其中的 Cookie 是会话性的，读取时会用当前 cookie jar 刷新
  /// （见 `ComicController._refreshHeaders`），避免拿过期凭据去请求图片。
  final Map<String, String>? headers;

  /// 章节标题（仅用于展示）。
  final String title;

  final DateTime updatedAt;

  /// 缓存是否仍然「新鲜」（不需要回源校正）。
  ///
  /// ★ 这是「再次进入直接用本地缓存」的关键：刚读过就退出再进来时，
  ///   缓存还新鲜 → **完全不发任何网络请求**。
  ///   只有超过 [ttl] 的旧缓存才会在后台回源校正（不阻塞首屏）。
  bool isFresh(Duration ttl) =>
      ttl > Duration.zero &&
      DateTime.now().difference(updatedAt) < ttl;

  Map<String, dynamic> toMap() => {
        'chapterUrl': chapterUrl,
        'urls': urls,
        'headers': headers,
        'title': title,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  /// 解析存储值；任何非法/损坏数据都返回 null（当作未命中），不抛异常。
  static ComicChapterCacheEntry? fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) {
      return null;
    }
    final rawUrls = map['urls'];
    if (rawUrls is! List) {
      return null;
    }
    final urls = rawUrls
        .whereType<String>()
        .where((url) => url.isNotEmpty)
        .toList(growable: false);
    if (urls.isEmpty) {
      return null;
    }
    Map<String, String>? headers;
    final rawHeaders = map['headers'];
    if (rawHeaders is Map) {
      headers = <String, String>{};
      rawHeaders.forEach((key, value) {
        if (key != null && value != null) {
          headers![key.toString()] = value.toString();
        }
      });
    }
    return ComicChapterCacheEntry(
      chapterUrl: map['chapterUrl']?.toString() ?? '',
      urls: urls,
      headers: headers,
      title: map['title']?.toString() ?? '',
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (map['updatedAt'] as num?)?.toInt() ?? 0,
      ),
    );
  }

  /// 解析任意形态的存储值（JSON 字符串 / Map / null）。
  static ComicChapterCacheEntry? decode(dynamic raw) {
    if (raw == null) {
      return null;
    }
    if (raw is Map) {
      return fromMap(raw);
    }
    if (raw is String) {
      final text = raw.trim();
      if (text.isEmpty) {
        return null;
      }
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) {
          return fromMap(decoded);
        }
      } catch (_) {
        // 数据损坏 → 当作未命中，而不是让整个阅读流程炸掉。
      }
    }
    return null;
  }

  String encode() => jsonEncode(toMap());
}

/// 缓存键：漫画的 detailUrl + 章节序号。
///
/// 用 md5 压成定长 key，避免 URL 里的特殊字符影响 Hive 的 key 排序。
String comicChapterCacheKey(String detailUrl, int chapterIndex) =>
    '${md5.convert(utf8.encode(detailUrl))}#$chapterIndex';

/// 章节元数据缓存的存储抽象（可注入，便于测试）。
abstract class ComicChapterStore {
  /// 读取缓存；[chapterUrl] 用于校验缓存是否仍然对应当前播放列表。
  ComicChapterCacheEntry? read(
    String detailUrl,
    int chapterIndex, {
    required String chapterUrl,
  });

  Future<void> write(
    String detailUrl,
    int chapterIndex,
    ComicChapterCacheEntry entry,
  );

  Future<void> remove(String detailUrl, int chapterIndex);

  Future<void> clear();
}

/// 默认实现：持久化到 Hive。
///
/// Hive 的 box 打开后是**内存常驻**的，`box.get` 是同步调用，
/// 因此「读缓存」不产生任何 IO 等待 —— 这正是首屏能立刻出内容的前提。
class HiveComicChapterStore implements ComicChapterStore {
  const HiveComicChapterStore();

  /// 元数据条目总量上限（超出后淘汰最久未更新的），
  /// 避免长期使用后无限增长。
  static const int maxEntries = 5000;

  Box? get _box {
    try {
      return MiruStorage.comicChapterCache;
    } catch (_) {
      // Hive 尚未初始化（例如单元测试）→ 视为无缓存。
      return null;
    }
  }

  @override
  ComicChapterCacheEntry? read(
    String detailUrl,
    int chapterIndex, {
    required String chapterUrl,
  }) {
    final box = _box;
    if (box == null) {
      return null;
    }
    try {
      final entry = ComicChapterCacheEntry.decode(
        box.get(comicChapterCacheKey(detailUrl, chapterIndex)),
      );
      if (entry == null) {
        return null;
      }
      // 播放列表里的章节 URL 变了 → 旧的 URL 列表可能已经失效。
      if (entry.chapterUrl.isNotEmpty && entry.chapterUrl != chapterUrl) {
        return null;
      }
      return entry;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(
    String detailUrl,
    int chapterIndex,
    ComicChapterCacheEntry entry,
  ) async {
    final box = _box;
    if (box == null) {
      return;
    }
    try {
      await box.put(
        comicChapterCacheKey(detailUrl, chapterIndex),
        entry.encode(),
      );
      await _pruneIfNeeded(box);
    } catch (_) {
      // 写缓存失败不影响阅读。
    }
  }

  @override
  Future<void> remove(String detailUrl, int chapterIndex) async {
    final box = _box;
    if (box == null) {
      return;
    }
    try {
      await box.delete(comicChapterCacheKey(detailUrl, chapterIndex));
    } catch (_) {
      // 忽略删除失败。
    }
  }

  @override
  Future<void> clear() async {
    final box = _box;
    if (box == null) {
      return;
    }
    try {
      await box.clear();
    } catch (_) {
      // 忽略清理失败。
    }
  }

  /// 超过上限时淘汰最久未更新的条目。
  Future<void> _pruneIfNeeded(Box box) async {
    if (box.length <= maxEntries) {
      return;
    }
    final entries = <({dynamic key, DateTime updatedAt})>[];
    for (final key in box.keys) {
      final entry = ComicChapterCacheEntry.decode(box.get(key));
      entries.add((
        key: key,
        updatedAt:
            entry?.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
      ));
    }
    entries.sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
    final removeCount = entries.length - maxEntries;
    for (var i = 0; i < removeCount; i++) {
      await box.delete(entries[i].key);
    }
  }
}

/// 纯内存实现（测试用，不依赖 Hive）。
@visibleForTesting
class MemoryComicChapterStore implements ComicChapterStore {
  final Map<String, ComicChapterCacheEntry> entries =
      <String, ComicChapterCacheEntry>{};

  @override
  ComicChapterCacheEntry? read(
    String detailUrl,
    int chapterIndex, {
    required String chapterUrl,
  }) {
    final entry = entries[comicChapterCacheKey(detailUrl, chapterIndex)];
    if (entry == null) {
      return null;
    }
    if (entry.chapterUrl.isNotEmpty && entry.chapterUrl != chapterUrl) {
      return null;
    }
    return entry;
  }

  @override
  Future<void> write(
    String detailUrl,
    int chapterIndex,
    ComicChapterCacheEntry entry,
  ) async {
    entries[comicChapterCacheKey(detailUrl, chapterIndex)] = entry;
  }

  @override
  Future<void> remove(String detailUrl, int chapterIndex) async {
    entries.remove(comicChapterCacheKey(detailUrl, chapterIndex));
  }

  @override
  Future<void> clear() async => entries.clear();
}
