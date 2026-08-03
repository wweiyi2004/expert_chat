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

/// Bottom sheet: recent gallery thumbs +「从文件选择」.
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

  final permission = await PhotoManager.requestPermissionExtend();
  if (!permission.isAuth && !permission.hasAccess) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
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
  final _selected = <AssetEntity>{};
  List<AssetEntity> _assets = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final paths = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        onlyAll: true,
      );
      if (paths.isEmpty) {
        setState(() {
          _loading = false;
          _error = '相册为空';
        });
        return;
      }
      final recent = await paths.first.getAssetListPaged(page: 0, size: 80);
      if (!mounted) return;
      setState(() {
        _assets = recent;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载相册失败：$e';
      });
    }
  }

  void _toggle(AssetEntity asset) {
    setState(() {
      if (_selected.contains(asset)) {
        _selected.remove(asset);
      } else if (_selected.length >= widget.maxCount) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('最多选择 ${widget.maxCount} 张'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        _selected.add(asset);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final height = MediaQuery.sizeOf(context).height * 0.62;
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Text(
                  '最近照片',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(
                    context,
                    const RecentPhotoPickResult.files(),
                  ),
                  child: const Text('从文件选择'),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(child: Text(_error!))
                : GridView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 6,
                      crossAxisSpacing: 6,
                    ),
                    itemCount: _assets.length,
                    itemBuilder: (context, index) {
                      final asset = _assets[index];
                      final selected = _selected.contains(asset);
                      return _AssetTile(
                        asset: asset,
                        selected: selected,
                        onTap: () => _toggle(asset),
                      );
                    },
                  ),
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
                                _selected.toList(growable: false),
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

class _AssetTile extends StatelessWidget {
  const _AssetTile({
    required this.asset,
    required this.selected,
    required this.onTap,
  });

  final AssetEntity asset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<Uint8List?>(
            future: asset.thumbnailDataWithSize(
              const ThumbnailSize.square(200),
            ),
            builder: (context, snap) {
              final data = snap.data;
              if (data == null) {
                return ColoredBox(color: scheme.surfaceContainerHighest);
              }
              return Image.memory(data, fit: BoxFit.cover);
            },
          ),
          Positioned(
            top: 4,
            right: 4,
            child: Icon(
              selected ? Icons.check_circle : Icons.circle_outlined,
              color: selected ? scheme.primary : Colors.white,
              shadows: const [Shadow(blurRadius: 4, color: Colors.black54)],
            ),
          ),
        ],
      ),
    );
  }
}

/// Load original (or compressed) bytes for an [AssetEntity].
Future<Uint8List?> loadAssetImageBytes(AssetEntity asset) async {
  return asset.originBytes;
}
