"""Generate the L0 correction profile (profiles/s12-ultra.json) with AutoEq.

Input: RAA SIEC measurement + RAA's SIEC-corrected Harman In-Ear 2019 target, both
extracted from the report page by tools/raa_extract.py.

Constraints (CLAUDE.md §5.1):
  - at most 8 filters
  - no fitting above 10 kHz
  - |gain| <= 6 dB per filter
  - Q <= 3 everywhere, Q <= 2 for filters above 4 kHz
  - total boost <= +10 dB

Usage: tools/.venv/bin/python tools/generate_profile.py
"""
import json
from pathlib import Path

import numpy as np
from autoeq.frequency_response import FrequencyResponse

ROOT = Path(__file__).resolve().parent.parent
RAA = ROOT / "data" / "raa"
FS = 48000
MAX_F = 10000.0

PEQ_CONFIG = {
    "optimizer": {"min_f": 20.0, "max_f": MAX_F, "min_std": 0.008, "max_time": 30},
    "filter_defaults": {"min_gain": -6.0, "max_gain": 6.0},
    "filters": (
        [{"type": "LOW_SHELF", "fc": 105.0, "q": 0.7}]
        + [{"type": "PEAKING", "min_fc": 20.0, "max_fc": 4000.0, "min_q": 0.4, "max_q": 3.0}] * 5
        # Treble: measurements above ~8 kHz are coupler/insertion-dependent, so a single broad
        # filter centred at or below 8 kHz; its skirt covers 8-10 kHz.
        + [{"type": "PEAKING", "min_fc": 4000.0, "max_fc": 8000.0, "min_q": 0.4, "max_q": 1.0}]
    ),
}


def main():
    fr = FrequencyResponse.read_csv(RAA / "s12-ultra-siec-fr.csv")
    fr.name = "LETSHUOER S12 Ultra (RAA SIEC)"
    target = FrequencyResponse.read_csv(RAA / "harman-ie-2019-siec-smoothed.csv")
    target.name = "Harman In-Ear 2019 (RAA SIEC-corrected)"

    fr.process(target=target, min_mean_error=True, fs=FS, max_gain=10.0)
    peqs = fr.optimize_parametric_eq(PEQ_CONFIG, FS)
    peq = peqs[0]

    filters = [
        {"type": f.__class__.__name__.lower().replace("lowshelf", "lowShelf").replace("highshelf", "highShelf"),
         "frequency": round(float(f.fc), 1), "q": round(float(f.q), 3), "gain": round(float(f.gain), 2)}
        for f in peq.filters
    ]
    filters.sort(key=lambda f: f["frequency"])

    # Residual error vs. desired equalization, 20 Hz - 10 kHz.
    band = (fr.frequency >= 20) & (fr.frequency <= MAX_F)
    peq_fr = np.interp(np.log(fr.frequency), np.log(peq.f), peq.fr)
    residual = fr.equalization[band] - peq_fr[band]
    max_boost = float(np.max(peq.fr))

    profile = {
        "name": "LETSHUOER S12 Ultra -> Harman In-Ear 2019",
        "source": {
            "measurement": "Reference Audio Analyzer, SIEC rig, Summary (R+L), report id 6146",
            "target": "Harman In-Ear 2019 {Correction 711/SIEC + Smoothing} (RAA)",
            "generator": "AutoEq 4.1.2, tools/generate_profile.py",
            "optimized_at_fs": FS,
        },
        "defaultStrength": 0.55,
        "preampDb": round(-max_boost - 0.5, 2),
        "filters": filters,
        "fit": {
            "rmsErrorDb_20Hz_10kHz": round(float(np.sqrt(np.mean(residual**2))), 3),
            "maxAbsErrorDb_20Hz_10kHz": round(float(np.max(np.abs(residual))), 3),
            "maxBoostDb": round(max_boost, 2),
        },
    }
    out = ROOT / "profiles" / "s12-ultra.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(profile, indent=2) + "\n")
    print(json.dumps(profile, indent=2))

    # Comparison table for review.
    for f in [30, 100, 300, 600, 1000, 2000, 3000, 3500, 4000, 5000, 6000, 8000, 10000, 12000, 16000]:
        i = np.argmin(np.abs(fr.frequency - f))
        j = np.argmin(np.abs(peq.f - f))
        print(f"{f:6d} Hz  wanted {fr.equalization[i]:+6.2f}  peq {peq.fr[j]:+6.2f}")


if __name__ == "__main__":
    main()
