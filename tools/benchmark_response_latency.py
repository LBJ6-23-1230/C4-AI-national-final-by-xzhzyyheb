"""Offline controlled comparison; does not call a provider or load credentials."""
import json
from pathlib import Path
import statistics
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'server/zhixue-agent-server'))
from app.services.embedding_cache import cached_encode, clear
from app.runtime.orchestrator import decide_next_step, fallback_decision


def measure(action):
    start = time.perf_counter()
    result = action()
    return (time.perf_counter() - start) * 1000, result


def main():
    texts = [str(i) for i in range(30)]
    def provider(batch):
        time.sleep(0.05)
        return [[float(t), 1.0] for t in batch]
    def serial():
        return [v for offset in range(0, len(texts), 10) for v in provider(texts[offset:offset+10])]
    samples = {name: [] for name in ('embedding_serial_ms', 'embedding_parallel_ms', 'embedding_cached_ms',
                                    'workflow_before_ms', 'workflow_after_ms')}
    states = [{'profile': {}}, {'profile': {}, 'plan': {}},
              {'profile': {}, 'plan': {}, 'pendingSubmission': True}]
    def model(state):
        time.sleep(0.05)
        return {'step': fallback_decision(state).step}
    for _ in range(5):
        clear()
        elapsed, baseline = measure(serial)
        samples['embedding_serial_ms'].append(elapsed)
        elapsed, actual = measure(lambda: cached_encode(texts, 'benchmark', provider, time.monotonic()+5, 10))
        assert actual == baseline
        samples['embedding_parallel_ms'].append(elapsed)
        elapsed, cached = measure(lambda: cached_encode(texts, 'benchmark', provider, time.monotonic()+5, 10))
        assert cached == baseline
        samples['embedding_cached_ms'].append(elapsed)
        elapsed, before = measure(lambda: [model(state)['step'] for state in states])
        samples['workflow_before_ms'].append(elapsed)
        elapsed, after = measure(lambda: [decide_next_step(state, model).step for state in states])
        assert after == before
        samples['workflow_after_ms'].append(elapsed)
    print(json.dumps({'method': 'offline simulated 50ms provider latency; 5 rounds, median; identical outputs',
                      **{name: round(statistics.median(values), 3) for name, values in samples.items()}}, indent=2))


if __name__ == '__main__':
    main()
