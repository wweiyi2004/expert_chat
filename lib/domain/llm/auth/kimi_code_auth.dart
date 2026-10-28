import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import '../../../platform/browser.dart';
import '../../../platform/credentials.dart';
import '../../../platform/preferences.dart';

/// RFC 8628 flow and public client configuration from MoonshotAI/kimi-code,
/// packages/oauth (MIT). This client identifies itself as Expert Chat.
class KimiCodeAuth {
  KimiCodeAuth(this.storage,this.prefs);
  final FlutterSecureStorage storage;
  final SharedPreferences prefs;
  static const baseUrl='https://api.kimi.com/coding/v1';
  static const authHost='https://auth.kimi.com';
  static const clientId='17e5f671-d194-4dfb-9706-5516cb48c098';
  static String key(String id)=>'model_kimi_oauth_$id';
  final _dio=Dio(BaseOptions(connectTimeout:const Duration(seconds:20),receiveTimeout:const Duration(seconds:30),followRedirects:false));
  final _refreshing=<String,Future<String>>{};
  final _epochs=<String,int>{};

  static bool accepts(String url)=>url.replaceFirst(RegExp(r'/+$'),'')==baseUrl;
  Future<Map<String,dynamic>?> saved(String id)async{
    final raw=await storage.read(key:key(id));
    if(raw==null)return null;
    final value=jsonDecode(raw);return value is Map?Map<String,dynamic>.from(value):null;
  }
  Future<Map<String,String>> headers()async{
    var device=prefs.getString('kimiExpertDeviceId');
    if(device==null){device=const Uuid().v4();await prefs.setString('kimiExpertDeviceId',device);}
    return {'User-Agent':'ExpertChat/3.8.1','X-Msh-Platform':'expert_chat','X-Msh-Version':'3.8.1','X-Msh-Device-Id':device};
  }
  Future<Response<dynamic>> _post(String path,Map<String,String> body,CancelToken token)async=>_dio.post<dynamic>(
    '$authHost$path',data:body,cancelToken:token,
    options:Options(contentType:Headers.formUrlEncodedContentType,headers:await headers(),validateStatus:(s)=>s!=null&&s<500));
  Map<String,dynamic> _map(dynamic value)=>value is Map?Map<String,dynamic>.from(value):<String,dynamic>{};
  Map<String,dynamic> _tokens(Map<String,dynamic> data,{String? previousRefresh}){
    final access=data['access_token'],refresh=data['refresh_token']??previousRefresh;
    final expires=int.tryParse('${data['expires_in']}');
    if(access is! String||access.isEmpty||refresh is! String||refresh.isEmpty||expires==null||expires<=0){
      throw StateError('Kimi 授权响应缺少有效令牌或有效期');
    }
    return {'access_token':access,'refresh_token':refresh,'expires_at':DateTime.now().millisecondsSinceEpoch+expires*1000,'expires_in':expires};
  }
  Future<Map<String,dynamic>> signIn(String id,CancelToken token,{
    required void Function(String) onStage,
    required void Function(String url,String code) onDevice,
  })async{
    onStage('正在申请 Kimi Code 设备授权…');
    final response=await _post('/api/oauth/device_authorization',{'client_id':clientId},token);
    final data=_map(response.data);
    if(response.statusCode!=200)throw StateError('Kimi 设备授权未获准（HTTP ${response.statusCode}）');
    final device=data['device_code'],user=data['user_code'];
    final raw=data['verification_uri_complete']??data['verification_uri'];
    final uri=raw is String?Uri.tryParse(raw):null;
    if(device is! String||device.isEmpty||user is! String||user.isEmpty||uri==null||uri.scheme!='https'||
        !(uri.host=='kimi.com'||uri.host.endsWith('.kimi.com')||uri.host=='kimi.ai'||uri.host.endsWith('.kimi.ai'))){
      throw StateError('Kimi 返回的设备授权信息不完整');
    }
    onDevice(uri.toString(),user);
    onStage('请在浏览器确认 Kimi Code 授权');
    try{await launchUrl(uri,mode:LaunchMode.externalApplication);}catch(_){onStage('请复制授权网址到浏览器完成登录');}
    var interval=(int.tryParse('${data['interval']}')??5).clamp(1,60);
    final expires=(int.tryParse('${data['expires_in']}')??900).clamp(1,900);
    final deadline=DateTime.now().add(Duration(seconds:expires));
    while(DateTime.now().isBefore(deadline)){
      await Future.any([Future<void>.delayed(Duration(seconds:interval)),token.whenCancel.then<void>((error)=>throw error)]);
      if(token.isCancelled)throw token.cancelError!;
      final polled=await _post('/api/oauth/token',{'client_id':clientId,'device_code':device,'grant_type':'urn:ietf:params:oauth:grant-type:device_code'},token);
      final result=_map(polled.data);
      if(polled.statusCode==200&&result['access_token'] is String){
        final bundle=_tokens(result);
        onStage('授权成功，正在读取账号信息…');
        final me=await _dio.get<dynamic>('$baseUrl/me',cancelToken:token,
          options:Options(headers:{...await headers(),'Authorization':'Bearer ${bundle['access_token']}'}));
        final account=_map(me.data);
        final accountId=account['user_id']??account['userId'];
        if(accountId is! String||accountId.isEmpty)throw StateError('Kimi 未返回账号身份，请重新登录');
        final previous=await saved(id);
        if(previous?['account_id']!=null&&previous!['account_id']!=accountId)throw StateError('授权账号与原来源不同；请新建订阅来源');
        final displayName=[account['nickname'],account['name'],account['display_name'],account['username'],account['email']]
          .whereType<String>().map((value)=>value.trim()).where((value)=>value.isNotEmpty).firstOrNull??'Kimi Code';
        return {...bundle,'account_id':accountId,'name':displayName,
          if(account['email'] is String)'email':account['email'],
          'plan':account['user_level_name']??''};
      }
      switch(result['error']){
        case 'authorization_pending':continue;
        case 'slow_down':interval=(interval+5).clamp(1,60);continue;
        case 'expired_token':throw StateError('Kimi 授权码已过期，请重新登录');
        case 'access_denied':throw StateError('Kimi 授权已取消或拒绝');
        default:throw StateError('Kimi 登录未完成（HTTP ${polled.statusCode}）');
      }
    }
    throw StateError('Kimi 登录等待超时，请重新登录');
  }
  Future<void> save(String id,Map<String,dynamic> value)async{
    _epochs[id]=(_epochs[id]??0)+1;
    await storage.write(key:key(id),value:jsonEncode(value));
  }
  Future<void> delete(String id)async{
    _epochs[id]=(_epochs[id]??0)+1;
    await storage.delete(key:key(id));
  }
  Future<String> accessToken(String id)async{
    final existing=_refreshing[id];if(existing!=null)return existing;
    final future=_resolve(id);_refreshing[id]=future;
    try{return await future;}finally{if(identical(_refreshing[id],future))_refreshing.remove(id);}
  }
  Future<String> _resolve(String id)async{
    final epoch=_epochs[id]??0;
    final value=await saved(id);
    if(value==null)throw StateError('Kimi Code 尚未登录，请在订阅服务中登录');
    final expires=(value['expires_at'] as num?)?.toInt()??0;
    if(expires>DateTime.now().millisecondsSinceEpoch+60000&&value['access_token'] is String)return value['access_token'] as String;
    final refresh=value['refresh_token'];
    if(refresh is! String||refresh.isEmpty)throw StateError('Kimi 登录已失效，请重新授权');
    final response=await _post('/api/oauth/token',{'client_id':clientId,'grant_type':'refresh_token','refresh_token':refresh},CancelToken());
    final data=_map(response.data);
    if(response.statusCode!=200)throw StateError('Kimi 授权刷新失败（HTTP ${response.statusCode}），请重新登录');
    final current=await saved(id);
    if((_epochs[id]??0)!=epoch||current?['refresh_token']!=refresh)throw StateError('Kimi 登录状态已改变，请重新操作');
    final next={...value,..._tokens(data,previousRefresh:refresh)};
    await storage.write(key:key(id),value:jsonEncode(next));
    return next['access_token'] as String;
  }
}
