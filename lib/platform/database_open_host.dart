import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'paths_host.dart';

QueryExecutor openAppDatabase() => LazyDatabase(
  () async => NativeDatabase.createInBackground(
    File(
      '${(await getApplicationDocumentsDirectory()).path}/expert_chat.sqlite',
    ),
  ),
);
