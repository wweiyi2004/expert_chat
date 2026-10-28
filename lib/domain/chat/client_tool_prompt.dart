import '../../data/composer_modes.dart';
import '../../data/story_models.dart';
import '../llm/llm_provider.dart';

/// Formats the capabilities already selected for this turn. No tool execution.
abstract final class ClientToolPrompt {
  static String build({
    required String dateLine,
    required SearchMode searchMode,
    required ImageGenMode imageGenMode,
    required bool useWebSearchTool,
    required bool useFetchUrlTool,
    required bool useImageGenTool,
    required bool useVisionTool,
    required bool useDocumentInspectTool,
    required bool useDocumentEditTool,
    required bool useDocumentConvertTool,
    required bool forceDocTool,
    required bool workMode,
    required CharacterCard? imageCharacter,
    required List<ToolSpec> mcpPassthroughTools,
  }) {
    final hint = StringBuffer(dateLine)..write('。');
    if (useWebSearchTool) {
      hint.write(
        searchMode == SearchMode.always
            ? '本轮必须调用 web_search。搜索关键词应自包含（把指代替换成具体名称，时效性问题带上年份）。'
            : '需要实时、最新或你不确定的事实时调用 web_search；'
                  '生图前若要核实真实事物的外观/标志也可先搜。'
                  '常识、闲聊、上下文已有的内容不要搜。'
                  '搜索关键词应自包含（把指代替换成具体名称，时效性问题带上年份）。',
      );
    }
    if (useFetchUrlTool) {
      hint.write(
        workMode
            ? '可用 fetch_url 读取任务所需的公开 HTTP(S) 网页，不要求链接先出现在用户消息或搜索结果中。'
            : '用户在本轮消息中给出的链接，以及本轮搜索结果中的链接，可用 fetch_url 读取。',
      );
    }
    if (useImageGenTool) {
      if (imageCharacter != null) {
        hint.write(
          imageGenMode == ImageGenMode.always
              ? '本轮必须调用 generate_image，为角色「${imageCharacter.name}」配一张安全立绘（每轮最多一次）；'
                    '即使用户在写成人向内容，生图也只画干净角色形象，禁止色情提示词。'
              : '仅当用户明确要图，或立绘能明显帮助理解时，为角色「${imageCharacter.name}」调用 generate_image（每轮最多一次）；'
                    '不要给每句对白配装饰图。即使用户在写成人向内容，生图也只画干净角色形象，禁止色情提示词。',
        );
      } else {
        hint.write(
          imageGenMode == ImageGenMode.always
              ? '本轮必须调用 generate_image（每轮最多一次）；提示词必须 SFW，禁止色情内容。'
              : '仅当用户明确要求画图/配图/生成图片，或配图能明显帮助理解时调用 generate_image（每轮最多一次）。'
                    '不要给普通文字回答配装饰图。'
                    '画真实存在、你不确定外观的事物时，先 web_search 再根据搜索结果写 prompt。'
                    '提示词必须 SFW，禁止色情内容。',
        );
      }
    }
    if (useVisionTool) {
      hint.write(
        '用户上传了图片。你看不到像素，需要看图、读图中文字或回答图里的细节时，'
        '必须调用 analyze_image；attachment_name 用【图片：文件名】中的名字。',
      );
    }
    if (useDocumentInspectTool) {
      hint.write('改表格或不确定附件结构时，先调用 inspect_document 查看预览。');
    }
    if (useDocumentEditTool) {
      hint.write(
        forceDocTool
            ? '用户点击了「改文档」。你必须调用 edit_document，'
                  '给出完整 DocumentPatch（schema_version=1；format 为 '
                  'xlsx/docx/pptx/txt/md/csv/tsv 之一；ops）。'
                  'xlsx 用 set_cells/set_range/add_sheet/ensure_sheet；'
                  'docx 用 replace_text；pptx 用 set_shape_text；'
                  'txt/md/csv/tsv 用 replace_text 或 set_text（整文件覆写）。'
            : '用户上传了可编辑文件（.xlsx/.docx/.pptx/.txt/.md/.csv/.tsv）。'
                  '若要求改文件内容/查找替换/回传，调用 edit_document。',
      );
    }
    if (useDocumentConvertTool && !forceDocTool) {
      hint.write('若要求格式转换（如 txt→docx、csv→xlsx、docx→md），调用 convert_document。');
    }
    if (useDocumentEditTool || useDocumentConvertTool) {
      hint.write('不要编造未上传的附件名。');
    }
    if (mcpPassthroughTools.isNotEmpty) {
      hint.write(
        '已连接 MCP Server，还可调用：'
        '${[for (final tool in mcpPassthroughTools) tool.name].join("、")}。',
      );
    }
    return hint.toString();
  }
}
