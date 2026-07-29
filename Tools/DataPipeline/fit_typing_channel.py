#!/usr/bin/env python3
"""Fit the typing-channel priors from the user's own selection events.

The engine prices every candidate by P(word) * P(form | word): how likely the
user was to write the word fully spelled out (beijing), mixed (beij / meiy),
or as bare initials (bj / dx). The shipped priors (0.80 / 0.13 / 0.07) are
swept, not measured. This script measures them — from the one source that is
not circular: the learning store's event log, exported with

    biling-cli --export-learning /tmp/learning.json

Circularity note, spelled out because it is easy to miss: the derived
evaluation corpora CANNOT be used here. Their keystroke forms were *sampled
from the current prior* by build_eval_corpus.py, so refitting on them returns
the prior you started with plus sampling noise, dressed up as measurement.
The script therefore takes only the event-log export format and refuses
anything without real selection events.

Classification: an event's key is matched against the chosen text's readings
(full pinyin joined, first-syllable + initials, bare initials) via pypinyin.
Events whose key matches none of the three (Latin words, typo-repaired
readings, literal commits) are reported but excluded — they carry no form
information. Laplace smoothing (+1) keeps a small log from zeroing a form.

Output (validated by ScoreModel.TypingChannel before it takes effect):

    ~/Library/Application Support/BiLing/typing-channel.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def classify(key: str, text: str, lazy_pinyin) -> str | None:
    readings = lazy_pinyin(text)
    if not readings or not all(r.isascii() and r.isalpha() for r in readings):
        return None
    full = "".join(readings)
    initials = "".join(r[0] for r in readings)
    mixed = readings[0] + "".join(r[0] for r in readings[1:])
    if key == full:
        return "full"
    if len(readings) > 1 and key == initials:
        return "initials"
    if len(readings) > 1 and key == mixed and mixed not in (full, initials):
        return "mixed"
    return None


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("export", type=Path, help="output of biling-cli --export-learning")
    parser.add_argument(
        "--out",
        type=Path,
        default=Path.home()
        / "Library/Application Support/BiLing/typing-channel.json",
    )
    parser.add_argument("--min-events", type=int, default=200,
                        help="refuse to overwrite the swept prior on less evidence than this")
    args = parser.parse_args()

    try:
        from pypinyin import lazy_pinyin
    except ImportError:
        sys.exit("pypinyin required (the BiLing venv has it).")

    export = json.loads(args.export.read_text())
    events = export.get("events", [])
    if not events:
        sys.exit("No events in the export — this must be a learning-store export, "
                 "not a corpus (see the circularity note in the header).")

    counts = {"full": 0, "mixed": 0, "initials": 0}
    unclassified = 0
    for wrapper in events:
        event = wrapper.get("event", wrapper)
        key, chosen = event.get("pinyin", ""), event.get("chosen", "")
        form = classify(key, chosen, lazy_pinyin) if key and chosen else None
        if form is None:
            unclassified += 1
        else:
            counts[form] += 1

    classified = sum(counts.values())
    print(f"events: {len(events)}  classified: {classified}  excluded: {unclassified}")
    if classified < args.min_events:
        sys.exit(f"REFUSED: {classified} classified events < {args.min_events}. "
                 "The swept prior beats a noisy fit; keep typing and rerun.")

    total = classified + 3  # Laplace
    payload = {
        "schema": "biling-typing-channel",
        "version": 1,
        "full": (counts["full"] + 1) / total,
        "mixed": (counts["mixed"] + 1) / total,
        "initials": (counts["initials"] + 1) / total,
        "fitted_from_events": classified,
    }
    for form, value in counts.items():
        print(f"  {form}: {value}  ->  {payload[form]:.4f}")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(payload, indent=2))
    print(f"wrote {args.out} (takes effect at next engine start; "
          "delete the file to return to the swept prior)")


if __name__ == "__main__":
    main()
