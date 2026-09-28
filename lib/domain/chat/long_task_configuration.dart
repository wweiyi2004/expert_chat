import '../../data/gateway_config.dart';

/// Only the connection settings required by the durable document-job runner.
class LongTaskConfiguration {
  const LongTaskConfiguration({
    required this.gateway,
    required this.gatewayToken,
    required this.systemPrompt,
    this.gatewayTokenProvider,
  });
  final GatewayConfig gateway;
  final String gatewayToken;
  final String systemPrompt;
  final Future<String> Function()? gatewayTokenProvider;
}
