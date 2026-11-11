"""Regression coverage for mixed-point grading through both API entry points."""

from copy import deepcopy

import pytest

from app import create_app
from app.api import exercises
from app.domain.assessment import AssessmentResult
from app.repositories.json_repository import JsonRepository
from app.tools.assessment_tools import grade_exercise


@pytest.mark.parametrize("entry", ["submit", "workflow"])
@pytest.mark.parametrize("correct, expected", [
    ((True, True), (39, 100)),
    ((False, False), (6, 86)),
    ((True, False), (39, 86)),
])
def test_mixed_points_keep_own_baselines_and_survive_restart(tmp_path, entry, correct, expected):
    path = tmp_path / "grading.json"
    client = create_app(path).test_client()
    repo = exercises._repository
    profile = repo.get("profiles", "demo-user")
    template = profile["mastery"][0]
    points = ("binary-tree-postorder", "graph-algorithm", "untouched")
    profile["mastery"] = [dict(template, knowledgePointId=p, masteryScore=score)
                          for p, score in zip(points, (10, 90, 75))]
    repo.save("profiles", "demo-user", profile)
    selected = [next(q for q in exercises._EXERCISE_BANK if q["knowledgePointId"] == p)
                for p in points[:2]]
    answers = [{"exerciseId": q["exerciseId"],
                "answer": exercises._ANSWER_KEYS[q["exerciseId"]] if ok else "WRONG"}
               for q, ok in zip(selected, correct)]
    if entry == "submit":
        url = "/api/v1/exercises/set-demo-data-structures-001/submit"
        payload = {"answers": answers, "idempotencyKey": "mixed"}
    else:
        workflow = client.post("/api/v1/workflows", json={"goal": "混合知识点复习"}).get_json()
        url = f"/api/v1/workflows/{workflow['sessionId']}/run"
        client.post(url, json={})
        payload = {"answers": answers}
    response = client.post(url, json=payload)
    assert response.status_code == 200, response.get_data(as_text=True)
    body = response.get_json()
    assessment = body["assessment"] if entry == "submit" else body["state"]["assessment"]
    updates = {r["knowledgePointId"]: r for r in assessment["masteryUpdates"]}
    assert [(updates[p]["oldScore"], updates[p]["newScore"]) for p in points[:2]] == [
        (10, expected[0]), (90, expected[1])]
    assert all(r["questionCount"] == 1 for r in updates.values())
    saved = repo.get("profiles", "demo-user")
    assert {r["knowledgePointId"]: r["masteryScore"] for r in saved["mastery"]} == dict(
        zip(points, (*expected, 75)))
    assert saved["profileVersion"] == profile["profileVersion"] + 1
    assert len(saved["history"]) == len(profile.get("history", [])) + 2
    for row in saved["history"][-2:]:
        assert row["oldScore"] == {points[0]: 10, points[1]: 90}[row["knowledgePointId"]]
    evidence = saved["evidence"][-1]
    assert set(evidence["perKnowledgeAccuracy"]) == set(points[:2])
    before_retry = deepcopy(saved)
    assert client.post(url, json=payload).status_code == 200
    assert repo.get("profiles", "demo-user") == before_retry
    assert JsonRepository(path).get("profiles", "demo-user") == before_retry


def test_counts_deduplicate_answers_and_primary_is_not_highest_accuracy():
    result = grade_exercise([
        {"exerciseId": "a1", "answer": "A"},
        {"exerciseId": "a1", "answer": "B"},
        {"exerciseId": "a2", "answer": "B"},
        {"exerciseId": "b1", "answer": "A"},
        {"exerciseId": "absent", "answer": "A"},
    ], {"a1": "A", "a2": "A", "b1": "A"},
       {"a1": "a", "a2": "a", "b1": "b"}, old_mastery_by_point={"a": 10, "b": 90})
    assert result.question_counts == {"a": 2, "b": 1}
    assert result.correct_counts == {"a": 0, "b": 1}
    assert result.dominant_knowledge_point() == "a"
    assert result.remediation_knowledge_point() == "a"
    assert AssessmentResult.from_dict(result.to_dict()) == result


def test_unseen_point_uses_zero_even_when_scalar_is_nonzero():
    result = grade_exercise([{"exerciseId": "q", "answer": "A"}], {"q": "A"},
                            {"q": "new"}, old_mastery=90, old_mastery_by_point={"other": 90})
    assert result.old_mastery == 0
    assert result.per_knowledge_mastery == {"new": 29}
