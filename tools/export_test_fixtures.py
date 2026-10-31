"""Export AutoEq's own response / coefficients for the L0 profile as Swift test fixtures.

AutoEq negates a1/a2 and returns (a0=1, a1, a2, b0, b1, b2); we store RBJ-normalised
b0 b1 b2 a1 a2 with the usual sign convention.

Usage: tools/.venv/bin/python tools/export_test_fixtures.py
"""
import json
from pathlib import Path

import numpy as np
from autoeq.peq import PEQ

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Tests" / "EQCoreTests" / "Fixtures"
KINDS = {"peaking": "PEAKING", "lowShelf": "LOW_SHELF", "highShelf": "HIGH_SHELF"}


def main():
    profile = json.loads((ROOT / "profiles" / "s12-ultra.json").read_text())
    f = np.geomspace(20, 20000, 200)
    fixture = {}
    for fs in (44100, 48000, 96000):
        peq = PEQ.from_dict({"filters": [{"type": KINDS[x["type"]], "fc": x["frequency"], "q": x["q"],
                                          "gain": x["gain"]} for x in profile["filters"]]}, f, fs)
        coeffs = []
        for filt in peq.filters:
            a0, a1, a2, b0, b1, b2 = filt.biquad_coefficients()
            coeffs.append({"b0": b0, "b1": b1, "b2": b2, "a1": -a1, "a2": -a2})
        fixture[str(fs)] = {"frequencies": f.tolist(), "responseDb": peq.fr.tolist(), "coefficients": coeffs}
    (OUT / "autoeq-s12-ultra-response.json").write_text(json.dumps(fixture))
    print("ok", {k: len(v["coefficients"]) for k, v in fixture.items()})


if __name__ == "__main__":
    main()
