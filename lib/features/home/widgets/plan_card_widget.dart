import 'package:flutter/material.dart';
import '../../../core/models/execution_plan.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../shared/widgets/ios_tactile.dart';

/// Compact card that shows live progress of an [ExecutionPlan].
///
/// Renders inside the message bubble — similar in style to [_ToolCallItem]
/// in `chat_message_widget.dart`.
class PlanCard extends StatefulWidget {
  const PlanCard({super.key, required this.plan});

  final ExecutionPlan plan;

  @override
  State<PlanCard> createState() => _PlanCardState();
}

class _PlanCardState extends State<PlanCard> {
  bool _expanded = true;

  // ── Icon per step status ──────────────────────────────────────────────
  IconData _stepIcon(StepStatus s) {
    switch (s) {
      case StepStatus.pending:
        return Lucide.Square;
      case StepStatus.running:
        return Lucide.Loader;
      case StepStatus.completed:
        return Lucide.circleCheckBig;
      case StepStatus.failed:
        return Lucide.CircleX;
      case StepStatus.skipped:
        return Lucide.Minus;
    }
  }

  Color _stepColor(ColorScheme cs, StepStatus s) {
    switch (s) {
      case StepStatus.pending:
        return cs.onSurface.withOpacity(0.35);
      case StepStatus.running:
        return cs.primary;
      case StepStatus.completed:
        return Colors.green;
      case StepStatus.failed:
        return cs.error;
      case StepStatus.skipped:
        return cs.onSurface.withOpacity(0.45);
    }
  }

  IconData _actionIcon(PlanStepAction a) {
    switch (a) {
      case PlanStepAction.toolCall:
        return Lucide.Wrench;
      case PlanStepAction.llmQuery:
        return Lucide.MessageCircle;
      case PlanStepAction.aggregate:
        return Lucide.Layers;
      case PlanStepAction.validate:
        return Lucide.Shield;
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final plan = widget.plan;
    final progress = plan.progress;
    final isRunning = plan.status == PlanStatus.executing;
    final isFailed = plan.status == PlanStatus.failed;
    final bg = (isFailed
            ? cs.errorContainer
            : cs.tertiaryContainer)
        .withOpacity(isDark ? 0.25 : 0.30);

    return IosCardPress(
      borderRadius: BorderRadius.circular(16),
      baseColor: bg,
      pressedScale: 1.0,
      duration: const Duration(milliseconds: 260),
      onTap: () => setState(() => _expanded = !_expanded),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header row ──────────────────────────────────────────────
          Row(
            children: [
              if (isRunning)
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
                  ),
                )
              else
                Icon(
                  isFailed ? Lucide.XCircle : Lucide.ListOrdered,
                  size: 18,
                  color: isFailed ? cs.error : cs.secondary,
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  plan.goal.isEmpty ? 'Execution Plan' : plan.goal,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: cs.secondary,
                  ),
                ),
              ),
              // Expand / collapse chevron
              Icon(
                _expanded ? Lucide.ChevronUp : Lucide.ChevronDown,
                size: 16,
                color: cs.onSurface.withOpacity(0.5),
              ),
            ],
          ),

          // ── Progress bar ────────────────────────────────────────────
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 4,
              backgroundColor: cs.onSurface.withOpacity(0.1),
              valueColor: AlwaysStoppedAnimation<Color>(
                isFailed ? cs.error : cs.primary,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${plan.completedSteps.length} / ${plan.steps.length}',
            style: TextStyle(
              fontSize: 11,
              color: cs.onSurface.withOpacity(0.55),
            ),
          ),

          // ── Step list (collapsible) ─────────────────────────────────
          if (_expanded && plan.steps.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...plan.steps.map((step) => _buildStepRow(cs, step)),
          ],
        ],
      ),
    );
  }

  Widget _buildStepRow(ColorScheme cs, PlanStep step) {
    final color = _stepColor(cs, step.status);
    final icon = _stepIcon(step.status);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Step status icon
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: step.status == StepStatus.running
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      valueColor: AlwaysStoppedAnimation<Color>(color),
                    ),
                  )
                : Icon(icon, size: 14, color: color),
          ),
          const SizedBox(width: 8),
          // Action type badge
          Icon(_actionIcon(step.action), size: 12, color: cs.onSurface.withOpacity(0.45)),
          const SizedBox(width: 6),
          // Description
          Expanded(
            child: Text(
              step.description,
              style: TextStyle(
                fontSize: 12,
                color: step.status == StepStatus.skipped
                    ? cs.onSurface.withOpacity(0.4)
                    : cs.onSurface.withOpacity(0.8),
                decoration: step.status == StepStatus.skipped
                    ? TextDecoration.lineThrough
                    : null,
              ),
            ),
          ),
          // Execution time (if finished)
          if (step.executionTime != null)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                '${(step.executionTime!.inMilliseconds / 1000).toStringAsFixed(1)}s',
                style: TextStyle(
                  fontSize: 10,
                  color: cs.onSurface.withOpacity(0.4),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
