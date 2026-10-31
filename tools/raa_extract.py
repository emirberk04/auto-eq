"""Extract frequency-response curves from a saved Reference Audio Analyzer report page.

RAA renders its charts server-side as canvas drawing commands (moveTo/lineTo in pixel
space). The axis labels are drawn at the same pixel positions as the grid lines, so we
calibrate both axes from the labels and invert the mapping. Precision: 0.1 px in the
source, i.e. ~0.03 dB vertically.

Usage: python tools/raa_extract.py data/raa/s12-ultra-report-6146.html myCanvasv0 data/raa/
"""
import csv
import math
import re
import sys
from pathlib import Path


def canvas_script(page: str, canvas_id: str) -> str:
    for m in re.finditer(r"<script[^>]*>(.*?)</script>", page, re.S):
        if f'"{canvas_id}"' in m.group(1):
            return m.group(1)
    raise SystemExit(f"canvas {canvas_id} not found")


def axis_calibration(js: str):
    labels = re.findall(r'fillText\("(-?[0-9.]+)", ([0-9.]+), ([0-9.]+)\)', js)
    db = [(float(v), float(y)) for v, x, y in labels if float(x) > 500 and float(y) < 334]
    hz = [(float(v), float(x)) for v, x, y in labels if float(y) == 335]
    # dB axis: linear; Hz axis: log10. Fit with two extreme labels, verify the rest.
    (d0, y0), (d1, y1) = db[0], db[-1]
    (f0, x0), (f1, x1) = hz[0], hz[-1]
    y_to_db = lambda y: d0 + (y - y0) * (d1 - d0) / (y1 - y0)
    x_to_hz = lambda x: f0 * (f1 / f0) ** ((x - x0) / (x1 - x0))
    worst = max(abs(math.log10(x_to_hz(x) / f)) for f, x in hz)
    assert worst < 0.002, f"Hz axis is not log-linear (err {worst})"
    return x_to_hz, y_to_db


def curves(js: str):
    names = {}
    for m in re.finditer(r'fillStyle = "([^"]+)";\s*context\.strokeStyle = "[^"]+";.*?fillText\("([^"]+)", 5,', js, re.S):
        names[m.group(1)] = m.group(2)
    for m in re.finditer(r'strokeStyle = "([^"]+)";\s*// fill=\d.*?// count data=\d+.*?(context\.moveTo.*?)context\.stroke', js, re.S):
        pts = [tuple(map(float, p)) for p in re.findall(r"(?:moveTo|lineTo)\(([0-9.-]+),([0-9.-]+)\)", m.group(2))]
        yield names.get(m.group(1), m.group(1)), pts


def main(page_path, canvas_id, out_dir):
    js = canvas_script(Path(page_path).read_text(encoding="latin-1"), canvas_id)
    x_to_hz, y_to_db = axis_calibration(js)
    out = Path(out_dir)
    for name, pts in curves(js):
        slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
        path = out / f"{canvas_id}-{slug}.csv"
        with path.open("w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["frequency", "raw"])
            for x, y in pts:
                w.writerow([f"{x_to_hz(x):.2f}", f"{y_to_db(y):.3f}"])
        print(f"{path}  ({len(pts)} points)  {name}")


if __name__ == "__main__":
    main(*sys.argv[1:4])
