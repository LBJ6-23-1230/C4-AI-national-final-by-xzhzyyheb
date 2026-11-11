"""Explicit low-volume provider verification using synthetic, non-user content."""
import json
import logging
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "server" / "zhixue-agent-server"
sys.path.insert(0, str(SERVER))
from dotenv import load_dotenv
load_dotenv(SERVER / ".env")
from app.agent import chat_llm, knowledge
from app.services import llm_health, llm_runtime


def main():
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    result = {"configured": chat_llm.llm_ready(), "textModel": chat_llm.llm_model(),
              "syntheticChunks": 200}
    result["textVerification"], result["textProbeStatus"] = llm_health.verify()
    chunks = [{"chunkId": f"synthetic-{n}", "text": (
        f"Reference {n}. Binary tree postorder traversal visits left subtree, right subtree, then root."),
        "headingPath": "Data structures"} for n in range(200)]
    started = time.monotonic()
    hits, mode = knowledge.search(chunks, "binary tree postorder traversal", 3, use_semantic=True)
    result.update(retrievalMode=mode, hitCount=len(hits), retrievalSeconds=round(time.monotonic() - started, 3))
    target = ROOT / "evidence" / "phase9-live-20261022.json"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    llm_runtime.clear_clients()
    return 0 if result["textVerification"]["verified"] and mode == "hybrid:semantic+keyword+tag" else 1


if __name__ == "__main__":
    raise SystemExit(main())
