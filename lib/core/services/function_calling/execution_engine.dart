import 'package:flutter/foundation.dart';
import 'models/models.dart';
import 'tool_registry.dart';

/// 执行配置
class ExecutionConfig {
  final Duration timeout;
  final int maxRetries;
  final Duration retryDelay;

  const ExecutionConfig({
    this.timeout = const Duration(seconds: 30),
    this.maxRetries = 1,
    this.retryDelay = const Duration(seconds: 1),
  });
}

/// 执行引擎
///
/// 负责实际执行工具调用，处理超时、重试和安全检查。
class ExecutionEngine {
  final ToolRegistry _registry;
  final ExecutionConfig config;

  /// 用户确认回调 — 当工具 safety == confirm 时调用。
  /// 返回 true 表示用户确认执行，false 取消。
  Future<bool> Function(String toolName, Map<String, dynamic> arguments)?
      onConfirmRequired;

  ExecutionEngine({
    required ToolRegistry registry,
    this.config = const ExecutionConfig(),
    this.onConfirmRequired,
  }) : _registry = registry;

  /// 执行单个工具调用
  Future<ToolResult> execute(
    String toolName,
    Map<String, dynamic> arguments,
    ToolContext context,
  ) async {
    final stopwatch = Stopwatch()..start();

    // 1. 查找定义
    final definition = _registry.getDefinition(toolName);
    if (definition == null) {
      stopwatch.stop();
      return ToolResult.failure(
        'Tool "$toolName" is not registered',
        executionTime: stopwatch.elapsed,
      );
    }

    // 2. 安全检查 — 危险工具直接拒绝
    if (definition.isDangerous) {
      stopwatch.stop();
      return ToolResult.failure(
        'Tool "$toolName" is blocked for safety reasons',
        executionTime: stopwatch.elapsed,
      );
    }

    // 3. 需确认工具 — 弹窗确认
    if (definition.requiresConfirmation && onConfirmRequired != null) {
      final confirmed = await onConfirmRequired!(toolName, arguments);
      if (!confirmed) {
        stopwatch.stop();
        return ToolResult.failure(
          'User cancelled the operation',
          executionTime: stopwatch.elapsed,
        );
      }
    }

    // 4. 查找执行器
    final executor = _registry.getExecutor(toolName);
    if (executor == null) {
      stopwatch.stop();
      return ToolResult.failure(
        'No executor found for tool "$toolName"',
        executionTime: stopwatch.elapsed,
      );
    }

    // 5. 带超时和重试的执行
    int attempt = 0;
    ToolResult? lastResult;

    while (attempt <= config.maxRetries) {
      try {
        lastResult = await executor(toolName, arguments, context)
            .timeout(config.timeout, onTimeout: () {
          return ToolResult.failure(
            'Tool "$toolName" timed out after ${config.timeout.inSeconds}s',
          );
        });

        if (lastResult.success) {
          stopwatch.stop();
          return ToolResult(
            success: true,
            content: lastResult.content,
            imageUrls: lastResult.imageUrls,
            structuredData: lastResult.structuredData,
            executionTime: stopwatch.elapsed,
          );
        }

        // 失败 — 可重试
        attempt++;
        if (attempt <= config.maxRetries) {
          debugPrint(
            '[ExecutionEngine] Tool "$toolName" failed (attempt $attempt), '
            'retrying in ${config.retryDelay.inMilliseconds}ms...',
          );
          await Future.delayed(config.retryDelay);
        }
      } catch (e) {
        attempt++;
        lastResult = ToolResult.failure(e.toString());
        if (attempt <= config.maxRetries) {
          await Future.delayed(config.retryDelay);
        }
      }
    }

    stopwatch.stop();
    return ToolResult(
      success: false,
      content: '',
      errorMessage: lastResult?.errorMessage ?? 'Unknown error',
      executionTime: stopwatch.elapsed,
    );
  }
}
