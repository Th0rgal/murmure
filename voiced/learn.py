#!/usr/bin/env python3
"""Personal evaluation, vocabulary suggestion, rule auditing, and overnight
MLX adaptation CLI for Murmure / voiced (inspired by `voiceio learn`).

Usage:
    python3 voiced/learn.py status
    python3 voiced/learn.py eval [--split holdout|all]
    python3 voiced/learn.py suggest
    python3 voiced/learn.py audit
    python3 voiced/learn.py train [--epochs 4]
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
import time
from typing import Any, Dict, List, Optional, Sequence, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import pipeline as vp  # noqa: E402
import worker as w  # noqa: E402


def tokenize_words(text: str) -> List[str]:
    return [tok for tok in re.findall(r"[\w']+", text.lower()) if tok]


def word_error_rate(reference: str, hypothesis: str) -> Tuple[int, int, float]:
    """Returns (edits, ref_word_count, wer) at the word level."""
    ref = tokenize_words(reference)
    hyp = tokenize_words(hypothesis)
    if not ref:
        return (len(hyp), 0, 0.0 if not hyp else 1.0)
    prev = list(range(len(hyp) + 1))
    curr = [0] * (len(hyp) + 1)
    for i, rw in enumerate(ref):
        curr[0] = i + 1
        for j, hw in enumerate(hyp):
            cost = 0 if rw == hw else 1
            curr[j + 1] = min(prev[j + 1] + 1, curr[j] + 1, prev[j] + cost)
        prev, curr = curr, prev
    edits = prev[len(hyp)]
    return edits, len(ref), edits / float(len(ref))


def vocabulary_recall(reference: str, hypothesis: str, vocabulary: Sequence[str]) -> Tuple[int, int]:
    """Returns (matched_terms, expected_terms) for terms appearing in `reference`."""
    ref_lower = reference.lower()
    hyp_lower = hypothesis.lower()
    expected = 0
    matched = 0
    for term in vocabulary:
        tl = term.lower().strip()
        if not tl:
            continue
        pattern = r"(?<![\w])" + re.escape(tl) + r"(?![\w])"
        if re.search(pattern, ref_lower):
            expected += 1
            if re.search(pattern, hyp_lower):
                matched += 1
    return matched, expected


def load_recordings(home: Optional[str] = None, split: Optional[str] = None) -> List[Dict[str, Any]]:
    rec_dir = os.path.join(home or vp.voice_home(), "recordings")
    if not os.path.isdir(rec_dir):
        return []
    items: List[Dict[str, Any]] = []
    for meta_path in sorted(glob.glob(os.path.join(rec_dir, "*.json"))):
        wav_path = meta_path[:-5] + ".wav"
        if not os.path.exists(wav_path):
            continue
        try:
            with open(meta_path, "r", encoding="utf-8") as f:
                meta = json.load(f)
            if split and split != "all" and meta.get("split") != split:
                continue
            meta["wav_path"] = wav_path
            meta["meta_path"] = meta_path
            items.append(meta)
        except (OSError, ValueError):
            continue
    return items


def cmd_status(home: Optional[str] = None) -> Dict[str, Any]:
    base = home or vp.voice_home()
    vocab = vp.load_vocabulary(base)
    corrections = vp.load_corrections(base)
    all_clips = load_recordings(base, split="all")
    holdout = [c for c in all_clips if c.get("split") == "holdout"]
    reviewed = [c for c in all_clips if c.get("reviewed")]
    total_secs = sum(float(c.get("duration_secs", 0.0)) for c in all_clips)
    summary = {
        "voice_home": base,
        "vocabulary_terms": len(vocab),
        "correction_rules": len(corrections),
        "recordings_total": len(all_clips),
        "recordings_holdout": len(holdout),
        "recordings_reviewed": len(reviewed),
        "total_audio_secs": round(total_secs, 1),
    }
    return summary


def cmd_eval(
    home: Optional[str] = None,
    split: str = "all",
    backend=None,
) -> Dict[str, Any]:
    """Replays retained WAV clips through the backend + post-processing pipeline,
    comparing raw vs post-processed WER and vocabulary term recall against the
    ground-truth `reference` (or `text`) field in each recording's JSON metadata.
    """
    base = home or vp.voice_home()
    clips = load_recordings(base, split=split)
    vocab = vp.load_vocabulary(base)
    rules = vp.load_corrections(base)
    worker_inst = w.Worker(backend=backend)

    raw_edits = 0
    post_edits = 0
    total_ref_words = 0
    raw_vocab_hit = 0
    post_vocab_hit = 0
    total_vocab_expected = 0
    total_infer_secs = 0.0
    total_audio_secs = 0.0

    for clip in clips:
        ref = clip.get("reference") or clip.get("text") or ""
        lang = clip.get("language") or "en"
        with open(clip["wav_path"], "rb") as wf:
            wav_bytes = wf.read()
        samples, rate = w.decode_wav(wav_bytes)
        secs = len(samples) / float(rate)
        if not worker_inst.backend.loaded:
            worker_inst.backend.load()
        t0 = time.perf_counter()
        # Allow a clip to store `simulated_raw` for deterministic offline pipeline evaluation
        if "simulated_raw" in clip and isinstance(clip["simulated_raw"], str):
            raw_hyp = clip["simulated_raw"]
        else:
            raw_hyp = worker_inst.backend.transcribe(samples, rate, lang, True)
        infer_secs = time.perf_counter() - t0
        post_hyp = vp.postprocess_transcript(
            raw_hyp,
            language=lang,
            vocabulary=vocab,
            corrections=rules,
        )
        re_d, r_len, _ = word_error_rate(ref, raw_hyp)
        pe_d, _, _ = word_error_rate(ref, post_hyp)
        raw_edits += re_d
        post_edits += pe_d
        total_ref_words += r_len

        r_hit, v_exp = vocabulary_recall(ref, raw_hyp, vocab)
        p_hit, _ = vocabulary_recall(ref, post_hyp, vocab)
        raw_vocab_hit += r_hit
        post_vocab_hit += p_hit
        total_vocab_expected += v_exp
        total_infer_secs += infer_secs
        total_audio_secs += secs

    raw_wer = (raw_edits / float(total_ref_words)) if total_ref_words else 0.0
    post_wer = (post_edits / float(total_ref_words)) if total_ref_words else 0.0
    raw_recall = (raw_vocab_hit / float(total_vocab_expected)) if total_vocab_expected else 1.0
    post_recall = (post_vocab_hit / float(total_vocab_expected)) if total_vocab_expected else 1.0

    return {
        "clips": len(clips),
        "total_audio_secs": round(total_audio_secs, 2),
        "total_infer_secs": round(total_infer_secs, 3),
        "raw_wer": round(raw_wer, 4),
        "post_wer": round(post_wer, 4),
        "raw_vocab_recall": round(raw_recall, 4),
        "post_vocab_recall": round(post_recall, 4),
        "improved_or_equal": post_wer <= raw_wer and post_recall >= raw_recall,
    }


def cmd_audit(home: Optional[str] = None) -> Dict[str, Any]:
    """Audits `corrections.json` for risky rules (short keys <= 3 chars, rules that
    shadow common words, or rules that contradict reviewed transcripts).
    """
    base = home or vp.voice_home()
    rules = vp.load_corrections(base)
    clips = load_recordings(base, split="all")
    warnings: List[str] = []

    for wrong, right in sorted(rules.items()):
        if len(wrong.strip()) <= 3:
            warnings.append(f"short key '{wrong}' -> '{right}' may false-trigger on short words")
        if wrong.lower() == right.lower():
            warnings.append(f"redundant rule '{wrong}' -> '{right}' (use vocabulary.txt for casing)")
        for clip in clips:
            if not clip.get("reviewed"):
                continue
            ref = (clip.get("reference") or clip.get("text") or "").lower()
            pattern = r"(?<![\w])" + re.escape(wrong.lower()) + r"(?![\w])"
            if re.search(pattern, ref):
                warnings.append(
                    f"rule '{wrong}' -> '{right}' contradicts reviewed clip {clip.get('id')} where '{wrong}' was intentional"
                )
    return {"rules_checked": len(rules), "warnings": warnings}


def cmd_suggest(home: Optional[str] = None) -> Dict[str, Any]:
    """Finds capitalized or unusual tokens across retained transcripts that are not
    yet in `vocabulary.txt` and suggests them.
    """
    base = home or vp.voice_home()
    vocab_lower = {v.lower() for v in vp.load_vocabulary(base)}
    clips = load_recordings(base, split="all")
    counts: Dict[str, int] = {}
    for clip in clips:
        text = clip.get("reference") or clip.get("text") or ""
        for sentence in re.split(r"[.!?]+\s*", text):
            words = sentence.strip().split()
            # Look at non-sentence-initial capitalized words or camelCase/digits words
            for idx, raw_w in enumerate(words):
                w_clean = raw_w.strip(".,!?;:\"'()[]{}")
                if len(w_clean) < 4 or w_clean.lower() in vocab_lower:
                    continue
                is_mid_cap = idx > 0 and w_clean[0].isupper()
                is_mixed = any(c.isupper() for c in w_clean[1:]) or any(c.isdigit() for c in w_clean)
                if is_mid_cap or is_mixed:
                    counts[w_clean] = counts.get(w_clean, 0) + 1
    suggestions = [k for k, _ in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))]
    return {"suggestions": suggestions}


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(prog="murmure-learn", description="Personal evaluation and vocabulary tools for Murmure")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status", help="Show corpus, vocabulary, and corrections counts")
    p_eval = sub.add_parser("eval", help="Evaluate WER and vocabulary recall on retained clips")
    p_eval.add_argument("--split", default="all", choices=["all", "holdout", "train"])
    sub.add_parser("audit", help="Audit corrections.json for risky or contradictory rules")
    sub.add_parser("suggest", help="Suggest new vocabulary terms from retained transcripts")

    args = parser.parse_args(argv)
    if args.cmd == "status":
        out = cmd_status()
    elif args.cmd == "eval":
        out = cmd_eval(split=args.split)
    elif args.cmd == "audit":
        out = cmd_audit()
    elif args.cmd == "suggest":
        out = cmd_suggest()
    else:
        return 1
    print(json.dumps(out, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
