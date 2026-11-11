"""Assessment domain models shared by the API and agent workflow."""

from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class AssessmentResult:
    score: float
    per_knowledge_accuracy: dict[str, float]
    error_types: list[str] = field(default_factory=list)
    old_mastery: int | float = 0
    suggested_new_mastery: int | float = 0
    exercise_result_id: str | None = None
    per_knowledge_mastery: dict[str, int | float] = field(default_factory=dict)
    old_mastery_by_point: dict[str, int | float] = field(default_factory=dict)
    question_counts: dict[str, int] = field(default_factory=dict)
    correct_counts: dict[str, int] = field(default_factory=dict)

    def __post_init__(self) -> None:
        for value in (self.score, self.old_mastery, self.suggested_new_mastery,
                      *self.per_knowledge_mastery.values(), *self.old_mastery_by_point.values()):
            if not 0 <= value <= 100:
                raise ValueError("assessment and mastery scores must be between 0 and 100")

    def dominant_knowledge_point(self) -> str:
        """Most graded questions, then point ID; independent of correctness."""
        return min(self.per_knowledge_accuracy,
            key=lambda p: (-self.question_counts.get(p, 0), p), default="unknown")

    def remediation_knowledge_point(self) -> str:
        """Lowest resulting mastery, then lowest accuracy and stable ID."""
        return min((p for p in self.per_knowledge_accuracy if p != "unknown"),
            key=lambda p: (self.per_knowledge_mastery.get(p, self.suggested_new_mastery),
                self.per_knowledge_accuracy[p], p), default="unknown")

    def mastery_updates(self) -> list[dict[str, Any]]:
        return [{"knowledgePointId": p,
            "oldScore": self.old_mastery_by_point.get(p, self.old_mastery),
            "newScore": self.per_knowledge_mastery.get(p, self.suggested_new_mastery),
            "accuracy": self.per_knowledge_accuracy[p],
            "questionCount": self.question_counts.get(p, 0),
            "correctCount": self.correct_counts.get(p, 0)}
            for p in sorted(self.per_knowledge_accuracy) if p != "unknown"]

    def to_dict(self) -> dict[str, Any]:
        return {"score": self.score,
            "perKnowledgeAccuracy": dict(self.per_knowledge_accuracy),
            "errorTypes": list(self.error_types), "oldMastery": self.old_mastery,
            "suggestedNewMastery": self.suggested_new_mastery,
            "exerciseResultId": self.exercise_result_id,
            "masteryUpdates": self.mastery_updates()}

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "AssessmentResult":
        updates = data.get("masteryUpdates", [])
        return cls(score=data["score"], per_knowledge_accuracy=data.get("perKnowledgeAccuracy", {}),
            error_types=data.get("errorTypes", []), old_mastery=data.get("oldMastery", 0),
            suggested_new_mastery=data.get("suggestedNewMastery", 0),
            exercise_result_id=data.get("exerciseResultId"),
            per_knowledge_mastery={r["knowledgePointId"]: r["newScore"] for r in updates},
            old_mastery_by_point={r["knowledgePointId"]: r["oldScore"] for r in updates},
            question_counts={r["knowledgePointId"]: r["questionCount"] for r in updates},
            correct_counts={r["knowledgePointId"]: r["correctCount"] for r in updates})
