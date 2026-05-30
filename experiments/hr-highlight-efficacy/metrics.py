"""
Agreement metrics between a selector's picks and the user's ground-truth picks.

Because exact frames won't match, matching uses a tolerance window with greedy
one-to-one assignment (closest pairs first).
"""

from typing import Dict, List, Tuple


def _match(selected: List[int], truth: List[int], tol: int) -> int:
    """Count one-to-one matches within +/- tol seconds (greedy, closest first)."""
    pairs: List[Tuple[int, int, int]] = []
    for i, sP in enumerate(selected):
        for j, tP in enumerate(truth):
            d = abs(sP - tP)
            if d <= tol:
                pairs.append((d, i, j))
    pairs.sort()
    used_s, used_t, matched = set(), set(), 0
    for _, i, j in pairs:
        if i not in used_s and j not in used_t:
            used_s.add(i); used_t.add(j); matched += 1
    return matched


def score_at_n(selected: List[int], truth: List[int], tol: int = 8) -> Dict[str, float]:
    n = len(selected)
    g = len(truth)
    matched = _match(selected, truth, tol)
    precision = matched / n if n else 0.0
    recall = matched / g if g else 0.0
    f1 = (2 * precision * recall / (precision + recall)) if (precision + recall) else 0.0
    return {"precision": precision, "recall": recall, "f1": f1, "matched": matched}


def _ranks(xs: List[float]) -> List[float]:
    order = sorted(range(len(xs)), key=lambda i: xs[i])
    ranks = [0.0] * len(xs)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and xs[order[j + 1]] == xs[order[i]]:
            j += 1
        avg = (i + j) / 2.0 + 1
        for k in range(i, j + 1):
            ranks[order[k]] = avg
        i = j + 1
    return ranks


def spearman(a: List[float], b: List[float]) -> float:
    """Spearman rank correlation (stdlib only)."""
    if len(a) != len(b) or len(a) < 2:
        return 0.0
    ra, rb = _ranks(a), _ranks(b)
    n = len(a)
    mean_a, mean_b = sum(ra) / n, sum(rb) / n
    num = sum((ra[i] - mean_a) * (rb[i] - mean_b) for i in range(n))
    da = sum((ra[i] - mean_a) ** 2 for i in range(n)) ** 0.5
    db = sum((rb[i] - mean_b) ** 2 for i in range(n)) ** 0.5
    return num / (da * db) if da and db else 0.0
