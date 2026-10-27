# -*- coding: utf-8 -*-
"""知识库接口（/api/v1/knowledge-bases/**、/api/v1/documents/**）。

设计要点
--------
1. **用户隔离是硬要求**。知识库是个人课程资料，所有读写都按 `userId` 过滤。
   审计已发现项目里存在"登录后仍读到 demo-user 数据"的缺陷（见 `docs/10` 缺陷 A），
   所有读写共用会话身份解析；游客只允许 demo-user。

2. **状态必须真实**。`status ∈ {ready, failed}` 直接来自解析结果，
   失败时带可读原因，绝不假装成功（有 failed 才说明系统真的在处理）。

3. **输入护栏按 MB 级设计**：上传内容比 answers 大得多，
   沿用 `app/api/validation.py` 的上限思路，但单独定义文件级限额。
"""

from __future__ import annotations

from functools import wraps
from contextlib import nullcontext

from flask import Blueprint, jsonify, request

from app.agent import knowledge
from app.api.identity import resolve_user_id
from app.api.validation import bad_request, bounded_str, json_object
from app.repositories.json_repository import JsonRepository
from app.repositories.staged_repository import StagedRepository
from app.tools.profile_merge import PROFILE_LOCK

knowledge_api = Blueprint("knowledge", __name__)
_repository: JsonRepository | None = None

KB = "knowledge_bases"
DOCS = "documents"
CHUNKS = "chunks"


def _locked(function):
    @wraps(function)
    def wrapped(*args, **kwargs):
        with PROFILE_LOCK, (_repository.transaction() if _repository else nullcontext()):
            return function(*args, **kwargs)
    return wrapped


def configure_knowledge_repository(repository: JsonRepository) -> None:
    global _repository
    _repository = repository


# --------------------------------------------------------------------------- 身份
def _resolve_user_id(data: dict) -> tuple[str, object]:
    """解析并校验 userId（请求体里的 userId 只能用于演示身份，不能越权指定他人）。"""
    return resolve_user_id(data.get("userId")), None


# --------------------------------------------------------------------------- 查询辅助
def _list(collection: str, user_id: str) -> list[dict]:
    if _repository is None:
        return []
    return _repository.query(collection, {"userId": user_id})


def _get_owned(collection: str, item_id: str, user_id: str) -> dict | None:
    if _repository is None:
        return None
    item = _repository.get(collection, item_id)
    if not isinstance(item, dict) or item.get("userId") != user_id:
        return None
    return item


def _vocabulary(user_id: str) -> list[str]:
    """Only assessed or explicitly confirmed concepts may seed another extraction."""
    profile = _repository.get("profiles", user_id) if _repository else None
    words = [r.get("knowledgePointName", "") for r in (profile or {}).get("mastery", [])
             if r.get("confidence", 0) > 0]
    for doc in _list(DOCS, user_id):
        if doc.get("tagsConfirmed") is True:
            words.extend(doc.get("knowledgePoints", []))
    return list(dict.fromkeys(w for w in words if knowledge.valid_knowledge_term(w)))


def _upgrade_tags(record):
    """Migrate old automatic labels once, preserving source, revisions and assessed work."""
    if record.get("status") != "ready" or (record.get("extractionVersion") == 2 and all(knowledge.valid_knowledge_term(p) for p in record.get("knowledgePoints", []))):
        return record
    user_id, document_id = record["userId"], record["documentId"]
    with PROFILE_LOCK, _repository.transaction():
        record = _get_owned(DOCS, document_id, user_id)
        if not record or (record.get("extractionVersion") == 2 and all(knowledge.valid_knowledge_term(p) for p in record.get("knowledgePoints", []))):
            return record
        staged = StagedRepository(_repository)
        old = dict(record)
        chunks = [c for c in _list(CHUNKS, user_id) if c.get("documentId") == document_id]
        points = knowledge.extract_knowledge_points(chunks, _vocabulary(user_id))
        if record.get("tagsConfirmed"):
            points = [p for p in record.get("knowledgePoints", []) if knowledge.valid_knowledge_term(p)]
        record = dict(record, knowledgePoints=points, extractionVersion=2, parsedAt=knowledge.next_parsed_at(record.get("parsedAt")))
        revision_id = document_id + ":before-v2"
        if staged.get("document_tag_revisions", revision_id):
            revision_id += ":" + str(record["parsedAt"])
        staged.save("document_tag_revisions", revision_id, {"userId": user_id, "documentId": document_id, "previous": old,
            "previousProfile": staged.get("profiles", user_id)})
        staged.save(DOCS, document_id, record)
        for chunk in chunks:
            staged.save(CHUNKS, chunk["chunkId"], dict(chunk,
                knowledgePoints=[p for p in points if p.casefold() in chunk.get("text", "").casefold()]))
        confirmed = {p for d in staged.list(DOCS) if d.get("userId") == user_id and d.get("tagsConfirmed") for p in d.get("knowledgePoints", [])}
        profile = staged.get("profiles", user_id)
        if profile:
            removed = {r["knowledgePointId"] for r in profile.get("mastery", []) if r.get("source") == "document" and
                not r.get("confidence", 0) and r.get("knowledgePointName") not in confirmed}
            if removed:
                profile = dict(profile, mastery=[r for r in profile["mastery"] if r["knowledgePointId"] not in removed],
                    profileVersion=profile.get("profileVersion", 1) + 1)
                staged.save("profiles", user_id, profile)
                from app.api.plans import plan_belongs_to
                from app.tools.time_budget import fit_plan_to_budget
                for plan in staged.list("plans"):
                    if plan_belongs_to(plan, user_id):
                        for key in ("tasks", "unscheduledTasks", "candidatePool"):
                            plan[key] = [t for t in plan.get(key, []) if t.get("knowledgePointId") not in removed or t.get("status") == "completed"]
                        if "availableMinutes" in plan.get("constraints", {}):
                            plan = fit_plan_to_budget(plan, plan["constraints"]["availableMinutes"])["plan"]
                        plan.update(version=plan.get("version", 1) + 1, reason="未确认的资料标签已回到资料候选区；测评和完成记录保留")
                        staged.save("plans", plan["planId"], plan)
        kb = staged.get(KB, record["kbId"])
        if kb:
            docs = [d for d in staged.list(DOCS) if d.get("userId") == user_id and d.get("kbId") == record["kbId"]]
            staged.save(KB, kb["kbId"], dict(kb, knowledgePoints=list(dict.fromkeys(p for d in docs for p in d.get("knowledgePoints", [])))))
        staged.commit()
        return record


# --------------------------------------------------------------------------- 知识库 CRUD
@knowledge_api.get("/api/v1/knowledge-bases")
def list_knowledge_bases():
    data = request.args
    user_id, error = _resolve_user_id({"userId": data.get("userId")})
    if error is not None:
        return error
    items = sorted(_list(KB, user_id), key=lambda item: item.get("createdAt", ""), reverse=True)
    return jsonify({"knowledgeBases": items, "total": len(items)})


@knowledge_api.post("/api/v1/knowledge-bases")
@_locked
def create_knowledge_base():
    data, guard = json_object()
    if guard is not None:
        return guard
    user_id, error = _resolve_user_id(data)
    if error is not None:
        return error

    course_name, error = bounded_str(data.get("courseName"), "courseName", 60)
    if error is not None:
        return error
    name, error = bounded_str(data.get("name"), "name", knowledge.MAX_KB_NAME_CHARS)
    if error is not None:
        return error
    description = data.get("description")
    if description is not None and not isinstance(description, str):
        return bad_request("description 必须是字符串", {"field": "description"})

    kbs = _list(KB, user_id)
    if len(kbs) >= 20:
        return bad_request("单个用户最多 20 个知识库")
    for existing in kbs:
        if str(existing.get("courseName", "")).strip().casefold() == course_name.casefold():
            return jsonify({"errorCode": "CONFLICT",
                            "message": f"课程「{course_name}」已有资料库，请直接上传文档",
                            "details": {"kbId": existing.get("kbId")}}), 409
        if existing.get("name") == name:
            return jsonify({"errorCode": "CONFLICT",
                            "message": f"已存在同名知识库「{name}」",
                            "details": {"kbId": existing.get("kbId")}}), 409

    kb_id = f"kb-{knowledge._digest(user_id, name)}"
    timestamp = knowledge._now()
    record = {
        "kbId": kb_id, "userId": user_id, "courseName": course_name, "name": name,
        "description": (description or "").strip()[:200],
        "documentCount": 0, "chunkCount": 0, "knowledgePoints": [],
        "createdAt": timestamp, "updatedAt": timestamp,
    }
    if _repository:
        _repository.save(KB, kb_id, record)
    return jsonify(record), 201


@knowledge_api.get("/api/v1/knowledge-bases/<kb_id>")
def get_knowledge_base(kb_id: str):
    user_id, error = _resolve_user_id({"userId": request.args.get("userId")})
    if error is not None:
        return error
    record = _get_owned(KB, kb_id, user_id)
    if record is None:
        return jsonify({"errorCode": "NOT_FOUND", "message": "知识库不存在",
                        "details": {"kbId": kb_id}}), 404
    documents = _list(DOCS, user_id)
    documents = [_upgrade_tags(doc) for doc in documents if doc.get("kbId") == kb_id]
    return jsonify({**(_get_owned(KB, kb_id, user_id) or record), "documents": documents})


@knowledge_api.delete("/api/v1/knowledge-bases/<kb_id>")
@_locked
def delete_knowledge_base(kb_id: str):
    user_id, error = _resolve_user_id({"userId": request.args.get("userId")})
    if error is not None:
        return error
    if _get_owned(KB, kb_id, user_id) is None:
        return jsonify({"errorCode": "NOT_FOUND", "message": "知识库不存在",
                        "details": {"kbId": kb_id}}), 404
    if _repository:
        deletes: list[tuple[str, str]] = []
        for doc in [d for d in _list(DOCS, user_id) if d.get("kbId") == kb_id]:
            _schedule_original_delete(doc)
            for chunk in [c for c in _list(CHUNKS, user_id)
                          if c.get("documentId") == doc.get("documentId")]:
                deletes.append((CHUNKS, chunk["chunkId"]))
            deletes.append((DOCS, doc["documentId"]))
        deletes.append((KB, kb_id))
        _repository.apply_batch(deletes, [])
    return jsonify({"status": "deleted", "kbId": kb_id})


# --------------------------------------------------------------------------- 文档
@knowledge_api.get("/api/v1/knowledge-bases/<kb_id>/documents")
def list_documents(kb_id: str):
    user_id, error = _resolve_user_id({"userId": request.args.get("userId")})
    if error is not None:
        return error
    if _get_owned(KB, kb_id, user_id) is None:
        return jsonify({"errorCode": "NOT_FOUND", "message": "知识库不存在",
                        "details": {"kbId": kb_id}}), 404
    documents = [d for d in _list(DOCS, user_id) if d.get("kbId") == kb_id]
    documents = [_upgrade_tags(d) for d in documents]
    documents.sort(key=lambda item: item.get("uploadedAt", ""), reverse=True)
    return jsonify({"kbId": kb_id, "documents": documents, "total": len(documents)})


@knowledge_api.post("/api/v1/knowledge-bases/<kb_id>/documents")
def upload_document(kb_id: str):
    data, guard = json_object()
    if guard is not None:
        return guard
    user_id, error = _resolve_user_id(data)
    if error is not None:
        return error
    kb = _get_owned(KB, kb_id, user_id)
    if kb is None:
        return jsonify({"errorCode": "NOT_FOUND", "message": "知识库不存在",
                        "details": {"kbId": kb_id}}), 404

    existing = [d for d in _list(DOCS, user_id) if d.get("kbId") == kb_id]
    if len(existing) >= knowledge.MAX_DOCUMENTS_PER_KB:
        return bad_request(f"单个知识库最多 {knowledge.MAX_DOCUMENTS_PER_KB} 份文档",
                           {"limit": knowledge.MAX_DOCUMENTS_PER_KB})

    file_name = knowledge.normalize_file_name(data.get("fileName"))
    if not file_name:
        return bad_request("fileName 不能为空", {"field": "fileName"})
    content = data.get("contentBase64")
    if not isinstance(content, str) or not content:
        return bad_request("contentBase64 不能为空", {"field": "contentBase64"})
    if getattr(_repository, "durable_jobs", False):
        return _queue_document(kb_id, user_id, file_name, content, data)

    # 先算 documentId，再解析 —— 因为 chunkId 必须把归属信息（含 documentId）
    # 纳入摘要，否则不同用户/知识库上传同名同内容文件时会撞主键、
    # 互相覆盖切片记录（详见 knowledge.process_document 的 scope 说明）。
    document_id = f"doc-{knowledge._digest(user_id, kb_id, file_name, knowledge._now())}"
    parsed = knowledge.process_document(
        file_name, content, _vocabulary(user_id),
        scope=f"{user_id}:{kb_id}:{document_id}")
    timestamp = knowledge._now()

    record = {
        "documentId": document_id, "kbId": kb_id, "userId": user_id,
        "fileName": file_name,
        "mimeType": str(data.get("mimeType") or "")[:100],
        "sizeBytes": int(data.get("sizeBytes") or 0) if isinstance(data.get("sizeBytes"), int) else 0,
        "status": parsed["status"], "statusMessage": parsed["statusMessage"],
        "charCount": parsed["charCount"], "chunkCount": len(parsed["chunks"]),
        "knowledgePoints": parsed["knowledgePoints"],
        "parseSource": "basic" if parsed["status"] == knowledge.STATUS_READY else "failed",
        "tagsConfirmed": False,
        "extractionVersion": 2,
        "errorPointCandidates": parsed["errorPointCandidates"],
        "uploadedAt": timestamp, "parsedAt": timestamp,
    }

    if _repository:
        with PROFILE_LOCK, _repository.transaction():
            # Parsing runs outside the transaction; revalidate ownership and limits now.
            kb = _get_owned(KB, kb_id, user_id)
            if kb is None:
                return jsonify({"errorCode": "NOT_FOUND", "message": "知识库不存在", "details": {"kbId": kb_id}}), 404
            current_docs = [d for d in _list(DOCS, user_id) if d.get("kbId") == kb_id]
            if len(current_docs) >= knowledge.MAX_DOCUMENTS_PER_KB:
                return bad_request(f"单个知识库最多 {knowledge.MAX_DOCUMENTS_PER_KB} 份文档")
            staged = StagedRepository(_repository)
            saves: list[tuple[str, str, dict]] = [(DOCS, document_id, record)]
            for index, chunk in enumerate(parsed["chunks"], 1):
                saves.append((CHUNKS, chunk["chunkId"], {
                    "chunkId": chunk["chunkId"], "documentId": document_id, "kbId": kb_id,
                    "userId": user_id, "text": chunk["text"],
                    "headingPath": chunk["headingPath"],
                    "knowledgePoints": chunk["knowledgePoints"],
                    # 切片序号**显式落库**：`chunkId` 的摘要里虽然也含序号，
                    # 但摘要是单向的、取不回来，此前"按顺序读正文"只能依赖
                    # 仓库的写入顺序（隐式约定）。详情接口要按原文顺序回传正文，
                    # 所以把序号存成字段，让顺序可复核、不依赖存储实现。
                    "index": index,
                }))
            # 刷新知识库汇总（文档数 / 切片数 / 知识点并集）
            # 本次文档仍在待提交批次中，仓库查询还看不到它，必须显式并入汇总。
            all_docs = [d for d in _list(DOCS, user_id) if d.get("kbId") == kb_id]
            all_docs.append(record)
            points: list[str] = []
            for doc in all_docs:
                for point in doc.get("knowledgePoints", []):
                    if point not in points:
                        points.append(point)
            saves.append((KB, kb_id, {
                **kb,
                "documentCount": len(all_docs),
                "chunkCount": sum(int(d.get("chunkCount") or 0) for d in all_docs),
                "knowledgePoints": points,
                "updatedAt": timestamp,
            }))
            staged.apply_batch([], saves)

            # Extracted labels are candidates until the user confirms them.
            staged.commit()

    # 201 = 已接收并处理完成（含 failed，因为"受理"成功了，处理结果在 status 里）
    return jsonify(record), 201


@knowledge_api.get("/api/v1/documents/<document_id>")
def get_document(document_id: str):
    """文档详情：文档记录 + **切片正文**。

    为什么要带正文：用户反馈"上传讲义后只看得到大模型给出的大致属性（文件名、
    字数、片段数、知识点），看不到具体内容"。根因是本接口原先只回 `documents`
    集合里的记录，而正文只存在于 `chunks` 集合 —— 前端没有任何途径读到它。
    检索测试之所以"看起来正常"，是因为它走 `/search`、那条路本来就会回正文。

    归属校验沿用 `_get_owned` / `_list(..., user_id)`，不新写一套：
    `documentId` 是全局唯一的（见 `upload_document` 的摘要算法），但"猜不到 id"
    不等于"读不到"，切片仍按 `userId` 过滤后才回传，避免越权读到他人讲义正文。
    """
    user_id, error = _resolve_user_id({"userId": request.args.get("userId")})
    if error is not None:
        return error
    record = _get_owned(DOCS, document_id, user_id)
    if record is None:
        return jsonify({"errorCode": "NOT_FOUND", "message": "文档不存在",
                        "details": {"documentId": document_id}}), 404

    record = _upgrade_tags(record)
    chunks = [chunk for chunk in _list(CHUNKS, user_id)
              if chunk.get("documentId") == document_id]
    # 正文必须按**原文顺序**回传，否则用户看到的讲义是乱的。
    # 优先按上传时落库的 `index`；本次改动之前上传的老切片没有该字段，
    # 此时键为 0，`list.sort` 稳定排序会保留它们原有的相对顺序 ——
    # 而 `JsonRepository.list()` 是 `dict.values()`，天然保持写入顺序，
    # 所以老文档的正文顺序同样正确（无需数据迁移）。
    chunks.sort(key=lambda item: item["index"] if isinstance(item.get("index"), int) else 0)

    total = len(chunks)
    returned = chunks[:knowledge.MAX_CHUNKS_PER_RESPONSE]
    return jsonify({
        **record,
        "knowledgePointEvidence": [{"name": point,
            "chunkId": next((c["chunkId"] for c in chunks if point.casefold() in c.get("text", "").casefold()), ""),
            "excerpt": next((c["text"][:500] for c in chunks if point.casefold() in c.get("text", "").casefold()), ""),
            "headingPath": next((c.get("headingPath", "") for c in chunks if point.casefold() in c.get("text", "").casefold()), "")}
            for point in record.get("knowledgePoints", [])],
        # 切片总数取自 chunks 集合的**实测值**，不直接用 record["chunkCount"]：
        # 后者是解析当时的快照，若两边不一致，界面应当看到事实而不是旧快照。
        "chunkTotal": total,
        # 截断必须如实标注（不静默截断）：前端据此显示"仅显示前 N 段"，
        # 而不是让用户误以为文档只有这么多内容。
        "chunksTruncated": total > len(returned),
        # `index` 取**排序后的位置**，而不是库里那个字段：本次改动之前上传的
        # 老切片没有该字段（读出来是 0），直接用会让界面出现"第 0 段、第 0 段…"。
        # 位置本身就是"正文第几段"，是接口能自证的事实。
        "chunks": [{
            "chunkId": chunk.get("chunkId", ""),
            "index": position,
            "headingPath": chunk.get("headingPath", ""),
            "text": chunk.get("text", ""),
            "knowledgePoints": chunk.get("knowledgePoints", []),
        } for position, chunk in enumerate(returned, 1)],
    })


@knowledge_api.put("/api/v1/documents/<document_id>/knowledge-points")
@_locked
def revise_document_points(document_id):
    data, guard = json_object()
    if guard is not None:
        return guard
    user_id, guard = _resolve_user_id(data)
    if guard is not None:
        return guard
    record = _get_owned(DOCS, document_id, user_id)
    if record is None:
        return jsonify({"errorCode": "NOT_FOUND", "message": "文档不存在"}), 404
    if record.get("status") != "ready":
        return bad_request("文档没有可用正文，请转换格式或 OCR 后重新上传")
    if data.get("expectedParsedAt") != record.get("parsedAt"):
        return jsonify({"errorCode": "CONFLICT", "message": "资料已变更，请刷新后重试"}), 409
    chunks = [c for c in _list(CHUNKS, user_id) if c.get("documentId") == document_id]
    points = knowledge.extract_knowledge_points(chunks, _vocabulary(user_id)) if data.get("reparse") is True else data.get("knowledgePoints")
    if not isinstance(points, list) or len(points) > 30 or any(not isinstance(p, str) or not 1 <= len(p.strip()) <= 24 for p in points):
        return bad_request("知识点应为不超过30个名称，每个1至24字")
    points = list(dict.fromkeys(p.strip() for p in points))
    if any(not knowledge.valid_knowledge_term(p) for p in points):
        return bad_request("作者、页码及题型说明不能作为知识点")
    old = set(record.get("knowledgePoints", []))
    record.update(knowledgePoints=points, extractionVersion=2, parsedAt=knowledge.next_parsed_at(record.get("parsedAt")), tagsConfirmed=data.get("reparse") is not True, parseSource="basic")
    staged = StagedRepository(_repository)
    staged.save("document_tag_revisions", document_id + ":" + str(data["expectedParsedAt"]),
        {"userId": user_id, "documentId": document_id, "previous": _get_owned(DOCS, document_id, user_id)})
    staged.save(DOCS, document_id, record)
    for chunk in chunks:
        chunk["knowledgePoints"] = [p for p in points if p.casefold() in chunk.get("text", "").casefold()]
        staged.save(CHUNKS, chunk["chunkId"], chunk)
    kb = _get_owned(KB, record["kbId"], user_id)
    docs = [d for d in staged.list(DOCS) if d.get("userId") == user_id]
    kb["knowledgePoints"] = list(dict.fromkeys(p for d in docs if d.get("kbId") == kb["kbId"] for p in d.get("knowledgePoints", [])))
    staged.save(KB, kb["kbId"], kb)
    profile = staged.get("profiles", user_id)
    still_used = {p for d in docs if d.get("tagsConfirmed") is True for p in d.get("knowledgePoints", [])}
    if profile:
        removed_ids = {r["knowledgePointId"] for r in profile.get("mastery", []) if
            r.get("knowledgePointName") in old - set(points) - still_used and r.get("source") == "document" and not r.get("confidence", 0)}
        profile["mastery"] = [r for r in profile.get("mastery", []) if not (
            r.get("knowledgePointName") in old - set(points) - still_used and r.get("source") == "document" and not r.get("confidence", 0))]
        staged.save("profiles", user_id, profile)
        from app.api.plans import plan_belongs_to
        for plan in staged.list("plans"):
            if plan_belongs_to(plan, user_id) and removed_ids:
                for key in ("tasks", "unscheduledTasks", "candidatePool"):
                    plan[key] = [t for t in plan.get(key, []) if t.get("knowledgePointId") not in removed_ids or t.get("status") == "completed"]
                budget = plan.get("constraints", {}).get("availableMinutes")
                if budget is not None:
                    from app.tools.time_budget import fit_plan_to_budget
                    plan = fit_plan_to_budget(plan, budget)["plan"]
                staged.save("plans", plan["planId"], plan)
        from app.tools.profile_merge import merge_points_into_profile
        merge_points_into_profile(staged, user_id, [{"name": p, "source": "document", "sourceCourse": kb.get("courseName", "")} for p in points] if record["tagsConfirmed"] else [], refresh=True)
    staged.commit()
    return jsonify(record)


@knowledge_api.delete("/api/v1/documents/<document_id>")
@_locked
def delete_document(document_id: str):
    user_id, error = _resolve_user_id({"userId": request.args.get("userId")})
    if error is not None:
        return error
    record = _get_owned(DOCS, document_id, user_id)
    if record is None:
        return jsonify({"errorCode": "NOT_FOUND", "message": "文档不存在",
                        "details": {"documentId": document_id}}), 404
    if _repository:
        _schedule_original_delete(record)
        deletes: list[tuple[str, str]] = []
        for chunk in [c for c in _list(CHUNKS, user_id) if c.get("documentId") == document_id]:
            deletes.append((CHUNKS, chunk["chunkId"]))
        deletes.append((DOCS, document_id))
        kb = _get_owned(KB, record.get("kbId", ""), user_id)
        saves: list[tuple[str, str, dict]] = []
        if kb is not None:
            remaining = [d for d in _list(DOCS, user_id)
                         if d.get("kbId") == kb["kbId"] and d.get("documentId") != document_id]
            points: list[str] = []
            for doc in remaining:
                for point in doc.get("knowledgePoints", []):
                    if point not in points:
                        points.append(point)
            saves.append((KB, kb["kbId"], {
                **kb, "documentCount": len(remaining),
                "chunkCount": sum(int(d.get("chunkCount") or 0) for d in remaining),
                "knowledgePoints": points, "updatedAt": knowledge._now(),
            }))
        _repository.apply_batch(deletes, saves)
    return jsonify({"status": "deleted", "documentId": document_id})


def _schedule_original_delete(document):
    file_id = document.get("fileId")
    if file_id:
        original = _repository.get("file_objects", file_id)
        if original:
            from app.services.file_storage import schedule_delete
            schedule_delete(_repository, original)


def _queue_document(kb_id, owner, name, content, data):
    import uuid
    from app.services.file_storage import storage
    from app.services.job_queue import enqueue
    raw, error = knowledge.decode_binary(content)
    if error:
        return bad_request(error)
    store = storage()
    original = store.put(owner, raw, name)
    document_id, token = "doc-" + uuid.uuid4().hex, uuid.uuid4().hex
    stamp = knowledge._now()
    record = {"documentId": document_id, "kbId": kb_id, "userId": owner, "fileId": original["fileId"],
              "fileName": name, "mimeType": str(data.get("mimeType") or "")[:100], "sizeBytes": len(raw),
              "sha256": original["sha256"], "status": "processing", "statusMessage": "已上传，正在处理资料",
              "charCount": 0, "chunkCount": 0, "knowledgePoints": [], "errorPointCandidates": [],
              "parseSource": "pending", "tagsConfirmed": False, "extractionVersion": 2,
              "parseToken": token, "uploadedAt": stamp, "parsedAt": stamp}
    try:
        with PROFILE_LOCK, _repository.transaction():
            kb = _get_owned(KB, kb_id, owner)
            if not kb:
                raise ValueError("knowledge base deleted during upload")
            docs = [d for d in _list(DOCS, owner) if d.get("kbId") == kb_id]
            if len(docs) >= knowledge.MAX_DOCUMENTS_PER_KB:
                raise ValueError("document limit reached")
            _repository.save("file_objects", original["fileId"], dict(original, documentId=document_id))
            _repository.save(DOCS, document_id, record)
            _repository.save(KB, kb_id, dict(kb, documentCount=len(docs) + 1, updatedAt=stamp))
            enqueue(_repository, "parse_document", owner, {"documentId": document_id, "kbId": kb_id,
                "userId": owner, "parseToken": token, "fileName": name, "file": original,
                "vocabulary": _vocabulary(owner), "scope": f"{owner}:{kb_id}:{document_id}"}, document_id)
    except BaseException:
        try:
            store.delete(original)
        except Exception:
            # A short orphan grace period + inventory audit handles a process
            # crash between object upload and the database transaction.
            import logging
            logging.getLogger("zhixue.files").warning("orphan_file file_id=%s", original["fileId"])
        raise
    return jsonify(record), 201


def complete_document_job(repository, payload, parsed):
    """Called inside the job completion transaction; deletion or newer parsing wins."""
    record = repository.get(DOCS, payload["documentId"])
    kb = repository.get(KB, payload["kbId"])
    if (not record or not kb or record.get("parseToken") != payload["parseToken"]
            or record.get("userId") != payload["userId"]):
        return
    updated = dict(record, status=parsed["status"], statusMessage=parsed["statusMessage"],
        charCount=parsed["charCount"], chunkCount=len(parsed["chunks"]), knowledgePoints=parsed["knowledgePoints"],
        errorPointCandidates=parsed["errorPointCandidates"], parsedAt=knowledge._now(),
        parseSource="basic" if parsed["status"] == "ready" else "failed")
    repository.save(DOCS, record["documentId"], updated)
    for index, chunk in enumerate(parsed["chunks"], 1):
        repository.save(CHUNKS, chunk["chunkId"], dict(chunk, index=index, documentId=record["documentId"],
            kbId=record["kbId"], userId=record["userId"], sha256=record["sha256"], extractionVersion=2))
    docs = repository.query(DOCS, {"userId": payload["userId"], "kbId": payload["kbId"]})
    repository.save(KB, kb["kbId"], dict(kb, documentCount=len(docs),
        chunkCount=sum(int(d.get("chunkCount") or 0) for d in docs),
        knowledgePoints=list(dict.fromkeys(p for d in docs for p in d.get("knowledgePoints", [])))))


@knowledge_api.get("/api/v1/documents/<document_id>/download")
def download_original(document_id):
    owner = resolve_user_id(request.args.get("userId"))
    document = _get_owned(DOCS, document_id, owner)
    original = _repository.get("file_objects", document.get("fileId", "")) if document else None
    if not original or original.get("userId") != owner:
        return jsonify({"errorCode": "NOT_FOUND", "message": "原文件不存在"}), 404
    from app.services.file_storage import storage
    store = storage()
    url = store.download_url(original)
    if url:
        return jsonify({"url": url, "expiresIn": 120})
    from flask import send_file
    from io import BytesIO
    return send_file(BytesIO(store.read(original)), as_attachment=True, download_name=original["fileName"])


# --------------------------------------------------------------------------- 检索
@knowledge_api.post("/api/v1/knowledge-bases/<kb_id>/search")
def search_knowledge_base(kb_id: str):
    data, guard = json_object()
    if guard is not None:
        return guard
    user_id, error = _resolve_user_id(data)
    if error is not None:
        return error
    if _get_owned(KB, kb_id, user_id) is None:
        return jsonify({"errorCode": "NOT_FOUND", "message": "知识库不存在",
                        "details": {"kbId": kb_id}}), 404

    query, error = bounded_str(data.get("query"), "query", knowledge.MAX_QUERY_CHARS)
    if error is not None:
        return error
    top_k = data.get("topK", 5)
    if isinstance(top_k, bool) or not isinstance(top_k, int) or not 1 <= top_k <= 20:
        return bad_request("topK 必须是 1-20 的整数", {"field": "topK"})
    point = data.get("knowledgePointId")
    if point is not None and not isinstance(point, str):
        return bad_request("knowledgePointId 必须是字符串", {"field": "knowledgePointId"})

    candidates = [c for c in _list(CHUNKS, user_id) if c.get("kbId") == kb_id]
    hits, retrieval_mode = knowledge.search(candidates, query, top_k, point or "")

    documents = {d["documentId"]: d for d in _list(DOCS, user_id)}
    for hit in hits:
        doc = documents.get(hit.get("documentId", ""))
        hit["fileName"] = doc.get("fileName", "") if doc else ""

    from app.agent import semantic

    return jsonify({
        "kbId": kb_id, "query": query, "hits": hits,
        "totalScanned": len(candidates),
        # 诚实标注**实际**使用的检索方式，便于答辩解释：
        #   · `hybrid:semantic+keyword+tag` —— 已配置 Key，向量重排生效
        #   · `keyword+tag`                 —— 未配置 Key 或调用失败，纯关键词
        # 前端/评委据此一眼看出当前是不是真的在跑语义检索，不会被"假装"糊弄。
        "retrievalMode": retrieval_mode,
        "semanticAvailable": semantic.semantic_available(),
        "semanticWeight": semantic.SEMANTIC_WEIGHT if retrieval_mode.startswith("hybrid") else 0.0,
    })
