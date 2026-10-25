import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/providers.dart';
import '../../../state/chat_controller.dart';
import '../../../state/settings_controller.dart';
import '../../../state/controlled_browser.dart';

class ControlledBrowserPanel extends ConsumerStatefulWidget {
  const ControlledBrowserPanel({super.key});
  @override
  ConsumerState<ControlledBrowserPanel> createState() => _BrowserState();
}

class _BrowserState extends ConsumerState<ControlledBrowserPanel> {
  String? _selected, _tool, _error;
  bool _busy = false;
  final _arguments = TextEditingController(text: '{}'),
      _feedback = TextEditingController();
  @override
  void dispose() {
    _arguments.dispose();
    _feedback.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final conversation = ref.watch(
      chatControllerProvider.select((s) => s.value?.currentId),
    );
    final state = ref.watch(controlledBrowserProvider);
    final settings = ref.watch(settingsControllerProvider).value;
    final observations = state.observations.values
        .where((o) => o.conversation == conversation)
        .toList();
    final observation =
        observations.where((o) => o.key == _selected).firstOrNull ??
        observations.lastOrNull;
    final server = settings?.gateway.customMcpServers
        .where(
          (s) => s.id == observation?.server && s.enabled && s.toolsDiscovered,
        )
        .firstOrNull;
    const manualTools = {
      'browser_navigate',
      'browser_navigate_back',
      'browser_snapshot',
      'browser_take_screenshot',
      'browser_click',
      'browser_type',
      'browser_press_key',
      'browser_tabs',
      'browser_close',
      'browser_console_messages',
      'browser_network_requests',
    };
    final tools =
        server?.tools.where((t) => manualTools.contains(t.name)).toList() ?? [];
    final selectedTool = tools.where((t) => t.name == _tool).firstOrNull;
    final takeover =
        conversation != null && state.takeovers.contains(conversation);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '模型受控浏览器 · 官方 Playwright MCP',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            '这是独立受控浏览器的实际观察回传。上方“人工网页”是另一 WebView，未共享页面或登录。每个会话/代理保有独立浏览器；此处仅显示所选会话。',
          ),
          const Text(
            '不会因模型命令空闲而关闭人工接手页面。需要释放时，可接手后选择 browser_close 关闭当前代理浏览器；停止任务或删除会话会关闭该会话隔离进程。',
          ),
          if (observations.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('尚无受控浏览器观察。先在此会话选择 Playwright MCP，并让模型读取页面或截图。'),
            ),
          if (observation != null) ...[
            DropdownButtonFormField<String>(
              key: ValueKey(observation.key),
              initialValue: observation.key,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '观察的代理 / 服务'),
              items: [
                for (final item in observations)
                  DropdownMenuItem(
                    value: item.key,
                    child: Text(
                      '${item.agent.isEmpty ? '主代理' : item.agent} · ${item.server}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) => setState(() => _selected = value),
            ),
            Text('${observation.at.toLocal()} · ${observation.tool}'),
            if (observation.image != null)
              Image.memory(
                base64Decode(observation.image!),
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const Text('截图解码失败'),
              ),
            ExpansionTile(
              title: const Text('页面快照 / 工具结果'),
              children: [SelectableText(observation.text)],
            ),
            SwitchListTile(
              title: const Text('用户接手受控浏览器'),
              subtitle: const Text(
                '接手期间拒绝新的模型浏览器调用；已派发的操作可能仍会结束。手动操作下方同一个受控实例，完成后关闭接手让模型继续。',
              ),
              value: takeover,
              onChanged: conversation == null
                  ? null
                  : (enabled) => ref
                        .read(controlledBrowserProvider.notifier)
                        .takeover(conversation, enabled),
            ),
            if (takeover) ...[
              DropdownButtonFormField<String>(
                key: ValueKey('${server?.id}:$_tool'),
                initialValue: selectedTool?.name,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '手动调用实际已发现工具'),
                items: [
                  for (final tool in tools)
                    DropdownMenuItem(value: tool.name, child: Text(tool.name)),
                ],
                onChanged: (value) => setState(() => _tool = value),
              ),
              if (selectedTool != null)
                ExpansionTile(
                  title: const Text('工具参数说明'),
                  children: [
                    SelectableText(
                      const JsonEncoder.withIndent(
                        '  ',
                      ).convert(selectedTool.inputSchema),
                    ),
                  ],
                ),
              TextField(
                controller: _arguments,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: '工具参数 JSON（如 {"url":"https://example.com"}）',
                ),
              ),
              FilledButton(
                onPressed: _busy || selectedTool == null || server == null
                    ? null
                    : () async {
                        setState(() {
                          _busy = true;
                          _error = null;
                        });
                        try {
                          final latest = ref
                              .read(settingsControllerProvider)
                              .requireValue;
                          final current = latest.gateway.customMcpServers
                              .where(
                                (s) =>
                                    s.id == server.id &&
                                    s.enabled &&
                                    s.toolsDiscovered,
                              )
                              .firstOrNull;
                          if (current == null ||
                              current.localProcess?.isPlaywright != true) {
                            throw StateError('受控浏览器服务已关闭或配置已改变');
                          }
                          final routed = latest.routedMcpTools
                              .where(
                                (t) =>
                                    t.serverId == server.id &&
                                    t.originalName == selectedTool.name,
                              )
                              .firstOrNull;
                          if (routed == null) throw StateError('该工具当前不可用');
                          final result = await ref
                              .read(mcpClientProvider)
                              .callTool(
                                connection: latest
                                    .connectionForRouted(routed)
                                    .forSession(
                                      conversation,
                                      agentId: observation.agent.isEmpty
                                          ? null
                                          : observation.agent,
                                    ),
                                name: selectedTool.name,
                                userInitiated: true,
                                arguments: Map<String, dynamic>.from(
                                  jsonDecode(_arguments.text) as Map,
                                ),
                              );
                          String? image;
                          for (final content in result.content) {
                            if (content['type'] == 'image' &&
                                content['data'] is String) {
                              image = content['data'] as String;
                              break;
                            }
                          }
                          ref
                              .read(controlledBrowserProvider.notifier)
                              .observe(
                                conversation: conversation,
                                server: server.id,
                                agent: observation.agent,
                                tool: selectedTool.name,
                                text: result.text,
                                image: image,
                              );
                        } catch (error) {
                          if (mounted) setState(() => _error = '$error');
                        } finally {
                          if (mounted) setState(() => _busy = false);
                        }
                      },
                child: Text(_busy ? '执行中…' : '执行此手动浏览器操作'),
              ),
            ],
            TextField(
              controller: _feedback,
              decoration: const InputDecoration(
                labelText: '选中元素反馈（ref、文字或截图位置，作为补充要求）',
              ),
            ),
            TextButton(
              onPressed: conversation == null
                  ? null
                  : () {
                      ref
                          .read(controlledBrowserProvider.notifier)
                          .addFeedback(
                            conversation,
                            '浏览器用户反馈 [${observation.agent}]：${_feedback.text}',
                          );
                      _feedback.clear();
                    },
              child: const Text('在下一工具轮发给模型'),
            ),
          ],
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }
}
