import 'dart:async';
import 'dart:io';
import 'package:dartssh2/dartssh2.dart';
import '../../data/research/ssh_profile.dart';
import 'research_ssh_contract.dart';

/// Owns the forward listeners and local sockets for one authenticated SSH
/// connection. TCP backpressure is handled by stream piping in both directions.
class SshRemoteForwarding {
  SshRemoteForwarding({this.onError});
  final void Function(String message)? onError;
  final _subscriptions = <StreamSubscription<SSHForwardChannel>>[];
  final _channels = <SSHForwardChannel>{};
  final _sockets = <Socket>{};
  bool _closed = false;
  static const maxConnections = 128;

  Future<void> start(
    SSHClient client,
    List<SshRemoteForward> rules, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    for (final rule in rules) {
      if (_closed) throw ResearchSshException('RemoteForward 已取消');
      final forward = await client
          .forwardRemote(host: rule.bindHost, port: rule.bindPort)
          .timeout(timeout);
      if (_closed) throw ResearchSshException('RemoteForward 已取消');
      if (forward == null) {
        throw ResearchSshException(
          'RemoteForward ${rule.configLine} 被服务器拒绝，请检查监听端口是否占用或服务器是否允许转发',
        );
      }
      _subscriptions.add(
        forward.connections.listen(
          (channel) {
            if (_closed || _channels.length >= maxConnections) {
              channel.destroy();
              return;
            }
            _channels.add(channel);
            unawaited(_bridge(channel, rule, timeout));
          },
          onError: (Object error) {
            if (!_closed) {
              onError?.call('RemoteForward ${rule.configLine} 连接中断：$error');
            }
          },
        ),
      );
    }
  }

  Future<void> _bridge(
    SSHForwardChannel channel,
    SshRemoteForward rule,
    Duration timeout,
  ) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        rule.targetHost,
        rule.targetPort,
        timeout: timeout,
      );
      if (_closed || !_channels.contains(channel)) {
        socket.destroy();
        return;
      }
      _sockets.add(socket);
      await Future.wait([
        channel.stream.cast<List<int>>().pipe(socket),
        socket.cast<List<int>>().pipe(channel.sink),
      ], eagerError: true);
    } catch (error) {
      if (!_closed) {
        onError?.call('RemoteForward ${rule.configLine} 连接本地目标失败：$error');
      }
    } finally {
      _channels.remove(channel);
      channel.destroy();
      if (socket != null) {
        _sockets.remove(socket);
        socket.destroy();
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final channel in _channels.toList()) {
      channel.destroy();
    }
    _channels.clear();
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    _sockets.clear();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    // The owning SSHClient closes immediately afterwards, which releases
    // remote listener registrations even when the transport is unavailable.
  }
}
