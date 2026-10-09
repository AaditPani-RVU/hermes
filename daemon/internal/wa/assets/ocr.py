"""Hermes OCR helper: reads one image path per line on stdin, writes one JSON line per image.

Runs inside the venv made by hermes-ocr-setup. Kept alive between images so the models load once.
"""
import json
import sys

from rapidocr import RapidOCR

engine = RapidOCR(params={"Global.log_level": "critical"})
print(json.dumps({"ready": True}), flush=True)

for line in sys.stdin:
    path = line.rstrip("\n")
    if not path:
        continue
    try:
        res = engine(path)
        txts = list(res.txts or ())
        scores = list(res.scores or ())
        boxes = res.boxes if res.boxes is not None else []
        # Keep confident lines, in reading order (top to bottom, then left to right).
        items = []
        for i, t in enumerate(txts):
            if i < len(scores) and scores[i] < 0.6:
                continue
            y, x = (float(boxes[i][0][1]), float(boxes[i][0][0])) if i < len(boxes) else (i, 0)
            items.append((round(y / 12), x, t.strip()))
        items.sort()
        print(json.dumps({"text": "\n".join(t for _, _, t in items if t)}), flush=True)
    except Exception as e:  # one bad image shouldn't kill the worker
        print(json.dumps({"error": str(e)}), flush=True)
