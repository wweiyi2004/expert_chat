import 'dart:convert';
import 'package:riverpod/riverpod.dart';
import '../core/providers.dart';
import '../data/context_selection.dart';
export '../data/context_selection.dart';

final contextSelectionsProvider = NotifierProvider<ContextSelections,Map<String,ContextSelection>>(ContextSelections.new);
class ContextSelections extends Notifier<Map<String,ContextSelection>> {
  Future<void> _pending=Future.value();
  @override Map<String,ContextSelection> build() {
    final raw=ref.read(sharedPrefsProvider).getString('contextSelections.v1');
    if(raw==null)return {};
    final values=jsonDecode(raw) as Map;
    return values.map((key,value)=>MapEntry(key.toString(),ContextSelection.fromJson(Map<String,dynamic>.from(value as Map))));
  }
  Future<void> toggle(String session,String key,bool enabled) {
    final task=_pending.then((_) async {
      final old=state[session]??const ContextSelection();
      final value=Map<String,dynamic>.from(old.toJson());
      if(key=='project'||key=='memory') {
        value['include_$key']=enabled;
      } else {
        final split=key.indexOf(':');
        if(split<1)throw ArgumentError('无效的上下文项');
        final type=key.substring(0,split),id=key.substring(split+1);
        final field=switch(type){'round'=>'excluded_rounds','file'=>'excluded_attachments','tool'=>'included_tools',_=>throw ArgumentError('无效的上下文项')};
        final entries=Set<String>.from(value[field] as List);
        if(type=='tool'?enabled:!enabled){entries.add(id);}else{entries.remove(id);}
        value[field]=entries.toList();
      }
      final next={...state,session:ContextSelection.fromJson(value)};
      if(!await ref.read(sharedPrefsProvider).setString('contextSelections.v1',jsonEncode(next.map((k,v)=>MapEntry(k,v.toJson()))))) {
        throw StateError('上下文选择未保存');
      }
      if(ref.mounted)state=next;
    });
    _pending=task.catchError((Object _){});
    return task;
  }
}
