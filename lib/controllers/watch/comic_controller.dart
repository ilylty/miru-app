import 'dart:async';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:miru_app/data/providers/anilist_provider.dart';
import 'package:miru_app/data/services/comic_cache_service.dart';
import 'package:miru_app/data/services/comic_image_cache.dart';
import 'package:miru_app/models/index.dart';
import 'package:miru_app/controllers/watch/reader_controller.dart';
import 'package:miru_app/data/services/database_service.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:extended_image/extended_image.dart';
import 'package:miru_app/utils/comic_cache_config_store.dart';
import 'package:miru_app/utils/miru_storage.dart';

/// 漫画阅读控制器。
///
/// 相比原版增加了两块能力：
/// 1. **漫画缓存系统**（生产者 + 消费者，全部可配置）
///    - 生产者：[ComicCacheService] 按配置自动缓存「当前话之后的 n 话」，
///      每话间隔 l 秒、话内图片间隔 m 秒；
///    - 消费者：用户实际阅读的章节同样入队缓存，间隔同样受配置控制。
///
/// 2. **条漫无感切换**
///    - 相邻章节被拼进同一条连续图片流（[ComicStripModel] + `ComicStripView`）；
///    - 滚动跨话只更新「当前话」状态，**不触发内容重载**，
///      因此没有白屏、没有位置突变、没有滚动惯性中断。
class ComicController extends ReaderController<ExtensionMangaWatch> {
  ComicController({
    required super.title,
    required super.playList,
    required super.detailUrl,
    required super.playIndex,
    required super.episodeGroupId,
    required super.runtime,
    required super.cover,
    required super.anilistID,
    ComicCacheConfig? config,
    ComicCacheService? cacheService,
    MangaReadMode? initialReadMode,
  }) {
    _initialReadMode = initialReadMode;
    cacheConfig = config ?? ComicCacheConfigStore.load();
    strip = ComicStripModel(
      currentChapter: playIndex,
      totalChapters: playList.length,
    )..applyConfig(cacheConfig);
    seamlessEnabled.value = cacheConfig.seamlessChapterSwitch;
    this.cacheService = cacheService ??
        ComicCacheService(
          config: cacheConfig,
          chapterLoader: _loadChapterForCache,
          fetcher: (url, headers) =>
              ComicImageCache.download(url, headers: headers),
          cacheProbe: (url) => ComicImageCache.exists(url),
          trimmer: (maxBytes, protectedUrls) =>
              ComicImageCache.trimToLimit(
            maxBytes,
            protectedUrls: protectedUrls,
          ),
        );
    // 设置页改了缓存配置：立即生效（不用重进阅读器）。
    // 在构造器里注册，确保无论是否经过 GetX 的 onInit 都能生效。
    ComicCacheConfigStore.revision.addListener(_onCacheConfigChanged);
  }

  Map<String, MangaReadMode> readmode = {
    'standard': MangaReadMode.standard,
    'rightToLeft': MangaReadMode.rightToLeft,
    'webTonn': MangaReadMode.webTonn,
  };
  final readType = MangaReadMode.standard.obs;

  /// 全局默认阅读模式（懒读取；存储未就绪时退回 standard）。
  String get setting {
    try {
      return (MiruStorage.getSetting(SettingKey.readingMode) as String?) ??
          'standard';
    } catch (_) {
      return 'standard';
    }
  }

  final currentScale = 1.0.obs;

  /// 当前页码（条漫连续流模式下为当前话内的图片下标）。
  final currentPage = 0.obs;

  final pageController = ExtendedPageController().obs;
  final itemPositionsListener = ItemPositionsListener.create();
  final itemScrollController = ItemScrollController();
  final scrollOffsetController = ScrollOffsetController();

  // 是否已经恢复上次阅读
  final isRecover = false.obs;

  final isZoom = false.obs;

  // ---------------------------------------------------------------------------
  // 漫画缓存 / 条漫无感切换
  // ---------------------------------------------------------------------------

  /// 当前生效的漫画缓存配置（设置页修改后调用 [reloadCacheConfig] 刷新）。
  late ComicCacheConfig cacheConfig;

  /// 连续流模型（渲染窗口最多 [ComicStripModel.defaultMaxWindowChapters] 话）。
  late final ComicStripModel strip;

  /// 缓存调度器（生产端 + 消费端）。
  late final ComicCacheService cacheService;

  /// 初始阅读模式（由调用方指定时优先，用于恢复每部作品的上次模式）。
  MangaReadMode? _initialReadMode;

  /// 初始化完成信号（初始化包含异步的存储/章节装载，调用方可 await）。
  Future<void>? _initFuture;

  /// 幂等初始化：由 [onInit] 触发，也可由测试/外部主动 await。
  Future<void> ensureInitialized() => _initFuture ??= _bootstrap();

  /// 连续流内容版本号；变化时重建列表。
  final stripRevision = 0.obs;

  /// 章节加载失败信息（当前话的失败优先，否则回退到最近一次失败）。
  String get stripError {
    final current = _chapterErrors[index.value];
    if (current != null) {
      return current;
    }
    return _lastChapterError;
  }

  /// 各章节的失败原因（成功装载时会移除）。
  final Map<int, String> _chapterErrors = <int, String>{};
  String _lastChapterError = '';

  /// 请求条漫视图在下一帧把当前话对齐到顶部（用户主动跳章时）。
  final jumpChapterRequest = 0.obs;

  /// 是否处于「条漫 + 无感切换」路径。
  bool get isSeamlessStrip =>
      readType.value == MangaReadMode.webTonn && seamlessEnabled.value;

  /// [isSeamlessStrip] 的可观察副本。
  ///
  /// 阅读器视图靠它来响应「设置里开关了无感切换」并即时切换渲染路径。
  final seamlessEnabled = true.obs;

  /// 滚动引起的章节变化不应触发内容重载 —— 这是「无感」的核心。
  bool _suppressReload = false;

  /// 已经同步到 [watchData] 的章节序号，避免重复写入触发历史恢复。
  int _syncedChapterIndex = -1;

  /// 串行化扩展 watch 调用：QuickJS 运行时不适合并发求值。
  Future<void> _loadChain = Future<void>.value();

  /// 正在装载中的章节，避免同一个章节被并发装载两次。
  final Map<int, Future<StripChapter?>> _pendingChapterLoads =
      <int, Future<StripChapter?>>{};

  /// 构造器里注册的配置变更监听（保存 tear-off，确保 onClose 能正确移除）。
  late final VoidCallback _onCacheConfigChanged = reloadCacheConfig;

  /// 滚动位置上报节流，避免每帧都做章节切换判断。
  Timer? _positionThrottle;
  ItemPosition? _pendingPosition;
  static const Duration _positionThrottleInterval =
      Duration(milliseconds: 120);

  @override
  void onInit() {
    ensureInitialized();
    itemPositionsListener.itemPositions.addListener(_onPositionsChanged);

    ever(readType, (callback) async {
      if (callback == MangaReadMode.webTonn && seamlessEnabled.value) {
        await ensureStripWindow(index.value);
      } else {
        // 从条漫连续流切回分页模式：重新加载当前话的单页图片。
        await super.getContent();
      }
      _jumpPage(currentPage.value);
      // 保存设置
      try {
        await DatabaseService.setMangaReaderType(
          super.detailUrl,
          callback,
        );
      } catch (_) {
        // 存储不可用不影响阅读。
      }
    });
    // 如果切换章节，重置当前页码
    ever(super.index, (callback) {
      currentPage.value = 0;
    });
    ever(super.watchData, (callback) async {
      if (isRecover.value || callback == null) {
        return;
      }

      isRecover.value = true;
      // 获取上次阅读的页码
      History? history;
      try {
        history = await DatabaseService.getHistoryByPackageAndUrl(
          super.runtime.extension.package,
          super.detailUrl,
        );
      } catch (_) {
        // 数据库不可用（如初始化早期）时不影响阅读。
        return;
      }

      if (history == null ||
          history.progress.isEmpty ||
          episodeGroupId != history.episodeGroupId ||
          history.episodeId != index.value) {
        return;
      }
      currentPage.value = int.parse(history.progress);
      _jumpPage(currentPage.value);
    });
    super.onInit();
  }

  /// 初始化：先定阅读模式（含存储恢复），再按需预装载连续流窗口。
  Future<void> _bootstrap() async {
    await _initSetting();
    if (isSeamlessStrip) {
      await ensureStripWindow(index.value);
    }
  }

  /// 重新读取配置（设置页修改后调用）。
  void reloadCacheConfig() {
    cacheConfig = ComicCacheConfigStore.load();
    seamlessEnabled.value = cacheConfig.seamlessChapterSwitch;
    strip.applyConfig(cacheConfig);
    cacheService.updateConfig(cacheConfig);
    if (cacheConfig.seamlessChapterSwitch) {
      unawaited(ensureStripWindow(index.value, forceReload: true));
    } else {
      stripRevision.value++;
    }
  }

  // ---------------------------------------------------------------------------
  // 章节装载
  // ---------------------------------------------------------------------------

  /// 串行执行扩展调用，避免并发求值导致 QuickJS 运行时状态错乱。
  Future<T> _serialize<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _loadChain = _loadChain.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  /// 装载单个章节；已装载则直接返回。**不会**触发列表重建。
  ///
  /// 同一个章节的并发请求会被合并（只真正装载一次）。
  Future<StripChapter?> loadStripChapter(int chapterIndex) {
    if (chapterIndex < 0 || chapterIndex >= playList.length) {
      return Future<StripChapter?>.value(null);
    }
    final existing = strip.chapterAt(chapterIndex);
    if (existing != null && existing.urls.isNotEmpty) {
      return Future<StripChapter?>.value(existing);
    }
    final pending = _pendingChapterLoads[chapterIndex];
    if (pending != null) {
      return pending;
    }
    final future = _loadStripChapterOnce(chapterIndex);
    _pendingChapterLoads[chapterIndex] = future;
    return future.whenComplete(() {
      _pendingChapterLoads.remove(chapterIndex);
    });
  }

  Future<StripChapter?> _loadStripChapterOnce(int chapterIndex) async {
    try {
      final raw = await _serialize(
        () => runtime.watch(playList[chapterIndex].url),
      );
      // 运行时返回类型不符（扩展被换掉 / 返回结构异常）时当作加载失败，
      // 而不是让类型转换异常把整个装载流程打断。
      final data = raw is ExtensionMangaWatch ? raw : null;
      if (data == null || data.urls.isEmpty) {
        _chapterErrors[chapterIndex] = 'empty chapter ${chapterIndex + 1}';
        _lastChapterError = _chapterErrors[chapterIndex]!;
        return null;
      }
      final chapter = StripChapter(
        index: chapterIndex,
        urls: List<String>.from(data.urls),
        title: playList[chapterIndex].name,
        headers: data.headers,
      );
      strip.putChapter(chapter);
      // 该话已成功：清掉它的失败记录，但不影响其它话的错误。
      _chapterErrors.remove(chapterIndex);
      return chapter;
    } catch (e) {
      _chapterErrors[chapterIndex] = e.toString();
      _lastChapterError = e.toString();
      return null;
    }
  }

  /// 缓存服务使用的按需加载器。
  Future<ComicCacheChapterTask?> _loadChapterForCache(int chapterIndex) async {
    final chapter = await loadStripChapter(chapterIndex);
    if (chapter == null) {
      return null;
    }
    return ComicCacheChapterTask(
      chapterIndex: chapter.index,
      urls: chapter.urls,
      headers: chapter.headers,
    );
  }

  /// 同步连续流窗口到以 [center] 为中心的位置。
  ///
  /// ★ 无感切换的关键：**窗口边界不能是「墙」**。
  ///
  /// 用户一路下滑（或一路回拉）时，必须在真正碰到边界之前就把更远的
  /// 章节装载好，否则滚动会停在列表尽头，看起来就像卡死。
  /// 所以这里每次都会把「当前话 ± 余量」的范围补齐，
  /// 而**只有窗口里有哪些章节真的变了才重建列表**——
  /// 普通滚动（内容已就位）既不会重建、也不会等待网络，
  /// 滚动位置、已解码图片、滚动惯性全部保留。
  Future<void> ensureStripWindow(
    int center, {
    bool forceReload = false,
  }) async {
    if (!seamlessEnabled.value) {
      return;
    }
    final clamped = center.clamp(0, playList.length - 1);
    strip.updateTotalChapters(playList.length);
    strip.jumpToChapter(clamped);

    final signatureBefore = strip.windowSignature;

    // 「必须覆盖」的范围：当前话 ± span。
    final required = strip.prefetchRange();
    final requiredMissing =
        required.where((i) => !strip.hasChapter(i)).toList();

    // 只有必须覆盖的范围出现缺口时才真的装载。
    // 已经在范围内的普通滚动（包括往回拉一话）不会触发任何装载，
    // 也就不会重建列表 —— 这是「无感」的关键。
    if (requiredMissing.isNotEmpty) {
      // 一次补齐到「当前话 ± (span + 余量)」：多留一点余量，
      // 这样用户再往前滑/回拉一话时不需要重新装载，
      // 也不会在窗口边界上撞停（边界不能是墙）。
      final desired = strip.prefetchRange(
        forwardExtra: ComicStripModel.prefetchMargin,
        backwardExtra: ComicStripModel.prefetchMargin,
      );
      final missing = desired.where((i) => !strip.hasChapter(i)).toList();
      // 中心章节优先，其次按距离排序。
      missing.sort((a, b) => (a - clamped).abs().compareTo((b - clamped).abs()));
      await Future.wait(missing.map(loadStripChapter));
      strip.pruneOutsideWindow();
    }

    // 只有「窗口里的章节集合」变化时才重建列表。
    if (forceReload || strip.windowSignature != signatureBefore) {
      stripRevision.value++;
    }
    _syncWatchData();
    _scheduleProducerCache();
    _scheduleConsumerCache();
  }

  /// 让 [watchData] 与「当前话」保持一致（历史记录、页码统计、headers 都依赖它）。
  void _syncWatchData() {
    final chapter = strip.chapterAt(index.value);
    if (chapter == null || chapter.urls.isEmpty) {
      return;
    }
    if (_syncedChapterIndex == chapter.index) {
      return;
    }
    _syncedChapterIndex = chapter.index;
    watchData.value = ExtensionMangaWatch(
      urls: chapter.urls,
      headers: chapter.headers,
    );
  }

  /// 滚动位置监听（节流）：驱动「当前话」切换与窗口滑动。
  void _onPositionsChanged() {
    final positions = itemPositionsListener.itemPositions.value;
    if (positions.isEmpty) {
      return;
    }
    _pendingPosition = positions.reduce(
      (a, b) => a.itemLeadingEdge < b.itemLeadingEdge ? a : b,
    );
    if (_positionThrottle?.isActive ?? false) {
      return;
    }
    _positionThrottle = Timer(_positionThrottleInterval, () {
      final pending = _pendingPosition;
      if (pending != null) {
        _applyPosition(pending);
      }
    });
  }

  void _applyPosition(ItemPosition position) {
    if (!isSeamlessStrip) {
      return;
    }
    final items = strip.items;
    if (items.isEmpty) {
      return;
    }
    final itemIndex = position.index.clamp(0, items.length - 1);
    onTopItemChanged(items[itemIndex]);
  }

  /// 视口顶部条目变化时的处理 —— 滚动跨话的核心逻辑。
  ///
  /// ★ 无感切换：
  ///   1. 只更新「当前话」状态，**不触发 getContent 重载**，
  ///      因为相邻章节的内容已经在同一条连续列表里了；
  ///   2. 无论当前话有没有变，都要检查窗口是否需要向两侧延伸。
  ///      否则用户一路回拉时会停在窗口边界，看起来就是「卡死」。
  ///      [ensureStripWindow] 在没有需要补的章节时几乎无开销
  ///      （不重建列表、不等待网络）。
  void onTopItemChanged(StripItem item) {
    if (!isSeamlessStrip) {
      return;
    }
    currentPage.value = item.imageIndex;
    if (item.chapterIndex != index.value) {
      _suppressReload = true;
      index.value = item.chapterIndex;
      _suppressReload = false;
      _syncWatchData();
    }
    // 即使当前话没变，也要让窗口跟着视口走（否则会在边界处滑不动）。
    unawaited(ensureStripWindow(item.chapterIndex));
  }

  // ---------------------------------------------------------------------------
  // 生产端 / 消费端缓存
  // ---------------------------------------------------------------------------

  /// 生产端：按配置把「当前话之后的 n 话」排入缓存队列。
  void _scheduleProducerCache() {
    if (!cacheConfig.enabled) {
      return;
    }
    cacheService.scheduleFollowingChapters(
      currentChapterIndex: index.value,
      totalChapters: playList.length,
    );
    // 已经远离的章节不再浪费时间缓存。
    cacheService.retainChapters(strip.prefetchRange().toSet());
  }

  /// 消费端：用户实际阅读的章节顺带缓存（间隔 m 由服务统一控制）。
  void _scheduleConsumerCache() {
    if (!cacheConfig.enabled || !cacheConfig.cacheOnRead) {
      return;
    }
    final chapter = strip.chapterAt(index.value);
    if (chapter == null || chapter.urls.isEmpty) {
      return;
    }
    cacheService.scheduleChapterTask(
      ComicCacheChapterTask(
        chapterIndex: chapter.index,
        urls: chapter.urls,
        headers: chapter.headers,
      ),
    );
  }

  /// 当前缓存状态（供 UI 展示 / 测试断言）。
  ComicCacheStats get cacheStats => cacheService.stats;

  // ---------------------------------------------------------------------------
  // 内容加载
  // ---------------------------------------------------------------------------

  @override
  getContent() async {
    if (!isSeamlessStrip) {
      return super.getContent();
    }
    // 滚动引起的章节变化：内容已经在连续流里，无需重载（无感切换的关键）。
    if (_suppressReload) {
      return;
    }
    error.value = '';
    try {
      await ensureStripWindow(index.value);
      final chapter = strip.chapterAt(index.value);
      if (chapter == null || chapter.urls.isEmpty) {
        final reason = stripError;
        error.value = reason.isEmpty ? 'common.error'.tr : reason;
        return;
      }
      // 用户主动跳章：请求视图在下一帧把该话对齐到顶部。
      jumpChapterRequest.value++;
    } catch (e) {
      error.value = e.toString();
    }
  }

  // ---------------------------------------------------------------------------
  // 设置 / 跳页 / 翻页
  // ---------------------------------------------------------------------------

  _initSetting() async {
    final base = _initialReadMode ?? readmode[setting] ?? MangaReadMode.standard;
    readType.value = base;
    try {
      readType.value = await DatabaseService.getMnagaReaderType(
        super.detailUrl,
        base,
      );
    } catch (_) {
      // 数据库不可用时退回到传入/全局默认阅读模式，不影响阅读本身。
      readType.value = base;
    }
  }

  _jumpPage(int page) async {
    if (readType.value == MangaReadMode.webTonn) {
      if (seamlessEnabled.value) {
        await ensureStripWindow(index.value);
        final offset = strip.itemOffsetOfChapter(index.value);
        if (offset != null && itemScrollController.isAttached) {
          itemScrollController.jumpTo(index: offset + page);
        }
        return;
      }
      if (itemScrollController.isAttached) {
        itemScrollController.jumpTo(
          index: page,
        );
      }
      return;
    }
    if (pageController.value.hasClients) {
      pageController.value.jumpToPage(page);
      return;
    }
    pageController.value = ExtendedPageController(initialPage: page);
  }

  // 下一页
  @override
  void nextPage() {
    if (readType.value != MangaReadMode.webTonn) {
      pageController.value.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.ease,
      );
    } else {
      scrollOffsetController.animateScroll(
        duration: const Duration(milliseconds: 100),
        curve: Curves.ease,
        offset: 200.0,
      );
    }
  }

  // 上一页
  @override
  void previousPage() {
    if (readType.value != MangaReadMode.webTonn) {
      pageController.value.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.ease,
      );
    } else {
      scrollOffsetController.animateScroll(
        duration: const Duration(milliseconds: 100),
        curve: Curves.ease,
        offset: -200.0,
      );
    }
  }

  onKey(RawKeyEvent event) {
    // 按下 ctrl
    isZoom.value = event.isControlPressed;
    // 上下
    if (event.isKeyPressed(LogicalKeyboardKey.arrowUp)) {
      if (readType.value == MangaReadMode.webTonn) {
        return previousPage();
      }
    }
    if (event.isKeyPressed(LogicalKeyboardKey.arrowDown)) {
      if (readType.value == MangaReadMode.webTonn) {
        return nextPage();
      }
    }

    if (event.isKeyPressed(LogicalKeyboardKey.arrowLeft)) {
      if (readType.value == MangaReadMode.rightToLeft) {
        return nextPage();
      }
      previousPage();
    }

    if (event.isKeyPressed(LogicalKeyboardKey.arrowRight)) {
      if (readType.value == MangaReadMode.rightToLeft) {
        return previousPage();
      }
      nextPage();
    }
  }

  @override
  void onClose() {
    ComicCacheConfigStore.revision
        .removeListener(_onCacheConfigChanged);
    _positionThrottle?.cancel();
    cacheService.dispose();
    // 保存历史与同步进度都可能因存储/网络不可用而失败，
    // 关闭流程绝不能被异常中断（否则会卡住阅读器退出）。
    unawaited(_saveStateOnClose());
    super.onClose();
  }

  Future<void> _saveStateOnClose() async {
    try {
      final data = watchData.value;
      if (data != null) {
        await addHistory(
          currentPage.value.toString(),
          data.urls.length.toString(),
        );
      }
    } catch (_) {
      // 忽略存储失败。
    }
    try {
      if (MiruStorage.getSetting(SettingKey.autoTracking) == true &&
          anilistID != "") {
        await AniListProvider.editList(
          status: AnilistMediaListStatus.current,
          progress: playIndex + 1,
          mediaId: anilistID,
        );
      }
    } catch (_) {
      // 忽略网络失败。
    }
  }
}
