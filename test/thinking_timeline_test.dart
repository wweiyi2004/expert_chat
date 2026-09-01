import 'package:expert_chat/data/models.dart';
import 'package:expert_chat/domain/chat/thinking_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy activities follow the full reasoning block', () {
    const reasoning = '先想清楚再搜。';
    final activities = [
      SearchActivity(
        kind: SearchActivityKind.search,
        query: '华科',
        status: SearchActivityStatus.done,
        resultCount: 3,
      ),
    ];
    final segments = buildThinkingTimeline(
      reasoning: reasoning,
      activities: activities,
    );
    expect(segments, hasLength(2));
    expect(segments.first.text, reasoning);
    expect(segments.last.activity?.query, '华科');
  });

  test('tool steps split reasoning at recorded offsets', () {
    const reasoning = '准备搜索。打开页面。开始总结。';
    final search = SearchActivity(
      kind: SearchActivityKind.search,
      query: '华科',
      status: SearchActivityStatus.done,
      resultCount: 2,
      reasoningOffset: '准备搜索。'.length,
      items: const [
        SearchActivityItem(title: '华中科技大学', url: 'https://hust.edu.cn'),
      ],
    );
    final fetch = SearchActivity(
      kind: SearchActivityKind.fetch,
      query: 'https://hust.edu.cn',
      status: SearchActivityStatus.done,
      resultCount: 1,
      reasoningOffset: '准备搜索。打开页面。'.length,
    );
    final segments = buildThinkingTimeline(
      reasoning: reasoning,
      activities: [fetch, search],
    );
    expect(segments.map((s) => s.isReasoning).toList(), [
      true,
      false,
      true,
      false,
      true,
    ]);
    expect(segments[0].text, '准备搜索。');
    expect(segments[1].activity?.kind, SearchActivityKind.search);
    expect(segments[2].text, '打开页面。');
    expect(segments[3].activity?.kind, SearchActivityKind.fetch);
    expect(segments[4].text, '开始总结。');
  });

  test('mcp image and document steps stay in the thinking chain', () {
    const reasoning = '先调工具再回答。';
    final segments = buildThinkingTimeline(
      reasoning: reasoning,
      activities: [
        SearchActivity(
          kind: SearchActivityKind.mcp,
          query: 'list_files',
          status: SearchActivityStatus.done,
          reasoningOffset: 3,
        ),
        SearchActivity(
          kind: SearchActivityKind.image,
          query: '配图',
          status: SearchActivityStatus.done,
          reasoningOffset: 6,
        ),
        SearchActivity(
          kind: SearchActivityKind.document,
          query: 'edit_document',
          status: SearchActivityStatus.done,
          reasoningOffset: reasoning.length,
        ),
      ],
    );
    expect(segments.where((s) => !s.isReasoning).map((s) => s.activity?.kind), [
      SearchActivityKind.mcp,
      SearchActivityKind.image,
      SearchActivityKind.document,
    ]);
  });

  test('mcp and document kinds survive JSON', () {
    final mcp = SearchActivity(
      kind: SearchActivityKind.mcp,
      query: 'list_files',
      status: SearchActivityStatus.done,
    );
    expect(SearchActivity.fromJson(mcp.toJson()).kind, SearchActivityKind.mcp);
    final document = SearchActivity(
      kind: SearchActivityKind.document,
      query: 'edit_document',
      status: SearchActivityStatus.done,
    );
    expect(
      SearchActivity.fromJson(document.toJson()).kind,
      SearchActivityKind.document,
    );
  });

  test('SearchActivity items survive JSON', () {
    final activity = SearchActivity(
      kind: SearchActivityKind.search,
      query: '华科',
      status: SearchActivityStatus.done,
      resultCount: 1,
      reasoningOffset: 12,
      items: const [
        SearchActivityItem(title: '简介', url: 'https://hust.edu.cn'),
      ],
    );
    final restored = SearchActivity.fromJson(activity.toJson());
    expect(restored.reasoningOffset, 12);
    expect(restored.items.single.title, '简介');
    expect(restored.items.single.url, 'https://hust.edu.cn');
  });
}
