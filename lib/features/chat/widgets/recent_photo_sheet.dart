import 'package:expert_chat/core/app_toast.dart';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

/// Whether the in-app recent-photo grid is available on this platform.
bool get supportsRecentPhotoSheet =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Result of [showRecentPhotoPicker].
class RecentPhotoPickResult {
  const RecentPhotoPickResult.files() : fromFiles = true, assets = const [];

  const RecentPhotoPickResult.assets(this.assets) : fromFiles = false;

  final bool fromFiles;
  final List<AssetEntity> assets;
}

/// Mobile album picker with paged images and an optional file browser.
///
/// Returns null if dismissed; [RecentPhotoPickResult.files] if user wants the
/// system file picker; otherwise selected [AssetEntity]s.
Future<RecentPhotoPickResult?> showRecentPhotoPicker(
  BuildContext context, {
  required int maxCount,
}) async {
  if (!supportsRecentPhotoSheet) {
    return const RecentPhotoPickResult.files();
  }

  final permission = await PhotoManager.requestPermissionExtend(
    requestOption: const PermissionRequestOption(
      androidPermission: AndroidPermission(
        type: RequestType.image,
        mediaLocation: false,
      ),
    ),
  );
  if (!permission.isAuth && !permission.hasAccess) {
    if (context.mounted) {
      AppToastMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('未获得相册权限，将使用系统文件选择器'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    return const RecentPhotoPickResult.files();
  }

  if (!context.mounted) return null;

  return showModalBottomSheet<RecentPhotoPickResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _RecentPhotoSheetBody(maxCount: maxCount),
  );
}

class _RecentPhotoSheetBody extends StatefulWidget {
  const _RecentPhotoSheetBody({required this.maxCount});

  final int maxCount;

  @override
  State<_RecentPhotoSheetBody> createState() => _RecentPhotoSheetBodyState();
}

class _RecentPhotoSheetBodyState extends State<_RecentPhotoSheetBody> {
  final _selected = <String, AssetEntity>{};
  final _scroll = ScrollController();
  List<AssetPathEntity> _albums = const [];
  AssetPathEntity? _album;
  int _generation = 0;
  int _page = 0;
  bool _hasMore = true;
  static const _pageSize = 80;
  List<AssetEntity> _assets = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.extentAfter < 600 && !_loading && _error == null) {
        _loadPage();
      }
    });
    _loadAlbums();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String _albumName(AssetPathEntity album) => album.isAll
      ? '最近图片'
      : switch (album.name.toLowerCase()) {
          'camera' => '相机',
          'screenshots' => '截图',
          'download' || 'downloads' => '下载',
          'wechat' || 'weixin' => '微信',
          _ => album.name,
        };

  Future<void> _loadAlbums() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        hasAll: true,
        filterOption: FilterOptionGroup(
          orders: [
            const OrderOption(type: OrderOptionType.createDate, asc: false),
          ],
        ),
      );
      if (!mounted) return;
      _albums = paths;
      if (paths.isEmpty) {
        setState(() {
          _loading = false;
          _hasMore = false;
        });
        return;
      }
      _switchAlbum(paths.where((p) => p.isAll).firstOrNull ?? paths.first);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '相册暂时无法读取，请重试或从手机文件选择。';
      });
    }
  }

  void _switchAlbum(AssetPathEntity album) {
    _generation++;
    setState(() {
      _album = album;
      _assets = const [];
      _page = 0;
      _hasMore = true;
      _loading = false;
      _error = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _loadPage();
  }

  Future<void> _loadPage() async {
    final album = _album;
    if (_loading || !_hasMore || album == null) return;
    final generation = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await album.getAssetListPaged(page: _page, size: _pageSize);
      if (!mounted || generation != _generation) return;
      final known = _assets.map((a) => a.id).toSet();
      setState(() {
        _assets = [..._assets, ...page.where((a) => known.add(a.id))];
        _page++;
        _hasMore = page.length == _pageSize;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = '图片加载失败，已选图片仍保留。';
      });
    }
  }

  void _toggle(AssetEntity asset) {
    setState(() {
      if (_selected.containsKey(asset.id)) {
        _selected.remove(asset.id);
      } else if (_selected.length >= widget.maxCount) {
        AppToastMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('最多选择 ${widget.maxCount} 张'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        _selected[asset.id] = asset;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final height = MediaQuery.sizeOf(context).height * 0.86;
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: PopupMenuButton<AssetPathEntity>(
                    tooltip: '切换相册',
                    enabled: _albums.isNotEmpty,
                    onSelected: _switchAlbum,
                    itemBuilder: (_) => [
                      for (final album in _albums)
                        CheckedPopupMenuItem(
                          value: album,
                          checked: album.id == _album?.id,
                          child: Text(_albumName(album)),
                        ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              _album == null ? '最近图片' : _albumName(_album!),
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          const Icon(Icons.expand_more),
                        ],
                      ),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(
                    context,
                    const RecentPhotoPickResult.files(),
                  ),
                  child: const Text('手机文件'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text(
              '按时间从新到旧 · 可跨相册选择',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: _assets.isEmpty && _loading
                ? const Center(child: CircularProgressIndicator())
                : _assets.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(_error ?? '此相册暂无可访问的图片，可切换相册或从手机文件选择。'),
                    ),
                  )
                : GridView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 100,
                          mainAxisSpacing: 4,
                          crossAxisSpacing: 4,
                        ),
                    itemCount: _assets.length,
                    itemBuilder: (context, index) {
                      final asset = _assets[index];
                      final order =
                          _selected.keys.toList().indexOf(asset.id) + 1;
                      return _AssetTile(
                        key: ValueKey(asset.id),
                        asset: asset,
                        order: order,
                        onTap: () => _toggle(asset),
                      );
                    },
                  ),
          ),
          if (_error != null)
            TextButton.icon(
              onPressed: _album == null ? _loadAlbums : _loadPage,
              icon: const Icon(Icons.refresh),
              label: Text(_assets.isEmpty ? '重新加载' : '加载失败，点击重试'),
            )
          else if (_assets.isNotEmpty && _hasMore)
            TextButton(
              onPressed: _loading ? null : _loadPage,
              child: Text(_loading ? '正在加载…' : '加载更多图片'),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Text(
                    '已选 ${_selected.length}/${widget.maxCount}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _selected.isEmpty
                        ? null
                        : () => Navigator.pop(
                            context,
                            RecentPhotoPickResult.assets(
                              _selected.values.toList(growable: false),
                            ),
                          ),
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.primary,
                    ),
                    child: Text('下一步 (${_selected.length})'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AssetTile extends StatefulWidget {
  const _AssetTile({
    super.key,
    required this.asset,
    required this.order,
    required this.onTap,
  });

  final AssetEntity asset;
  final int order;
  final VoidCallback onTap;

  @override
  State<_AssetTile> createState() => _AssetTileState();
}

class _AssetTileState extends State<_AssetTile> {
  late final _thumbnail = widget.asset.thumbnailDataWithSize(
    const ThumbnailSize.square(200),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = widget.order > 0;
    return Semantics(
      label: selected ? '图片，已选第 ${widget.order} 张' : '图片，未选择',
      selected: selected,
      button: true,
      child: InkWell(
        onTap: widget.onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FutureBuilder<Uint8List?>(
              future: _thumbnail,
              builder: (context, snap) {
                final data = snap.data;
                if (data == null) {
                  return ColoredBox(
                    color: scheme.surfaceContainerHighest,
                    child: const Icon(Icons.image_outlined),
                  );
                }
                return Image.memory(
                  data,
                  fit: BoxFit.cover,
                  errorBuilder: (_, error, stack) =>
                      const Icon(Icons.broken_image_outlined),
                );
              },
            ),
            if (selected)
              ColoredBox(color: scheme.primary.withValues(alpha: 0.16)),
            Positioned(
              top: 6,
              right: 6,
              child: Container(
                width: 24,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? scheme.primary : Colors.black38,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                child: selected
                    ? Text(
                        '${widget.order}',
                        style: TextStyle(
                          color: scheme.onPrimary,
                          fontWeight: FontWeight.bold,
                        ),
                      )
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Load original (or compressed) bytes for an [AssetEntity].
Future<Uint8List?> loadAssetImageBytes(AssetEntity asset) async {
  return asset.originBytes;
}
