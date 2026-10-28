"""Validate all page questions without hiding unreadable or missing items."""
import re


def normalize(parsed):
    if not isinstance(parsed, dict) or not parsed:
        raise ValueError("vision_invalid_structure")
    legacy = "questions" not in parsed
    rows = [parsed] if legacy else parsed["questions"]
    if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
        raise ValueError("vision_invalid_structure")
    count = parsed.get("questionCount", len(rows))
    if type(count) is not int or count < len(rows) or count < 0:
        raise ValueError("vision_invalid_structure")
    questions = []
    for index, row in enumerate(rows):
        question = str(row.get("questionText") or "").strip()
        readable = row.get("readable") is True and bool(question)
        reply = str(row.get("reply") or "").strip()
        has_solution = bool(reply)
        answer_visible = row.get("answerVisible") is True
        if not readable:
            reply = "本题关键条件不清晰，请补拍此题或补充题干；未生成答案和个人错因。"
        elif not reply:
            # A transcribed question with no solution is not a complete diagnosis.
            reply = "已识别题干，但本题解析未完成，请重试。"
        if re.search(r"(?:没有|未).{0,8}(?:上传|提供|收到).{0,8}(?:图片|题目)|未提供具体错题", reply):
            reply = "图片已接收并读取题干，请先核对识别内容。未提供用户答案时，只能讲解题目，不能判断个人错因。"
        if not answer_visible and re.search(r"你(?:的)?(?:答案|作答|解法|思路)(?:是|存在|有|出现了|出现)?(?:错误|有误)|你错在", reply):
            reply = "已读取题干，但未看到可核验的用户答案或解题过程，暂不能判断个人错因。请核对题干后再补充作答。"
        questions.append({
            "questionNumber": str(row.get("questionNumber") or index + 1),
            "questionText": question,
            "knowledgePoint": str(row.get("knowledgePoint") or "").strip()[:60] if readable else "",
            "wrongType": str(row.get("wrongType") or "")[:80] if readable and answer_visible else "",
            "reply": reply,
            "recognitionStatus": "recognized" if readable and has_solution else ("partial" if readable else "unreadable"),
        })
    complete = (bool(questions) and count == len(questions)
                and (legacy or (parsed.get("complete") is True and "questionCount" in parsed))
                and all(q["recognitionStatus"] == "recognized" for q in questions))
    status = "recognized" if complete else (
        "partial" if any(q["recognitionStatus"] != "unreadable" for q in questions) else "unreadable")
    if legacy and len(questions) == 1 and status == "recognized":
        reply = questions[0]["reply"]
    else:
        header = f"已识别 {len(questions)} 道题，按页面顺序列出。" if complete else (
            f"图片已接收，本次返回 {len(questions)} / {count} 道题；部分题目未识别完整，请核对并补拍或重试。")
        reply = header + "\n\n" + "\n\n".join(
            f"第{q['questionNumber']}题\n题干：{q['questionText']}\n{q['reply']}" for q in questions)
    # Keep single-question clients compatible. Multi-question clients use questions.
    first = questions[0] if questions else {}
    return reply, {"questionText": first.get("questionText", ""),
                   "knowledgePoint": first.get("knowledgePoint", ""),
                   "wrongType": first.get("wrongType", ""),
                   "recognitionStatus": status, "complete": complete,
                   "questionCount": count, "questions": questions}
