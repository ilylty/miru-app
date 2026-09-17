import 'dart:io';

import 'package:extended_image/extended_image.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miru_app/data/services/comic_image_cache.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    // 单元测试没有 path_provider 平台通道，用临时目录替代。
    tempDir = Directory.systemTemp.createTempSync('miru-cache-test-');
    ComicImageCache.directoryOverride =
        Directory(p.join(tempDir.path, ComicImageCache.folderName));
  });

  tearDown(() {
    ComicImageCache.directoryOverride = null;
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('ComicImageCache 磁盘缓存', () {
    test('缓存目录名与 extended_image 一致（预下载才能被阅读器直接命中）',
        () async {
      final dir = await ComicImageCache.directory();
      expect(p.basename(dir.path), ComicImageCache.folderName);
      expect(ComicImageCache.folderName, cacheImageFolderName);
      expect(dir.existsSync(), isTrue);
    });

    test('keyOf 使用 extended_image 的 md5 规则（与渲染侧 key 完全一致）', () {
      const url = 'https://img.test/c0/i0.jpg';
      expect(ComicImageCache.keyOf(url), keyToMd5(url));
      expect(ComicImageCache.keyOf(url, cacheKey: 'custom'), 'custom');
    });

    test('未缓存过的 URL，exists 返回 false', () async {
      expect(await ComicImageCache.exists('https://img.test/none.jpg'),
          isFalse);
    });

    test('非法 URL 下载直接失败，不抛异常', () async {
      expect(await ComicImageCache.download('not-a-url'), isFalse);
      expect(await ComicImageCache.download(''), isFalse);
      expect(await ComicImageCache.download('/relative/path.jpg'), isFalse);
    });

    test('sizeBytes / clear 在空目录下也安全', () async {
      expect(await ComicImageCache.sizeBytes(), 0);
      await ComicImageCache.clear();
      expect(await ComicImageCache.exists('https://img.test/x.jpg'), isFalse);
    });
  });

  group('缓存文件落盘后可被命中', () {
    test('写入缓存文件后 exists 返回 true（模拟预下载完成）', () async {
      final dir = await ComicImageCache.directory();
      const url = 'https://img.test/prefetched.jpg';
      final file = File(p.join(dir.path, ComicImageCache.keyOf(url)));
      await file.writeAsBytes([1, 2, 3, 4]);
      expect(await ComicImageCache.exists(url), isTrue);
    });

    test('download 命中已有缓存时不重复下载（用不可达地址验证）', () async {
      final dir = await ComicImageCache.directory();
      const url = 'https://127.0.0.1:1/cached.jpg';
      final file = File(p.join(dir.path, ComicImageCache.keyOf(url)));
      await file.writeAsBytes([1, 2, 3]);
      // 若真去请求 127.0.0.1:1 必然失败；返回 true 说明走的是缓存命中分支。
      expect(await ComicImageCache.download(url), isTrue);
    });

    test('空文件不算有效缓存：download 会重新尝试（此处必然失败）', () async {
      final dir = await ComicImageCache.directory();
      const url = 'https://127.0.0.1:1/empty.jpg';
      final file = File(p.join(dir.path, ComicImageCache.keyOf(url)));
      await file.writeAsBytes([]);
      expect(
        await ComicImageCache.download(
          url,
          timeout: const Duration(milliseconds: 500),
        ),
        isFalse,
      );
    });

    test('sizeBytes 会统计缓存文件大小', () async {
      final dir = await ComicImageCache.directory();
      final file = File(p.join(dir.path, ComicImageCache.keyOf('u1')));
      await file.writeAsBytes(List.filled(1234, 7));
      expect(await ComicImageCache.sizeBytes(), 1234);
    });

    test('clear(olderThan:) 只删除过期的缓存文件', () async {
      final dir = await ComicImageCache.directory();
      final fresh = File(p.join(dir.path, ComicImageCache.keyOf('fresh')));
      final old = File(p.join(dir.path, ComicImageCache.keyOf('old')));
      await fresh.writeAsBytes([1]);
      await old.writeAsBytes([1]);
      // 把 old 的修改时间改到 10 天前。
      final tenDaysAgo = DateTime.now().subtract(const Duration(days: 10));
      await old.setLastModified(tenDaysAgo);

      await ComicImageCache.clear(olderThan: const Duration(days: 7));

      expect(fresh.existsSync(), isTrue, reason: '未过期的缓存应保留');
      expect(old.existsSync(), isFalse, reason: '过期缓存应被清理');
    });

    test('clear() 无参时清空全部缓存', () async {
      final dir = await ComicImageCache.directory();
      final a = File(p.join(dir.path, ComicImageCache.keyOf('a')));
      final b = File(p.join(dir.path, ComicImageCache.keyOf('b')));
      await a.writeAsBytes([1]);
      await b.writeAsBytes([1]);
      await ComicImageCache.clear();
      expect(a.existsSync(), isFalse);
      expect(b.existsSync(), isFalse);
    });

    test('★ trimToLimit(0) 表示不限制，不删任何文件', () async {
      final dir = await ComicImageCache.directory();
      final a = File(p.join(dir.path, ComicImageCache.keyOf('a')));
      await a.writeAsBytes(List.filled(100, 1));

      expect(await ComicImageCache.trimToLimit(0), 0);
      expect(a.existsSync(), isTrue);
    });

    test('★ 超过上限时按 LRU 删除最久未使用的文件，直到回到上限内',
        () async {
      final dir = await ComicImageCache.directory();
      final old = File(p.join(dir.path, ComicImageCache.keyOf('old')));
      final mid = File(p.join(dir.path, ComicImageCache.keyOf('mid')));
      final fresh = File(p.join(dir.path, ComicImageCache.keyOf('fresh')));
      await old.writeAsBytes(List.filled(1000, 1));
      await mid.writeAsBytes(List.filled(1000, 1));
      await fresh.writeAsBytes(List.filled(1000, 1));
      // 修改时间：old < mid < fresh
      await old.setLastModified(
          DateTime.now().subtract(const Duration(days: 3)));
      await mid.setLastModified(
          DateTime.now().subtract(const Duration(days: 2)));
      await fresh.setLastModified(
          DateTime.now().subtract(const Duration(days: 1)));

      // 上限 2500 字节 → 必须删掉至少 1 个（最旧的 old）。
      final removed = await ComicImageCache.trimToLimit(2500);

      expect(removed, greaterThanOrEqualTo(1));
      expect(old.existsSync(), isFalse, reason: '最久未使用的先被删');
      expect(fresh.existsSync(), isTrue, reason: '最新使用的应保留');
      expect(await ComicImageCache.sizeBytes(), lessThanOrEqualTo(2500));
    });

    test('★ 回收会保护当前正在读的那一话', () async {
      final dir = await ComicImageCache.directory();
      const protectedUrl = 'https://img.test/protected.jpg';
      final protected =
          File(p.join(dir.path, ComicImageCache.keyOf(protectedUrl)));
      final other = File(p.join(dir.path, ComicImageCache.keyOf('other')));
      await protected.writeAsBytes(List.filled(1000, 1));
      await other.writeAsBytes(List.filled(1000, 1));
      // 让被保护的文件「更旧」，如果不保护就会被优先删掉。
      await protected.setLastModified(
          DateTime.now().subtract(const Duration(days: 5)));

      await ComicImageCache.trimToLimit(
        1200,
        protectedUrls: {protectedUrl},
      );

      expect(protected.existsSync(), isTrue,
          reason: '正在读的那一话不能被回收');
      expect(other.existsSync(), isFalse);
    });

    test('★ 回收会跳过写了一半的 .part 临时文件', () async {
      final dir = await ComicImageCache.directory();
      final part = File(p.join(dir.path, 'something.jpg.part'));
      await part.writeAsBytes(List.filled(5000, 1));

      // 上限很小，但 .part 不计入总量也不被删除。
      final removed = await ComicImageCache.trimToLimit(10);

      expect(removed, 0);
      expect(part.existsSync(), isTrue);
    });
  });
}
