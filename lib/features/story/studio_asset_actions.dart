import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/story_models.dart';
import '../../domain/story/studio_asset_io.dart';
import '../../state/character_controller.dart';
import '../../state/world_info_controller.dart';

final studioAssetIoProvider = Provider<StudioAssetIo>((_) => StudioAssetIo());

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
}

/// Saves each imported card individually, tolerating per-item failures, and
/// reports how many actually landed so a mid-batch failure cannot masquerade
/// as a complete one (and the user knows a re-import may duplicate).
Future<void> importCharactersAction(
  BuildContext context,
  WidgetRef ref,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final cards = await ref.read(studioAssetIoProvider).importCharacters();
    if (cards == null) return;
    var ok = 0;
    Object? firstError;
    for (final card in cards) {
      try {
        await ref.read(characterCardsProvider.notifier).save(card);
        ok++;
      } catch (e) {
        firstError ??= e;
      }
    }
    if (!context.mounted) return;
    final failed = cards.length - ok;
    if (failed == 0) {
      _toast(context, '已导入 ${cards.length} 张角色卡');
    } else {
      _toast(context, '导入完成：成功 $ok 张，失败 $failed 张（$firstError）');
    }
  } catch (e) {
    if (!context.mounted) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text('导入失败：$e'), behavior: SnackBarBehavior.floating),
      );
      return;
    }
    _toast(context, '导入失败：$e');
  }
}

Future<void> exportAllCharactersAction(
  BuildContext context,
  WidgetRef ref,
) async {
  final cards = ref.read(characterCardsProvider).value ?? const [];
  if (cards.isEmpty) {
    _toast(context, '还没有可导出的角色卡');
    return;
  }
  try {
    final path = await ref.read(studioAssetIoProvider).exportCharacters(cards);
    if (path == null || !context.mounted) return;
    _toast(context, '已导出 ${cards.length} 张角色卡');
  } catch (e) {
    if (!context.mounted) return;
    _toast(context, '导出失败：$e');
  }
}

Future<void> exportOneCharacterAction(
  BuildContext context,
  WidgetRef ref,
  CharacterCard card,
) async {
  try {
    final path = await ref.read(studioAssetIoProvider).exportCharacter(card);
    if (path == null || !context.mounted) return;
    _toast(context, '已导出「${card.name}」');
  } catch (e) {
    if (!context.mounted) return;
    _toast(context, '导出失败：$e');
  }
}

/// Saves each imported entry individually, tolerating per-item failures, and
/// reports how many actually landed so a mid-batch failure cannot masquerade
/// as a complete one (and the user knows a re-import may duplicate).
Future<void> importWorldInfoAction(BuildContext context, WidgetRef ref) async {
  try {
    final entries = await ref.read(studioAssetIoProvider).importWorldInfo();
    if (entries == null) return;
    var ok = 0;
    Object? firstError;
    for (final entry in entries) {
      try {
        await ref.read(worldInfoProvider.notifier).save(entry);
        ok++;
      } catch (e) {
        firstError ??= e;
      }
    }
    if (!context.mounted) return;
    final failed = entries.length - ok;
    if (failed == 0) {
      _toast(context, '已导入 ${entries.length} 条世界书');
    } else {
      _toast(context, '导入完成：成功 $ok 条，失败 $failed 条（$firstError）');
    }
  } catch (e) {
    if (!context.mounted) return;
    _toast(context, '导入失败：$e');
  }
}

Future<void> exportAllWorldInfoAction(
  BuildContext context,
  WidgetRef ref,
) async {
  final entries = ref.read(worldInfoProvider).value ?? const [];
  if (entries.isEmpty) {
    _toast(context, '还没有可导出的世界书条目');
    return;
  }
  try {
    final path = await ref
        .read(studioAssetIoProvider)
        .exportWorldInfoEntries(entries);
    if (path == null || !context.mounted) return;
    _toast(context, '已导出 ${entries.length} 条世界书');
  } catch (e) {
    if (!context.mounted) return;
    _toast(context, '导出失败：$e');
  }
}

Future<void> exportOneWorldInfoAction(
  BuildContext context,
  WidgetRef ref,
  WorldInfoEntry entry,
) async {
  try {
    final path = await ref
        .read(studioAssetIoProvider)
        .exportWorldInfoEntry(entry);
    if (path == null || !context.mounted) return;
    final title = entry.title.trim();
    _toast(context, '已导出「${title.isEmpty ? '未命名条目' : title}」');
  } catch (e) {
    if (!context.mounted) return;
    _toast(context, '导出失败：$e');
  }
}
