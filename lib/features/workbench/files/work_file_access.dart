import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../domain/desktop/workspace_tools.dart';
import '../../../state/work_changes.dart';
import '../../../domain/workbench/files/delivery_access.dart';
export '../../../domain/workbench/files/delivery_access.dart'
    hide openDeliverySessionUsing;

Future<WorkToolSession> openDeliverySession(
  WidgetRef ref,
  WorkFileChange file,
  CancelToken token,
) => openDeliverySessionUsing(ref.read, file, token);
