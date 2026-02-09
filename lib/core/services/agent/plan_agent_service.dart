import 'dart:async';
import 'dart:convert';
import '../../models/execution_plan.dart';
import '../../providers/settings_provider.dart';
import '../api/chat_api_service.dart';
import 'plan_executor.dart';
import 'plan_prompt_builder.dart';

/// Core service that decides whether to plan, generates a plan, executes it,
/// and summarises the results.
///
/// This service is stateless per invocation — it does NOT hold persistent
/// state. Each call to [generatePlan] / [executePlan] is independent.
class PlanAgentService {
  const PlanAgentService();

  // ===========================================================================
  // 1. Should we plan?
  // ===========================================================================

  /// Decide whether the current request should go through the planning path.
  ///
  /// Returns `true` if the plan agent should be activated.
  Future<bool> shouldPlan({
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> toolDefinitions,
    required PlanMode planMode,
    ProviderConfig? config,
    String? modelId,
  }) async {
    // Explicit modes
    if (planMode == PlanMode.always) return true;
    if (planMode == PlanMode.never) return false;

    // --- Auto mode heuristics ---

    // 1. Too few tools → no value in planning.
    if (toolDefinitions.length < 3) return false;

    // 2. Extract the last user message text.
    final lastUser = _extractLastUserMessage(messages);
    if (lastUser.length < 50) return false;

    // 3. Keyword / pattern heuristics.
    const planningIndicators = [
      // Chinese
      '然后', '接着', '首先', '最后', '分别', '对比', '汇总', '综合',
      '同时', '依次', '逐一', '逐个', '步骤',
      // English
      'then', 'first', 'finally', 'compare', 'step by step',
      'one by one', 'each of', 'summarize', 'aggregate',
    ];
    final lower = lastUser.toLowerCase();
    final hasIndicator = planningIndicators.any((kw) => lower.contains(kw));

    if (toolDefinitions.length >= 5 || hasIndicator) {
      // Optional: cheap LLM check when the model/config is available.
      if (config != null && modelId != null) {
        return _quickPlanCheck(lastUser, config, modelId);
      }
      return true;
    }

    return false;
  }

  // ===========================================================================
  // 2. Generate plan
  // ===========================================================================

  /// Call the LLM with a planning system prompt and return a structured
  /// [ExecutionPlan].
  Future<ExecutionPlan> generatePlan({
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> toolDefinitions,
    required String userGoal,
    required ProviderConfig config,
    required String modelId,
    double? temperature,
    double? topP,
    int? maxTokens,
    int? thinkingBudget,
  }) async {
    final systemPrompt = PlanPromptBuilder.buildPlanningSystemPrompt(
      toolDefinitions: toolDefinitions,
    );

    // Build a trimmed message list: system + last user message.
    final apiMessages = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemPrompt},
      {'role': 'user', 'content': userGoal},
    ];

    final buf = StringBuffer();
    await for (final chunk in ChatApiService.sendMessageStream(
      config: config,
      modelId: modelId,
      messages: apiMessages,
      temperature: temperature ?? 0.3, // lower temperature for structured output
      topP: topP,
      maxTokens: maxTokens ?? 2048,
      thinkingBudget: thinkingBudget,
      stream: false,
      requestId: 'plan_gen_${DateTime.now().millisecondsSinceEpoch}',
    )) {
      buf.write(chunk.content);
    }

    final raw = buf.toString().trim();
    return _parsePlanResponse(raw, userGoal);
  }

  // ===========================================================================
  // 3. Execute plan
  // ===========================================================================

  /// Execute a plan step-by-step, returning progress events.
  Stream<PlanExecutionEvent> executePlan({
    required ExecutionPlan plan,
    required Future<String> Function(String name, Map<String, dynamic> args)?
        onToolCall,
    required ProviderConfig config,
    required String modelId,
    double? temperature,
    double? topP,
    int? maxTokens,
    int? thinkingBudget,
  }) {
    return PlanExecutor.execute(
      plan: plan,
      onToolCall: onToolCall,
      config: config,
      modelId: modelId,
      temperature: temperature,
      topP: topP,
      maxTokens: maxTokens,
      thinkingBudget: thinkingBudget,
    );
  }

  // ===========================================================================
  // 4. Summarise results
  // ===========================================================================

  /// After plan execution, call the LLM to produce a human-readable summary.
  Future<String> summariseResults({
    required ExecutionPlan plan,
    required ProviderConfig config,
    required String modelId,
    double? temperature,
    double? topP,
    int? maxTokens,
    int? thinkingBudget,
  }) async {
    // If the plan has an aggregate step whose result is non-empty, use it
    // directly.
    final aggregateStep = plan.steps
        .where(
            (s) => s.action == PlanStepAction.aggregate && s.result != null && s.result!.isNotEmpty)
        .lastOrNull;
    if (aggregateStep != null) {
      return aggregateStep.result!;
    }

    // Otherwise ask the LLM to summarise.
    final stepResults = plan.steps
        .map((s) => {
              'step_id': s.stepId,
              'description': s.description,
              'status': s.status.name,
              'result': s.result ?? s.error ?? '',
            })
        .toList();

    final userPrompt = PlanPromptBuilder.buildSummarisationUserPrompt(
      goal: plan.goal,
      stepResults: stepResults,
    );

    final apiMessages = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': PlanPromptBuilder.buildSummarisationSystemPrompt(),
      },
      {'role': 'user', 'content': userPrompt},
    ];

    final buf = StringBuffer();
    await for (final chunk in ChatApiService.sendMessageStream(
      config: config,
      modelId: modelId,
      messages: apiMessages,
      temperature: temperature,
      topP: topP,
      maxTokens: maxTokens,
      thinkingBudget: thinkingBudget,
      stream: false,
      requestId: 'plan_summary_${DateTime.now().millisecondsSinceEpoch}',
    )) {
      buf.write(chunk.content);
    }
    return buf.toString().trim();
  }

  // ===========================================================================
  // Internal helpers
  // ===========================================================================

  /// Extract the text of the last user message from the API message list.
  String _extractLastUserMessage(List<Map<String, dynamic>> messages) {
    for (var i = messages.length - 1; i >= 0; i--) {
      final msg = messages[i];
      if (msg['role'] == 'user') {
        final content = msg['content'];
        if (content is String) return content;
        if (content is List) {
          // multimodal message — extract text parts
          final textParts = content
              .whereType<Map>()
              .where((p) => p['type'] == 'text')
              .map((p) => p['text']?.toString() ?? '')
              .join(' ');
          return textParts;
        }
        return content?.toString() ?? '';
      }
    }
    return '';
  }

  /// Quick LLM check to decide if planning is needed (low-token).
  Future<bool> _quickPlanCheck(
      String userMessage, ProviderConfig config, String modelId) async {
    try {
      final apiMessages = <Map<String, dynamic>>[
        {
          'role': 'system',
          'content': PlanPromptBuilder.buildQuickCheckSystemPrompt(),
        },
        {
          'role': 'user',
          'content': PlanPromptBuilder.buildQuickCheckUserPrompt(userMessage),
        },
      ];

      final buf = StringBuffer();
      await for (final chunk in ChatApiService.sendMessageStream(
        config: config,
        modelId: modelId,
        messages: apiMessages,
        maxTokens: 32,
        temperature: 0.0,
        stream: false,
        requestId: 'plan_check_${DateTime.now().millisecondsSinceEpoch}',
      )) {
        buf.write(chunk.content);
      }

      final raw = buf.toString().trim();
      return raw.contains('"needs_planning": true') ||
          raw.contains('"needs_planning":true');
    } catch (_) {
      // On error, fall back to not planning.
      return false;
    }
  }

  /// Parse the LLM's JSON plan response into an [ExecutionPlan].
  ExecutionPlan _parsePlanResponse(String raw, String fallbackGoal) {
    // Strip markdown code fences if present.
    var json = raw;
    if (json.startsWith('```')) {
      json = json.replaceFirst(RegExp(r'^```\w*\n?'), '');
      json = json.replaceFirst(RegExp(r'\n?```$'), '');
    }
    json = json.trim();

    try {
      final map = jsonDecode(json) as Map<String, dynamic>;

      // If the model said planning is not needed, return an empty plan.
      final needsPlanning = map['needs_planning'] as bool? ?? true;
      if (!needsPlanning) {
        return ExecutionPlan(
          id: 'plan_${DateTime.now().millisecondsSinceEpoch}',
          goal: (map['goal'] as String?) ?? fallbackGoal,
          steps: const [],
          status: PlanStatus.completed,
        );
      }

      final rawSteps = (map['steps'] as List?) ?? [];
      final steps = <PlanStep>[];
      for (var i = 0; i < rawSteps.length; i++) {
        final s = rawSteps[i] as Map<String, dynamic>;
        s['step_id'] ??= 'step_${i + 1}';
        s['order'] ??= i + 1;
        steps.add(PlanStep.fromJson(s));
      }

      return ExecutionPlan(
        id: 'plan_${DateTime.now().millisecondsSinceEpoch}',
        goal: (map['goal'] as String?) ?? fallbackGoal,
        steps: steps,
      );
    } catch (_) {
      // Failed to parse → return a trivial plan.
      return ExecutionPlan(
        id: 'plan_${DateTime.now().millisecondsSinceEpoch}',
        goal: fallbackGoal,
        steps: const [],
        status: PlanStatus.completed,
      );
    }
  }
}
