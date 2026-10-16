/// How many model rounds may call tools before the app forces a final answer.
abstract final class ToolLoopPolicy {
  /// Chat mode: user-configurable search rounds, plus one tool-less wrap-up.
  static const chatCallsPerRound = 3;

  /// Work mode: keep tools until the model stops calling them, with a cap.
  static const workSafetyRounds = 24;
  static const workCallsPerRound = 8;

  static const workModeHint =
      '当前是任务模式：用工具把用户交代的事情做完，再给最终结果。'
      '中间步骤尽量调用工具，不要只口头承诺。';

  static int maxRounds({required bool workMode, required int searchMaxRounds}) {
    if (workMode) return workSafetyRounds;
    return searchMaxRounds + 1;
  }

  static int maxCallsPerRound({required bool workMode}) =>
      workMode ? workCallsPerRound : chatCallsPerRound;
}
