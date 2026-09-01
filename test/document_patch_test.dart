import 'dart:convert';

import 'package:expert_chat/domain/document/document_convert.dart';
import 'package:expert_chat/domain/document/document_edit_tools.dart';
import 'package:expert_chat/domain/document/document_patch.dart';
import 'package:expert_chat/domain/document/document_service_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DocumentPatch', () {
    test('parses set_cells + set_range + ensure_sheet', () {
      final patch = DocumentPatch.parse({
        'schema_version': 1,
        'format': 'xlsx',
        'output_filename': 'out.xlsx',
        'ops': [
          {
            'op': 'set_cells',
            'sheet': 'Sheet1',
            'cells': {'B2': 1.1, 'C2': '=B2*1.1', 'A1': '标题'},
          },
          {
            'op': 'set_range',
            'start': 'A10',
            'values': [
              ['a', 'b'],
              [1, 2],
            ],
          },
          {'op': 'ensure_sheet', 'name': '汇总'},
        ],
      });

      expect(patch.format, 'xlsx');
      expect(patch.ops, hasLength(3));
      expect(patch.ops[0], isA<SetCellsOp>());
      final cells = patch.ops[0] as SetCellsOp;
      expect(cells.cells['B2'], 1.1);
      expect(cells.cells['C2'], '=B2*1.1');
      expect(patch.ops[1], isA<SetRangeOp>());
      expect(patch.ops[2], isA<AddSheetOp>());
      expect((patch.ops[2] as AddSheetOp).ensureOnly, isTrue);
      expect(patch.toJson()['schema_version'], 1);
    });

    test('rejects unknown op and bad A1', () {
      expect(
        () => DocumentPatch.parse({
          'schema_version': 1,
          'format': 'xlsx',
          'ops': [
            {'op': 'drop_table'},
          ],
        }),
        throwsA(isA<DocumentPatchException>()),
      );
      expect(
        () => DocumentPatch.parse({
          'schema_version': 1,
          'format': 'xlsx',
          'ops': [
            {
              'op': 'set_cells',
              'cells': {'A1:B2': 1},
            },
          ],
        }),
        throwsA(isA<DocumentPatchException>()),
      );
    });

    test('rejects path traversal in output_filename', () {
      expect(
        () => DocumentPatch.parse({
          'schema_version': 1,
          'format': 'xlsx',
          'output_filename': '../evil.xlsx',
          'ops': [
            {
              'op': 'set_cells',
              'cells': {'A1': 1},
            },
          ],
        }),
        throwsA(isA<DocumentPatchException>()),
      );
    });

    test('accepts docx replace_text and pptx set_shape_text', () {
      final docx = DocumentPatch.parse({
        'schema_version': 1,
        'format': 'docx',
        'ops': [
          {'op': 'replace_text', 'find': '旧', 'replace': '新'},
        ],
      });
      expect(docx.ops.single, isA<ReplaceTextOp>());
      final pptx = DocumentPatch.parse({
        'schema_version': 1,
        'format': 'pptx',
        'ops': [
          {'op': 'set_shape_text', 'slide': 1, 'shape': 0, 'text': '标题'},
        ],
      });
      expect(pptx.ops.single, isA<SetShapeTextOp>());
    });

    test('accepts txt/md/csv/tsv replace_text and set_text', () {
      for (final format in ['txt', 'md', 'csv', 'tsv']) {
        final replace = DocumentPatch.parse({
          'schema_version': 1,
          'format': format,
          'ops': [
            {'op': 'replace_text', 'find': 'a', 'replace': 'b'},
          ],
        });
        expect(replace.ops.single, isA<ReplaceTextOp>());
        final setText = DocumentPatch.parse({
          'schema_version': 1,
          'format': format,
          'ops': [
            {'op': 'set_text', 'text': 'hello\nworld'},
          ],
        });
        expect(setText.ops.single, isA<SetTextOp>());
        expect((setText.ops.single as SetTextOp).text, 'hello\nworld');
      }
    });

    test('rejects xlsx ops on txt and set_text on docx', () {
      expect(
        () => DocumentPatch.parse({
          'schema_version': 1,
          'format': 'txt',
          'ops': [
            {
              'op': 'set_cells',
              'cells': {'A1': 1},
            },
          ],
        }),
        throwsA(isA<DocumentPatchException>()),
      );
      expect(
        () => DocumentPatch.parse({
          'schema_version': 1,
          'format': 'docx',
          'ops': [
            {'op': 'set_text', 'text': 'x'},
          ],
        }),
        throwsA(isA<DocumentPatchException>()),
      );
    });

    test('enforces max ops', () {
      expect(
        () => DocumentPatch.parse({
          'schema_version': 1,
          'format': 'xlsx',
          'ops': List.generate(
            DocumentPatch.maxOps + 1,
            (_) => {
              'op': 'set_cells',
              'cells': {'A1': 1},
            },
          ),
        }),
        throwsA(isA<DocumentPatchException>()),
      );
    });
  });

  group('DocumentConvert', () {
    test('allows txt to docx and rejects pptx to xlsx', () {
      expect(DocumentConvert.canConvert('txt', 'docx'), isTrue);
      expect(DocumentConvert.canConvert('csv', 'xlsx'), isTrue);
      expect(DocumentConvert.canConvert('pptx', 'xlsx'), isFalse);
    });
  });

  group('DocumentServiceClient.sanitizeDownloadFilename', () {
    test('accepts plain basenames', () {
      expect(
        DocumentServiceClient.sanitizeDownloadFilename(
          'report_edited.xlsx',
          fallback: 'fallback.xlsx',
        ),
        'report_edited.xlsx',
      );
      expect(
        DocumentServiceClient.sanitizeDownloadFilename(
          'report..v2.xlsx',
          fallback: 'fallback.xlsx',
        ),
        'report..v2.xlsx',
      );
    });

    test('strips path traversal and falls back when empty after strip', () {
      expect(
        DocumentServiceClient.sanitizeDownloadFilename(
          '../evil.xlsx',
          fallback: 'safe.xlsx',
        ),
        'evil.xlsx',
      );
      expect(
        DocumentServiceClient.sanitizeDownloadFilename(
          '..\\..\\secret.csv',
          fallback: 'safe.csv',
        ),
        'secret.csv',
      );
      expect(
        DocumentServiceClient.sanitizeDownloadFilename(
          '../..',
          fallback: 'safe.bin',
        ),
        'safe.bin',
      );
    });

    test('rejects control characters and null bytes', () {
      expect(
        DocumentServiceClient.sanitizeDownloadFilename(
          'a\r\nb.xlsx',
          fallback: 'safe.xlsx',
        ),
        'safe.xlsx',
      );
      expect(
        DocumentServiceClient.sanitizeDownloadFilename(
          'a\x00b.xlsx',
          fallback: 'safe.xlsx',
        ),
        'safe.xlsx',
      );
    });

    test('uses fallback when raw is null or empty', () {
      expect(
        DocumentServiceClient.sanitizeDownloadFilename(
          null,
          fallback: 'out.md',
        ),
        'out.md',
      );
      expect(
        DocumentServiceClient.sanitizeDownloadFilename(
          '   ',
          fallback: 'out.md',
        ),
        'out.md',
      );
    });
  });

  group('truncated set_text guard helpers', () {
    test('hasSetTextOp detects whole-file rewrite', () {
      final withSet = DocumentPatch.parse({
        'schema_version': 1,
        'format': 'txt',
        'ops': [
          {'op': 'set_text', 'text': 'only prefix'},
        ],
      });
      expect(withSet.hasSetTextOp, isTrue);
      final withReplace = DocumentPatch.parse({
        'schema_version': 1,
        'format': 'txt',
        'ops': [
          {'op': 'replace_text', 'find': 'a', 'replace': 'b'},
        ],
      });
      expect(withReplace.hasSetTextOp, isFalse);
    });
  });

  group('DocumentEditTools', () {
    test('edit_document tool has stable name', () {
      expect(DocumentEditTools.editDocumentTool.name, 'edit_document');
      expect(DocumentEditTools.convertDocumentTool.name, 'convert_document');
      expect(DocumentEditTools.inspectDocumentTool.name, 'inspect_document');
    });

    test('parseConvertDocumentArgs reads target_format', () {
      final args = DocumentEditTools.parseConvertDocumentArgs(
        jsonEncode({
          'attachment_name': 'a.txt',
          'target_format': 'docx',
          'output_filename': 'a.docx',
        }),
      );
      expect(args.attachmentName, 'a.txt');
      expect(args.targetFormat, 'docx');
      expect(args.outputFilename, 'a.docx');
    });

    test('parseInspectDocumentArgs reads attachment_name', () {
      final args = DocumentEditTools.parseInspectDocumentArgs(
        jsonEncode({'attachment_name': 'sales.xlsx'}),
      );
      expect(args.attachmentName, 'sales.xlsx');
      expect(
        DocumentEditTools.parseInspectDocumentArgs('{}').attachmentName,
        isNull,
      );
    });

    test('describeAttachmentForInspect flags truncated files', () {
      final text = DocumentEditTools.describeAttachmentForInspect(
        name: 'notes.md',
        format: 'md',
        mimeType: 'text/markdown',
        sizeBytes: 12,
        truncated: true,
        hasBytes: true,
        text: 'hello',
      );
      expect(text, contains('附件：notes.md'));
      expect(text, contains('format: md'));
      expect(text, contains('truncated: yes'));
      expect(text, contains('禁止 set_text'));
      expect(text, contains('hello'));
    });

    test('parseEditDocumentArgs validates nested patch', () {
      final args = DocumentEditTools.parseEditDocumentArgs(
        jsonEncode({
          'attachment_name': 'sales.xlsx',
          'patch': {
            'schema_version': 1,
            'format': 'xlsx',
            'ops': [
              {
                'op': 'set_cells',
                'cells': {'A1': 'ok'},
              },
            ],
          },
        }),
      );
      expect(args.attachmentName, 'sales.xlsx');
      expect(args.patch.ops, hasLength(1));
    });

    test('parseEditDocumentArgs rejects missing patch', () {
      expect(
        () => DocumentEditTools.parseEditDocumentArgs(
          '{"attachment_name":"a.xlsx"}',
        ),
        throwsA(isA<DocumentPatchException>()),
      );
    });
  });
}
