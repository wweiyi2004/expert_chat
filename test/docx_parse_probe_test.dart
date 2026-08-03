import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:expert_chat/domain/tools/file_parser.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List makeDocx({int repeat = 1}) {
  final body = List.filled(repeat, '你好世界 hello world').join(' ');
  final documentXml =
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body><w:p><w:r><w:t>$body</w:t></w:r></w:p></w:body>
</w:document>''';
  final contentTypes =
      '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>''';
  final rels = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>''';
  final archive = Archive();
  void add(String name, String content) {
    final b = utf8.encode(content);
    archive.addFile(ArchiveFile(name, b.length, b));
  }

  add('[Content_Types].xml', contentTypes);
  add('_rels/.rels', rels);
  add('word/document.xml', documentXml);
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  final parser = FileParser();

  test('parses minimal docx', () {
    final bytes = makeDocx(repeat: 5);
    final a = parser.parse(
      name: 't.docx',
      mimeType:
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      sizeBytes: bytes.length,
      bytes: bytes,
    );
    expect(a.parseError, isNull, reason: a.parseError);
    expect(a.text, contains('你好世界'));
    expect(a.hasDownloadableBytes, isTrue);
  });

  test('parses highly compressible docx content', () {
    final bytes = makeDocx(repeat: 20000);
    final a = parser.parse(
      name: 'big.docx',
      mimeType:
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      sizeBytes: bytes.length,
      bytes: bytes,
    );
    expect(a.parseError, isNull, reason: a.parseError);
    expect(a.text, contains('你好世界'));
    expect(a.hasDownloadableBytes, isTrue);
  });

  test('retains binary for plain text formats used by document service', () {
    final bytes = Uint8List.fromList(utf8.encode('name,age\nAda,1\n'));
    final a = parser.parse(
      name: 'people.csv',
      mimeType: 'text/csv',
      sizeBytes: bytes.length,
      bytes: bytes,
    );
    expect(a.parseError, isNull, reason: a.parseError);
    expect(a.hasDownloadableBytes, isTrue);
    expect(a.isEditableDocument, isTrue);
    expect(a.documentPatchFormat, 'csv');
  });

  test('keeps office binary when zip is valid but text is empty-ish', () {
    // document.xml with no w:t text nodes
    final documentXml =
        '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body><w:p/></w:body>
</w:document>''';
    final contentTypes =
        '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>''';
    final rels =
        '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>''';
    final archive = Archive();
    void add(String name, String content) {
      final b = utf8.encode(content);
      archive.addFile(ArchiveFile(name, b.length, b));
    }

    add('[Content_Types].xml', contentTypes);
    add('_rels/.rels', rels);
    add('word/document.xml', documentXml);
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
    final a = parser.parse(
      name: 'empty.docx',
      mimeType:
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      sizeBytes: bytes.length,
      bytes: bytes,
    );
    expect(a.parseError, isNull, reason: a.parseError);
    expect(a.hasDownloadableBytes, isTrue);
    expect(a.isEditableDocument, isTrue);
  });
}
