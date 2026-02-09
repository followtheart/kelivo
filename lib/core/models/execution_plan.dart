import 'dart:convert';

// ============================================================================
// Enums
// ============================================================================

/// The type of action a plan step performs.
enum PlanStepAction {
  /// Call a registered tool (local, MCP, search, memory, etc.)
  toolCall,

  /// Ask the LLM a sub-question using intermediate context.
  llmQuery,

  /// Aggregate / summarise the results of previous steps.
  aggregate,

  /// Validate or verify a previous step's output.
  validate,
}

/// Status of a single plan step.
enum StepStatus {
  pending,
  running,
  completed,
  failed,
  skipped,
}

/// Overall status of an execution plan.
enum PlanStatus {
  pending,
  executing,
  completed,
  failed,
  cancelled,
}

/// When the plan agent should be activated.
enum PlanMode {
  /// Never plan – go straight to normal generation.
  never,

  /// Automatically decide based on heuristics.
  auto,

  /// Always generate a plan before executing.
  always,
}

// ============================================================================
// PlanStep
// ============================================================================

/// A single step inside an [ExecutionPlan].
class PlanStep {
  PlanStep({
    required this.stepId,
    required this.order,
    required this.description,
    required this.action,
    this.toolName,
    this.toolArgs,
    this.dependsOn = const <String>[],
    this.status = StepStatus.pending,
    this.result,
    this.error,
    this.executionTime,
  });

  final String stepId;
  final int order;
  final String description;
  final PlanStepAction action;
  final String? toolName;
  final Map<String, dynamic>? toolArgs;
  final List<String> dependsOn;

  StepStatus status;
  String? result;
  String? error;
  Duration? executionTime;

  // ---------------------------------------------------------------------------
  // Serialisation helpers
  // ---------------------------------------------------------------------------

  Map<String, dynamic> toJson() => {
        'step_id': stepId,
        'order': order,
        'description': description,
        'action': action.name,
        'tool_name': toolName,
        'tool_args': toolArgs,
        'depends_on': dependsOn,
        'status': status.name,
        'result': result,
        'error': error,
        'execution_time_ms': executionTime?.inMilliseconds,
      };

  factory PlanStep.fromJson(Map<String, dynamic> json) {
    return PlanStep(
      stepId: json['step_id'] as String? ?? 'step_0',
      order: (json['order'] as num?)?.toInt() ?? 0,
      description: json['description'] as String? ?? '',
      action: _parseAction(json['action']),
      toolName: json['tool_name'] as String?,
      toolArgs: json['tool_args'] as Map<String, dynamic>?,
      dependsOn: (json['depends_on'] as List?)?.cast<String>() ?? const [],
      status: _parseStepStatus(json['status']),
      result: json['result'] as String?,
      error: json['error'] as String?,
      executionTime: json['execution_time_ms'] != null
          ? Duration(milliseconds: (json['execution_time_ms'] as num).toInt())
          : null,
    );
  }

  PlanStep copyWith({
    StepStatus? status,
    String? result,
    String? error,
    Duration? executionTime,
  }) {
    return PlanStep(
      stepId: stepId,
      order: order,
      description: description,
      action: action,
      toolName: toolName,
      toolArgs: toolArgs,
      dependsOn: dependsOn,
      status: status ?? this.status,
      result: result ?? this.result,
      error: error ?? this.error,
      executionTime: executionTime ?? this.executionTime,
    );
  }

  static PlanStepAction _parseAction(dynamic v) {
    final s = (v ?? '').toString().toLowerCase();
    switch (s) {
      case 'tool_call':
      case 'toolcall':
        return PlanStepAction.toolCall;
      case 'llm_query':
      case 'llmquery':
        return PlanStepAction.llmQuery;
      case 'aggregate':
        return PlanStepAction.aggregate;
      case 'validate':
        return PlanStepAction.validate;
      default:
        return PlanStepAction.llmQuery;
    }
  }

  static StepStatus _parseStepStatus(dynamic v) {
    final s = (v ?? '').toString().toLowerCase();
    for (final e in StepStatus.values) {
      if (e.name == s) return e;
    }
    return StepStatus.pending;
  }
}

// ============================================================================
// ExecutionPlan
// ============================================================================

/// A structured execution plan produced by the Plan Agent.
class ExecutionPlan {
  ExecutionPlan({
    required this.id,
    required this.goal,
    required this.steps,
    this.status = PlanStatus.pending,
    DateTime? createdAt,
    this.completedAt,
    this.summary,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String goal;
  final List<PlanStep> steps;
  PlanStatus status;
  final DateTime createdAt;
  DateTime? completedAt;
  String? summary;

  // ---------------------------------------------------------------------------
  // Convenience getters
  // ---------------------------------------------------------------------------

  /// The first step that is still pending or running.
  PlanStep? get currentStep {
    for (final s in steps) {
      if (s.status == StepStatus.running) return s;
      if (s.status == StepStatus.pending) return s;
    }
    return null;
  }

  /// All completed steps.
  List<PlanStep> get completedSteps =>
      steps.where((s) => s.status == StepStatus.completed).toList();

  /// Progress ratio (0.0 – 1.0).
  double get progress {
    if (steps.isEmpty) return 1.0;
    final done = steps.where(
        (s) => s.status == StepStatus.completed || s.status == StepStatus.skipped);
    return done.length / steps.length;
  }

  /// Whether there are still steps to execute.
  bool get canProceed =>
      steps.any((s) => s.status == StepStatus.pending);

  // ---------------------------------------------------------------------------
  // Serialisation
  // ---------------------------------------------------------------------------

  Map<String, dynamic> toJson() => {
        'id': id,
        'goal': goal,
        'steps': steps.map((s) => s.toJson()).toList(),
        'status': status.name,
        'created_at': createdAt.toIso8601String(),
        'completed_at': completedAt?.toIso8601String(),
        'summary': summary,
      };

  factory ExecutionPlan.fromJson(Map<String, dynamic> json) {
    return ExecutionPlan(
      id: json['id'] as String? ?? '',
      goal: json['goal'] as String? ?? '',
      steps: (json['steps'] as List?)
              ?.map((e) => PlanStep.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      status: _parsePlanStatus(json['status']),
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : DateTime.now(),
      completedAt: json['completed_at'] != null
          ? DateTime.parse(json['completed_at'] as String)
          : null,
      summary: json['summary'] as String?,
    );
  }

  static PlanStatus _parsePlanStatus(dynamic v) {
    final s = (v ?? '').toString().toLowerCase();
    for (final e in PlanStatus.values) {
      if (e.name == s) return e;
    }
    return PlanStatus.pending;
  }

  /// Encode to JSON string.
  String encode() => jsonEncode(toJson());

  /// Decode from JSON string.
  static ExecutionPlan? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return ExecutionPlan.fromJson(
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}

// ============================================================================
// PlanExecutionEvent
// ============================================================================

/// Events emitted during plan execution so the UI can track progress.
enum PlanEventKind {
  planCreated,
  stepStarted,
  stepCompleted,
  stepFailed,
  stepSkipped,
  planCompleted,
  planFailed,
}

class PlanExecutionEvent {
  const PlanExecutionEvent({
    required this.kind,
    required this.plan,
    this.step,
    this.message,
  });

  final PlanEventKind kind;
  final ExecutionPlan plan;
  final PlanStep? step;
  final String? message;
}
