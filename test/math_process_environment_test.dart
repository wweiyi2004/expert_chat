import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:expert_chat/domain/tools/math/math_process.dart';

void main() {
  test(
    'math subprocess receives explicit filtered environment without host credential names',
    () async {
      final result = await executeMathScript(
        {},
        pythonExecutable: 'python',
        childEnvironment: {
          ...Platform.environment,
          'EXPERT_REMOTE_MODEL_KEY': 'synthetic-never-returned',
          'OPENAI_API_KEY': 'synthetic-never-returned',
          'SOME_TOKEN': 'synthetic-never-returned',
          'SAFE_FIXTURE': 'kept',
        },
        trustedScript:
            'import os,json\nprint(json.dumps({"ok":True,"result":{"remote_key":"EXPERT_REMOTE_MODEL_KEY" in os.environ,"api_key":"OPENAI_API_KEY" in os.environ,"token":"SOME_TOKEN" in os.environ,"safe":os.environ.get("SAFE_FIXTURE")}}))',
      );
      expect(result['ok'], true);
      expect(result['result'], {
        'remote_key': false,
        'api_key': false,
        'token': false,
        'safe': 'kept',
      });
    },
  );
}
