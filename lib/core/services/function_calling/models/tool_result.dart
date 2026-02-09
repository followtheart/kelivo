/// 工具执行结果
class ToolResult {
  final bool success;
  final String content; // 文本结果
  final List<String>? imageUrls; // 图片结果
  final Map<String, dynamic>? structuredData; // 结构化数据
  final String? errorMessage;
  final Duration executionTime;

  const ToolResult({
    required this.success,
    required this.content,
    this.imageUrls,
    this.structuredData,
    this.errorMessage,
    required this.executionTime,
  });

  /// 工厂方法: 成功结果
  factory ToolResult.success(String content, {Duration? executionTime}) {
    return ToolResult(
      success: true,
      content: content,
      executionTime: executionTime ?? Duration.zero,
    );
  }

  /// 工厂方法: 失败结果
  factory ToolResult.failure(String error, {Duration? executionTime}) {
    return ToolResult(
      success: false,
      content: '',
      errorMessage: error,
      executionTime: executionTime ?? Duration.zero,
    );
  }

  /// 转换为 API 响应文本
  String toResponseText() {
    if (!success) {
      return 'Error: ${errorMessage ?? "Unknown error"}';
    }
    return content;
  }

  @override
  String toString() =>
      'ToolResult(success=$success, time=${executionTime.inMilliseconds}ms, '
      '${success ? 'content=${content.length} chars' : 'error=$errorMessage'})';
}
