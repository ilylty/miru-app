import 'package:fluent_ui/fluent_ui.dart' as fluent;
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:get/get.dart';
import 'package:miru_app/views/widgets/watch/playlist.dart';
import 'package:miru_app/controllers/watch/reader_controller.dart';
import 'package:miru_app/router/router.dart';
import 'package:miru_app/utils/router.dart';
import 'package:miru_app/views/widgets/platform_widget.dart';
import 'package:window_manager/window_manager.dart';

class ControlPanelHeader<T extends ReaderController> extends StatefulWidget {
  const ControlPanelHeader(
    this.tag, {
    super.key,
    required this.buildSettings,
  });
  final String tag;
  final Widget Function(BuildContext context) buildSettings;

  @override
  State<ControlPanelHeader> createState() => _ControlPanelHeaderState<T>();
}

class _ControlPanelHeaderState<T extends ReaderController>
    extends State<ControlPanelHeader> {
  late final _c = Get.find<T>(tag: widget.tag);
  final fluent.FlyoutController _playListFlayoutcontroller =
      fluent.FlyoutController();
  final fluent.FlyoutController _settingFlayoutcontroller =
      fluent.FlyoutController();

  Widget _buildAndroid(BuildContext context) {
    // ★ 面板背景必须铺到屏幕最顶端（含刘海 / 状态栏区域），只有**内容**
    //   才需要避开刘海。
    //
    // 旧写法是 `SafeArea(child: Container(color: 面板色, child: AppBar))`：
    // `SafeArea` 在带背景色的 `Container` **外面**，于是整个有背景的面板被
    // inset 顶下去，**inset 那一条完全没有背景** —— 沉浸模式下系统栏已隐藏、
    // 下面的漫画还在画，那一条就透出漫画图片，看起来就是
    // 「面板上方是透明的，往下才是菜单栏」。
    //
    // 现在把背景铺在 `SafeArea` **外面**（覆盖到 y=0），`SafeArea` 留在里层
    // 只把内容推下来，两者各司其职。
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        child: SizedBox(
          height: 60,
          child: AppBar(
            title: Text(_c.title),
            actions: [
              IconButton(
                onPressed: () {
                  showModalBottomSheet(
                    context: context,
                    builder: (context) => widget.buildSettings(context),
                  );
                },
                icon: const Icon(Icons.settings),
              ),
              IconButton(
                onPressed: () {
                  showModalBottomSheet(
                    context: context,
                    builder: (context) {
                      return Obx(
                        () => PlayList(
                          title: _c.title,
                          list: _c.playList.map((e) => e.name).toList(),
                          selectIndex: _c.index.value,
                          onChange: (value) {
                            _c.index.value = value;
                            Get.back();
                          },
                        ),
                      );
                    },
                  );
                },
                icon: const Icon(Icons.list),
              ),
            ],
          ),
        ),
      ),
    ).animate().fade();
  }

  Widget _buildDesktop(BuildContext context) {
    return Obx(
      () => Container(
        width: double.infinity,
        height: 40,
        color: fluent.FluentTheme.of(context).micaBackgroundColor,
        padding: const EdgeInsets.only(left: 16),
        child: DragToMoveArea(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              fluent.IconButton(
                icon: const Icon(fluent.FluentIcons.back),
                onPressed: () {
                  RouterUtils.pop();
                },
              ),
              const SizedBox(width: 16),
              Text(_c.title + _c.playList[_c.index.value].name),
              const Spacer(),
              fluent.FlyoutTarget(
                controller: _settingFlayoutcontroller,
                child: fluent.IconButton(
                  icon: const Icon(fluent.FluentIcons.settings),
                  onPressed: () {
                    _settingFlayoutcontroller.showFlyout(builder: (context) {
                      return widget.buildSettings(context);
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),
              fluent.FlyoutTarget(
                controller: _playListFlayoutcontroller,
                child: fluent.IconButton(
                  icon: const Icon(fluent.FluentIcons.collapse_menu),
                  onPressed: () {
                    _playListFlayoutcontroller.showFlyout(builder: (context) {
                      return SizedBox(
                        width: 300,
                        child: Obx(
                          () => PlayList(
                            title: _c.title,
                            list: _c.playList.map((e) => e.name).toList(),
                            selectIndex: _c.index.value,
                            onChange: (value) {
                              _c.index.value = value;
                              router.pop();
                            },
                          ),
                        ),
                      );
                    });
                  },
                ),
              ),
              SizedBox(
                width: 138,
                child: WindowCaption(
                  backgroundColor: Colors.transparent,
                  brightness: fluent.FluentTheme.of(context).brightness,
                ),
              )
            ],
          ),
        ),
      ).animate().fade(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PlatformBuildWidget(
      androidBuilder: _buildAndroid,
      desktopBuilder: _buildDesktop,
    );
  }
}
