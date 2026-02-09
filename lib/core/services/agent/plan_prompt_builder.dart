/// Builds the system prompt and user prompt used by the Plan Agent
/// to produce a structured [ExecutionPlan] in JSON.
class PlanPromptBuilder {
  const PlanPromptBuilder._();

  // ---------------------------------------------------------------------------
  // Planning system prompt
  // ---------------------------------------------------------------------------

  /// Build the system prompt that instructs the LLM to output a JSON plan.
  ///
  /// [toolDefinitions] – the full list of tool definitions (OpenAI function
  /// format) currently available for this assistant.
  static String buildPlanningSystemPrompt({
    required List<Map<String, dynamic>> toolDefinitions,
  }) {
    final toolList = _formatToolList(toolDefinitions);
    return '''
You are a task-planning assistant. Your ONLY job is to analyse the user's
request and produce a structured execution plan in JSON.

## Available tools
$toolList

## Output format
Return a single JSON object – no markdown fences, no extra text:
{
  "goal": "<concise summary of the user's goal>",
  "needs_planning": true | false,
  "reasoning": "<brief explanation of why planning is / is not needed>",
  "steps": [
    {
      "step_id": "step_1",
      "order": 1,
      "description": "<human-readable step description>",
      "action": "tool_call | llm_query | aggregate | validate",
      "tool_name": "<tool name – only when action is tool_call>",
      "tool_args": { ... },
      "depends_on": []
    }
  ]
}

## Rules
1. Set "needs_planning" to true ONLY when the task genuinely requires
   multiple coordinated steps. Simple single-tool or conversational
   requests should set it to false and return an empty steps array.
2. Use "depends_on" to express ordering constraints (list step_ids).
3. Independent steps should have empty "depends_on" so they can run
   in parallel.
4. The final step is usually "aggregate" to combine results.
5. Keep the plan as concise as possible — avoid unnecessary steps.
6. "tool_name" MUST match one of the available tool names exactly.
7. "tool_args" must conform to the tool's parameter schema.
''';
  }

  // ---------------------------------------------------------------------------
  // Quick-check prompt  (low-token, yes/no)
  // ---------------------------------------------------------------------------

  /// A very short system prompt used for the cheap "do we need a plan?" check.
  static String buildQuickCheckSystemPrompt() {
    return '''
You decide whether a user request needs multi-step planning.
Reply with ONLY a JSON object: {"needs_planning": true} or {"needs_planning": false}.
No other text.
''';
  }

  /// Build the user message for the quick-check call.
  static String buildQuickCheckUserPrompt(String userMessage) {
    return 'Does the following request require multiple coordinated steps '
        '(e.g. calling several tools, comparing results, aggregating data)?\n\n'
        '"""$userMessage"""';
  }

  // ---------------------------------------------------------------------------
  // Summarisation prompt
  // ---------------------------------------------------------------------------

  /// System prompt used to ask the LLM to summarise executed plan results.
  static String buildSummarisationSystemPrompt() {
    return '''
You are a helpful assistant. You will receive the results of a multi-step
execution plan. Summarise them into a clear, well-structured response for
the user. Use the same language the user used in their original question.
''';
  }

  /// User prompt for summarisation.
  static String buildSummarisationUserPrompt({
    required String goal,
    required List<Map<String, dynamic>> stepResults,
  }) {
    final buf = StringBuffer();
    buf.writeln('Goal: $goal\n');
    buf.writeln('Step results:');
    for (final sr in stepResults) {
      final desc = sr['description'] ?? '';
      final result = sr['result'] ?? '(no result)';
      final status = sr['status'] ?? '';
      buf.writeln('- [$status] $desc → $result');
    }
    buf.writeln('\nPlease provide a comprehensive answer based on these results.');
    return buf.toString();
  }

  // ---------------------------------------------------------------------------
  // Sub-query prompt (for llm_query steps)
  // ---------------------------------------------------------------------------

  /// Build a user prompt for an intermediate LLM sub-query step.
  static String buildSubQueryUserPrompt({
    required String stepDescription,
    required Map<String, String?> previousResults,
  }) {
    final buf = StringBuffer();
    buf.writeln(stepDescription);
    if (previousResults.isNotEmpty) {
      buf.writeln('\nContext from previous steps:');
      previousResults.forEach((stepId, result) {
        buf.writeln('- $stepId: ${result ?? "(no result)"}');
      });
    }
    return buf.toString();
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  static String _formatToolList(List<Map<String, dynamic>> toolDefs) {
    if (toolDefs.isEmpty) return '(none)';
    final buf = StringBuffer();
    for (final def in toolDefs) {
      final fn = def['function'] as Map<String, dynamic>?;
      if (fn == null) continue;
      final name = fn['name'] ?? '?';
      final desc = fn['description'] ?? '';
      buf.writeln('- $name: $desc');
    }
    return buf.toString();
  }
}
