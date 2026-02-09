import '../../../providers/settings_provider.dart';

/// 工具调用上下文
///
/// 携带工具执行时所需的会话级上下文信息。
class ToolContext {
  final String conversationId;
  final String? assistantId;
  final ProviderKind providerKind;
  final Map<String, dynamic> metadata;

  const ToolContext({
    required this.conversationId,
    this.assistantId,
    required this.providerKind,
    this.metadata = const {},
  });

  @override
  String toString() =>
      'ToolContext(conv=$conversationId, assistant=$assistantId, '
      'provider=$providerKind)';
}
