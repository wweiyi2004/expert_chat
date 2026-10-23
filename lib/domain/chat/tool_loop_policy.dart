/// How many model rounds may call tools before the app forces a final answer.
abstract final class ToolLoopPolicy {
  /// Chat mode: user-configurable search rounds, plus one tool-less wrap-up.
  static const chatCallsPerRound = 3;

  /// Initial fallback; WorkRounds owns the extendable work-session budget.
  static const workSafetyRounds = 24;
  static const workCallsPerRound = 8;

  static const workModeHint =
      '当前是工作模式：以可核验的结果或文件交付完成任务。复杂任务先简述步骤，再逐步执行与验证。'
      '优先使用已连接的工具完成中间步骤，遇到缺失信息或失败如实说明，不要编造执行结果。完成后说明交付物与验证情况。';

  static int maxRounds({required bool workMode, required int searchMaxRounds}) {
    if (workMode) return workSafetyRounds;
    return searchMaxRounds + 1;
  }

  static int maxCallsPerRound({required bool workMode}) =>
      workMode ? workCallsPerRound : chatCallsPerRound;
}
