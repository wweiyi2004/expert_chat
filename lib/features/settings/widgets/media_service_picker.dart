import 'package:flutter/material.dart';
import '../../../data/provider_profile.dart';

class MediaServiceSelection {
  const MediaServiceSelection(this.profile, this.model);
  final ProviderProfile profile;
  final String model;
}

class MediaServicePicker extends StatefulWidget {
  const MediaServicePicker({super.key, required this.profiles});
  final List<ProviderProfile> profiles;
  @override
  State<MediaServicePicker> createState() => _MediaServicePickerState();
}

class _MediaServicePickerState extends State<MediaServicePicker> {
  ProviderProfile? _profile;
  final _model = TextEditingController();
  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('复用模型服务'),
    content: SizedBox(
      width: 430,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('复用服务地址与密钥，再选择支持这项多媒体能力的模型。'),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              isExpanded: true,
              decoration: const InputDecoration(labelText: '模型服务'),
              items: [
                for (final profile in widget.profiles.where(
                  (p) => p.authMode == 'apiKey',
                ))
                  DropdownMenuItem(
                    value: profile.id,
                    child: Text(profile.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (id) => setState(() {
                _profile = widget.profiles.firstWhere((p) => p.id == id);
                _model.clear();
              }),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _model,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: '多媒体模型 ID',
                suffixIcon: _profile == null
                    ? null
                    : PopupMenuButton<String>(
                        tooltip: '从已扫描模型中选择',
                        icon: const Icon(Icons.expand_more),
                        onSelected: (model) =>
                            setState(() => _model.text = model),
                        itemBuilder: (_) => [
                          for (final model in _profile!.models)
                            PopupMenuItem(value: model, child: Text(model)),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _profile == null || _model.text.trim().isEmpty
            ? null
            : () => Navigator.pop(
                context,
                MediaServiceSelection(_profile!, _model.text.trim()),
              ),
        child: const Text('使用此服务'),
      ),
    ],
  );
}
