import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:miru_app/models/index.dart';
import 'package:miru_app/controllers/watch/comic_controller.dart';
import 'package:miru_app/utils/i18n.dart';
import 'package:miru_app/views/pages/watch/reader/comic/comic_strip_view.dart';
import 'package:miru_app/views/widgets/button.dart';
import 'package:miru_app/views/widgets/cache_network_image.dart';
import 'package:miru_app/views/widgets/platform_widget.dart';
import 'package:miru_app/views/widgets/progress.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:extended_image/extended_image.dart';

class ComicReaderContent extends StatefulWidget {
  const ComicReaderContent(this.tag, {super.key});
  final String tag;

  @override
  State<ComicReaderContent> createState() => _ComicReaderContentState();
}

class _ComicReaderContentState extends State<ComicReaderContent> {
  @override
  void initState() {
    super.initState();
  }

  late final _c = Get.find<ComicController>(tag: widget.tag);

  // 按下数量
  final List<int> _pointer = [];

  _buildPlaceholder(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;
    return SizedBox(
      width: width,
      height: height,
      child: const Center(
        child: Center(
          child: ProgressRing(),
        ),
      ),
    );
  }

  _buildDisplay(Widget child) {
    return Stack(
      children: [
        child,
        Positioned(
          bottom: 0,
          child: Container(
            color: Colors.black.withAlpha(200),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
            child: Obx(
              () => Text(
                "${_c.currentPage.value + 1}/${_c.watchData.value?.urls.length ?? 0}",
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
            ),
          ),
        ),
        // 条漫连续流：额外显示当前话与缓存进度，方便确认「无感切换」生效。
        Positioned(
          bottom: 0,
          right: 0,
          child: Obx(() {
            if (!_c.isSeamlessStrip) {
              return const SizedBox.shrink();
            }
            final total = _c.playList.length;
            final stats = _c.cacheStats;
            return Container(
              color: Colors.black.withAlpha(200),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              child: Text(
                '${_c.index.value + 1}/$total'
                '  cached:${stats.cachedChapters}'
                '${stats.queuedChapters > 0 ? ' +${stats.queuedChapters}' : ''}',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            );
          }),
        ),
      ],
    );
  }

  /// 条漫 + 无感切换：相邻章节拼成同一条连续列表。
  ///
  /// 用 [Obx] 依赖 `seamlessEnabled`：用户在设置里关掉「条漫无感切换」时，
  /// 阅读器立刻退回单话滚动，不用重进阅读器。
  Widget _buildSeamlessStrip(double maxWidth, List<String> images) => Obx(
        () => _c.seamlessEnabled.value
            ? ComicStripView(controller: _c)
            : _buildPlainWebtoon(maxWidth, images, _c.currentPage.value),
      );

  /// 传统条漫：单话垂直滚动（保留原行为，作为「无感切换」关闭时的回退路径）。
  Widget _buildPlainWebtoon(
    double maxWidth,
    List<String> images,
    int currentPage,
  ) {
    final width = MediaQuery.of(context).size.width;
    final height = MediaQuery.of(context).size.height;
    final viewPadding = maxWidth > 800 ? ((maxWidth - 800) / 2) : 0.0;
    // 防缝出血：让每张图向下多绘制 1 物理像素，相邻图片互相重叠覆盖接缝，
    // 避免分数像素边界（图片高度通常不是整数）在合成时产生抗锯齿细缝。
    final bleed = 1 / MediaQuery.of(context).devicePixelRatio;
    return SizedBox(
      width: width,
      height: height,
      child: Listener(
        onPointerDown: (event) {
          _pointer.add(event.pointer);
          if (_pointer.length == 2) {
            _c.isZoom.value = true;
          }
        },
        onPointerUp: (event) {
          _pointer.remove(event.pointer);
          if (_pointer.length == 1) {
            _c.isZoom.value = false;
          }
        },
        child: InteractiveViewer(
          scaleEnabled: _c.isZoom.value,
          child: ScrollablePositionedList.builder(
            physics:
                _c.isZoom.value ? const NeverScrollableScrollPhysics() : null,
            padding: EdgeInsets.symmetric(horizontal: viewPadding),
            // 关闭每个 item 的独立 RepaintBoundary，让所有图片绘制进同一个
            // layer，消除排列在分数像素边界上的相邻图层之间合成的细缝。
            addRepaintBoundaries: false,
            initialScrollIndex: currentPage,
            itemScrollController: _c.itemScrollController,
            itemPositionsListener: _c.itemPositionsListener,
            scrollOffsetController: _c.scrollOffsetController,
            itemBuilder: (context, index) {
              final url = images[index];
              return CacheNetWorkImagePic(
                url,
                fit: BoxFit.fitWidth,
                placeholder: _buildPlaceholder(context),
                headers: _c.watchData.value?.headers,
                layoutInsets: EdgeInsets.only(bottom: -bleed),
              );
            },
            itemCount: images.length,
          ),
        ),
      ),
    );
  }

  /// 标准 / 从右到左：左右翻页。
  Widget _buildPaged(
    double maxWidth,
    List<String> images,
    MangaReadMode readerType,
  ) {
    final viewPadding = maxWidth > 800 ? ((maxWidth - 800) / 2) : 0.0;
    return ExtendedImageGesturePageView.builder(
      itemCount: images.length,
      reverse: readerType == MangaReadMode.rightToLeft,
      onPageChanged: (index) {
        _c.currentPage.value = index;
      },
      scrollDirection: Axis.horizontal,
      controller: _c.pageController.value,
      itemBuilder: (BuildContext context, int index) {
        final url = images[index];
        return Container(
          padding: EdgeInsets.symmetric(
            horizontal: viewPadding,
          ),
          child: CacheNetWorkImagePic(
            url,
            mode: ExtendedImageMode.gesture,
            key: ValueKey(url),
            fit: BoxFit.contain,
            placeholder: _buildPlaceholder(context),
            headers: _c.watchData.value?.headers,
          ),
        );
      },
    );
  }

  _buildContent() {
    late Color backgroundColor;
    if (isAndroidLayout) {
      backgroundColor = Theme.of(context).colorScheme.background;
    } else {
      backgroundColor = fluent.FluentTheme.of(context).micaBackgroundColor;
    }
    return RawKeyboardListener(
      focusNode: FocusNode(),
      autofocus: true,
      onKey: _c.onKey,
      child: Container(
        color: backgroundColor,
        width: double.infinity,
        child: LayoutBuilder(
          builder: ((context, constraints) {
            final maxWidth = constraints.maxWidth;
            return Obx(() {
              if (_c.error.value.isNotEmpty) {
                return Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(_c.error.value),
                    PlatformButton(
                      child: Text('common.retry'.i18n),
                      onPressed: () {
                        _c.getContent();
                      },
                    )
                  ],
                );
              }

              // 加载中
              if (_c.watchData.value == null) {
                return const Center(child: ProgressRing());
              }

              final images = _c.watchData.value!.urls;
              final readerType = _c.readType.value;

              if (readerType == MangaReadMode.webTonn) {
                // Obx 内部依赖 seamlessEnabled，开关变化时即时切换渲染路径。
                return _buildSeamlessStrip(maxWidth, images);
              }

              // 标准 / 从右到左
              return _buildPaged(maxWidth, images, readerType);
            });
          }),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PlatformBuildWidget(
      androidBuilder: (context) {
        // 阅读时已进入沉浸模式（见 `ReaderController.onInit`），系统栏被隐藏，
        // 所以**不**再包 `SafeArea` —— 否则会白白留下状态栏/小白条那么宽的
        // 黑边，画面无法铺满整屏。
        return Scaffold(
          body: _buildDisplay(
            _buildContent(),
          ),
        );
      },
      desktopBuilder: (context) => _buildDisplay(
        _buildContent(),
      ),
    );
  }
}
