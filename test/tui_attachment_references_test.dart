import 'dart:convert';
import 'dart:io';

import 'package:expert_chat/core/providers.dart';
import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/chat/request_context_builder.dart';
import 'package:expert_chat/features/tui_bridge/attachment_imports.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory directory;
  late ProviderContainer container;
  late TuiAttachmentImports imports;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tui-references-');
    container = ProviderContainer(
      overrides: [
        fileParserProvider.overrideWith(
          (ref) => throw StateError('must not parse'),
        ),
      ],
    );
    imports = TuiAttachmentImports(container);
  });
  tearDown(() async {
    imports.release('client');
    container.dispose();
    await directory.delete(recursive: true);
  });

  for (final entry in {
    'pdf': 'file',
    'bin': 'file',
    'mp3': 'audio',
    'mp4': 'video',
  }.entries) {
    test(
      '${entry.key} sends only its path without parsing or media processing',
      () async {
        final file = File(p.join(directory.path, '资料 file.${entry.key}'));
        await file.writeAsString(
          'This is deliberately not valid media or PDF data.',
        );
        final result = await imports.import('client', 'session', {
          'path': file.path,
          'confirmed': true,
        });
        expect(result['reference'], true);
        expect(result['path'], await file.resolveSymbolicLinks());
        expect(result['preview'], result['path']);
        expect(result['kind'], entry.value);
        expect(result['attachments_count'], 0);
        expect(result.containsKey('token'), false);
        expect(result.containsKey('data_base64'), false);
      },
    );
  }

  test(
    'empty and large files can be referenced without content limits',
    () async {
      final file = File(p.join(directory.path, 'empty.dat'));
      await file.writeAsBytes([]);
      for (final size in [0, 11 * 1024 * 1024]) {
        final handle = await file.open(mode: FileMode.append);
        await handle.truncate(size);
        await handle.close();
        final result = await imports.import('client', 'session', {
          'path': file.path,
          'confirmed': true,
          'display_name': 'Original name.dat',
        });
        expect(result['size'], size);
        expect(result['name'], 'Original name.dat');
        expect(result['path'], await file.resolveSymbolicLinks());
        expect(result['reference'], true);
      }
    },
  );

  test('images still carry image data behind a scoped token', () async {
    container.dispose();
    container = ProviderContainer();
    imports = TuiAttachmentImports(container);
    final file = File(p.join(directory.path, 'pixel.png'));
    await file.writeAsBytes(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6YVQAAAAASUVORK5CYII=',
      ),
    );
    final result = await imports.import('client', 'session', {
      'path': file.path,
      'confirmed': true,
    });
    expect(result['reference'], isNot(true));
    expect(result['kind'], 'image');
    final attachments = imports.resolve(
      'client',
      'session',
      result['token'] as String,
    );
    expect(attachments.single.hasImageData, true);
    expect(
      base64Decode(attachments.single.imageBase64!),
      await file.readAsBytes(),
    );
  });

  test(
    'stored references retain labels and provide only addresses to the model',
    () {
      final original = Attachment(
        name: 'notes.pdf',
        mimeType: 'application/pdf',
        referencePath: p.join(directory.path, 'notes.pdf'),
        referenceTag: '[File 1]',
      );
      final restored = Attachment.fromJson(original.toJson()).copyWith();
      expect(restored.referencePath, original.referencePath);
      expect(restored.referenceTag, '[File 1]');
      expect(restored.text, isEmpty);
      expect(restored.hasDownloadableBytes, false);
      final message = ChatMessage(
        role: MessageRole.user,
        content: 'Read [File 1]',
        attachments: [restored],
      );
      final request = RequestContextBuilder.requestMessage(
        message,
        vision: true,
      );
      expect(message.content, 'Read [File 1]');
      expect(request.content, contains('【文件地址 [File 1]】'));
      expect(request.content, contains(original.referencePath));
      expect(request.imageDataUrls, isEmpty);
    },
  );
}
