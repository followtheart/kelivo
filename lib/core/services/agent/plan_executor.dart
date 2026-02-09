import 'dart:async';
import '../../models/execution_plan.dart';
import '../api/chat_api_service.dart';
import '../../providers/settings_provider.dart';
import 'plan_prompt_builder.dart';

/// Executes an [ExecutionPlan] step-by-step, emitting [PlanExecutionEvent]s
/// so the caller can update the UI in real-time.
class PlanExecutor {
  const PlanExecutor._();

  /// Execute every step in [plan] in dependency order.
  ///
  /// [onToolCall] is the existing tool-call handler produced by
  /// `ToolHandlerService.buildToolCallHandler()`.
  ///
  /// [config] / [modelId] are forwarded to `ChatApiService` for any
  /// intermediate LLM calls (llm_query / aggregate / validate steps).
  ///
  /// Returns a stream of [PlanExecutionEvent] describing progress.
  static Stream<PlanExecutionEvent> execute({
    required ExecutionPlan plan,
    required Future<String> Function(String name, Map<String, dynamic> args)?
        onToolCall,
    required ProviderConfig config,
    required String modelId,
    double? temperature,
    double? topP,
    int? maxTokens,
    int? thinkingBudget,
  }) async* {
    plan.status = PlanStatus.executing;
    yield PlanExecutionEvent(
        kind: PlanEventKind.planCreated, plan: plan);

    final remaining = List<PlanStep>.from(plan.steps);

    while (remaining.isNotEmpty) {
      // Find steps whose dependencies are all satisfied.
      final ready = remaining.where((s) {
        return s.dependsOn.every((dep) {
          final depStep =
              plan.steps.where((ps) => ps.stepId == dep).firstOrNull;
          return depStep != null &&
              (depStep.status == StepStatus.completed ||
                  depStep.status == StepStatus.skipped);
        });
      }).toList();

      if (ready.isEmpty) {
        // No runnable steps and remaining is not empty → deadlock / error.
        plan.status = PlanStatus.failed;
        yield PlanExecutionEvent(
          kind: PlanEventKind.planFailed,
          plan: plan,
          message: 'No runnable steps remaining (possible circular dependency)',
        );
        return;
      }

      // Execute ready steps (currently sequential for simplicity;
      // could be parallelised for independent steps in the future).
      for (final step in ready) {
        step.status = StepStatus.running;
        yield PlanExecutionEvent(
            kind: PlanEventKind.stepStarted, plan: plan, step: step);

        final stopwatch = Stopwatch()..start();
        try {
          final result = await _executeStep(
            step: step,
            plan: plan,
            onToolCall: onToolCall,
            config: config,
            modelId: modelId,
            temperature: temperature,
            topP: topP,
            maxTokens: maxTokens,
            thinkingBudget: thinkingBudget,
          );

          stopwatch.stop();
          step.status = StepStatus.completed;
          step.result = result;
          step.executionTime = stopwatch.elapsed;
          remaining.remove(step);

          yield PlanExecutionEvent(
              kind: PlanEventKind.stepCompleted, plan: plan, step: step);
        } catch (e) {
          stopwatch.stop();
          step.status = StepStatus.failed;
          step.error = e.toString();
          step.executionTime = stopwatch.elapsed;
          remaining.remove(step);

          yield PlanExecutionEvent(
            kind: PlanEventKind.stepFailed,
            plan: plan,
            step: step,
            message: e.toString(),
          );

          // On failure, skip any steps that depend on this one.
          final dependents = remaining
              .where((s) => s.dependsOn.contains(step.stepId))
              .toList();
          for (final dep in dependents) {
            dep.status = StepStatus.skipped;
            dep.error = 'Skipped because dependency ${step.stepId} failed';
            remaining.remove(dep);
            yield PlanExecutionEvent(
              kind: PlanEventKind.stepSkipped,
              plan: plan,
              step: dep,
            );
          }
        }
      }
    }

    // All steps done.
    plan.status = plan.steps.any((s) => s.status == StepStatus.failed)
        ? PlanStatus.failed
        : PlanStatus.completed;
    plan.completedAt = DateTime.now();

    yield PlanExecutionEvent(
      kind: plan.status == PlanStatus.completed
          ? PlanEventKind.planCompleted
          : PlanEventKind.planFailed,
      plan: plan,
    );
  }

  // ---------------------------------------------------------------------------
  // Execute a single step
  // ---------------------------------------------------------------------------

  static Future<String> _executeStep({
    required PlanStep step,
    required ExecutionPlan plan,
    required Future<String> Function(String name, Map<String, dynamic> args)?
        onToolCall,
    required ProviderConfig config,
    required String modelId,
    double? temperature,
    double? topP,
    int? maxTokens,
    int? thinkingBudget,
  }) async {
    switch (step.action) {
      case PlanStepAction.toolCall:
        return _executeToolCall(step, onToolCall);

      case PlanStepAction.llmQuery:
        return _executeLlmQuery(
          step: step,
          plan: plan,
          config: config,
          modelId: modelId,
          temperature: temperature,
          topP: topP,
          maxTokens: maxTokens,
          thinkingBudget: thinkingBudget,
        );

      case PlanStepAction.aggregate:
        return _executeAggregate(
          step: step,
          plan: plan,
          config: config,
          modelId: modelId,
          temperature: temperature,
          topP: topP,
          maxTokens: maxTokens,
          thinkingBudget: thinkingBudget,
        );

      case PlanStepAction.validate:
        return _executeValidate(
          step: step,
          plan: plan,
          config: config,
          modelId: modelId,
          temperature: temperature,
          topP: topP,
          maxTokens: maxTokens,
          thinkingBudget: thinkingBudget,
        );
    }
  }

  // ---------------------------------------------------------------------------
  // Action handlers
  // ---------------------------------------------------------------------------

  static Future<String> _executeToolCall(
    PlanStep step,
    Future<String> Function(String name, Map<String, dynamic> args)? onToolCall,
  ) async {
    final toolName = step.toolName;
    if (toolName == null || toolName.isEmpty) {
      throw StateError('tool_call step "${step.stepId}" has no tool_name');
    }
    if (onToolCall == null) {
      throw StateError('No tool-call handler available');
    }
    return onToolCall(toolName, step.toolArgs ?? const {});
  }

  static Future<String> _executeLlmQuery({
    required PlanStep step,
    required ExecutionPlan plan,
    required ProviderConfig config,
    required String modelId,
    double? temperature,
    double? topP,
    int? maxTokens,
    int? thinkingBudget,
  }) async {
    final previousResults = _gatherDependencyResults(step, plan);
    final userPrompt = PlanPromptBuilder.buildSubQueryUserPrompt(
      stepDescription: step.description,
      previousResults: previousResults,
    );

    return _callLlm(
      config: config,
      modelId: modelId,
      systemPrompt: 'You are a helpful assistant. Answer concisely.',
      userPrompt: userPrompt,
      temperature: temperature,
      topP: topP,
      maxTokens: maxTokens,
      thinkingBudget: thinkingBudget,
    );
  }

  static Future<String> _executeAggregate({
    required PlanStep step,
    required ExecutionPlan plan,
    required ProviderConfig config,
    required String modelId,
    double? temperature,
    double? topP,
    int? maxTokens,
    int? thinkingBudget,
  }) async {
    final stepResults = plan.steps
        .where((s) => s.status == StepStatus.completed)
        .map((s) => {
              'step_id': s.stepId,
              'description': s.description,
              'status': s.status.name,
              'result': s.result ?? '',
            })
        .toList();

    final userPrompt = PlanPromptBuilder.buildSummarisationUserPrompt(
      goal: plan.goal,
      stepResults: stepResults,
    );

    return _callLlm(
      config: config,
      modelId: modelId,
      systemPrompt: PlanPromptBuilder.buildSummarisationSystemPrompt(),
      userPrompt: userPrompt,
      temperature: temperature,
      topP: topP,
      maxTokens: maxTokens,
      thinkingBudget: thinkingBudget,
    );
  }

  static Future<String> _executeValidate({
    required PlanStep step,
    required ExecutionPlan plan,
    required ProviderConfig config,
    required String modelId,
    double? temperature,
    double? topP,
    int? maxTokens,
    int? thinkingBudget,
  }) async {
    final previousResults = _gatherDependencyResults(step, plan);
    final userPrompt =
        'Validate the following results and highlight any issues:\n\n'
        '${previousResults.entries.map((e) => '- ${e.key}: ${e.value}').join('\n')}';

    return _callLlm(
      config: config,
      modelId: modelId,
      systemPrompt:
          'You are a validation assistant. Check correctness and consistency.',
      userPrompt: userPrompt,
      temperature: temperature,
      topP: topP,
      maxTokens: maxTokens,
      thinkingBudget: thinkingBudget,
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Gather results from steps that the current [step] depends on.
  static Map<String, String?> _gatherDependencyResults(
      PlanStep step, ExecutionPlan plan) {
    final results = <String, String?>{};
    for (final depId in step.dependsOn) {
      final dep = plan.steps.where((s) => s.stepId == depId).firstOrNull;
      if (dep != null) {
        results[depId] = dep.result;
      }
    }
    return results;
  }

  /// Make a simple non-streaming LLM call and collect the full response.
  static Future<String> _callLlm({
    required ProviderConfig config,
    required String modelId,
    required String systemPrompt,
    required String userPrompt,
    double? temperature,
    double? topP,
    int? maxTokens,
    int? thinkingBudget,
  }) async {
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': userPrompt},
    ];

    final buf = StringBuffer();
    await for (final chunk in ChatApiService.sendMessageStream(
      config: config,
      modelId: modelId,
      messages: messages,
      temperature: temperature,
      topP: topP,
      maxTokens: maxTokens,
      thinkingBudget: thinkingBudget,
      stream: false,
      requestId: 'plan_step_${DateTime.now().millisecondsSinceEpoch}',
    )) {
      buf.write(chunk.content);
    }
    return buf.toString().trim();
  }
}
