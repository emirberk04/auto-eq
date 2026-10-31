"""Plot measurement, target and the L0 profile applied at full and default strength.

Usage: tools/.venv/bin/python tools/plot_profile.py  ->  docs/s12-ultra-l0.png
"""
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from autoeq.frequency_response import FrequencyResponse
from autoeq.peq import PEQ

ROOT = Path(__file__).resolve().parent.parent
RAA = ROOT / "data" / "raa"


def main():
    profile = json.loads((ROOT / "profiles" / "s12-ultra.json").read_text())
    fr = FrequencyResponse.read_csv(RAA / "s12-ultra-siec-fr.csv")
    target = FrequencyResponse.read_csv(RAA / "harman-ie-2019-siec-smoothed.csv")
    f = fr.frequency
    kinds = {"peaking": "PEAKING", "lowShelf": "LOW_SHELF", "highShelf": "HIGH_SHELF"}
    peq = PEQ.from_dict({"filters": [{"type": kinds[x["type"]], "fc": x["frequency"], "q": x["q"],
                                      "gain": x["gain"]} for x in profile["filters"]]}, f, 48000)
    eq = peq.fr
    k = profile["defaultStrength"]
    t = np.interp(np.log(f), np.log(target.frequency), target.raw)
    # Align at the mean level 100 Hz-10 kHz so the comparison is level-independent.
    band = (f >= 100) & (f <= 10000)
    align = lambda y: y - np.mean(y[band] - t[band])

    fig, (a, b) = plt.subplots(2, 1, figsize=(10, 8), sharex=True, gridspec_kw={"height_ratios": [2, 1]})
    a.semilogx(f, t, color="#999", lw=3, label="Harman IE 2019 (SIEC)")
    a.semilogx(f, align(fr.raw), label="S12 Ultra (RAA)")
    a.semilogx(f, align(fr.raw + eq), label="S12 Ultra + L0 (100%)")
    a.semilogx(f, align(fr.raw + k * eq), "--", label=f"S12 Ultra + L0 ({k:.0%})")
    a.set_ylabel("dB"); a.legend(); a.grid(True, which="both", alpha=0.3); a.set_ylim(-20, 20)
    b.semilogx(f, eq, label="L0 EQ (100%)")
    b.semilogx(f, k * eq, "--", label=f"L0 EQ ({k:.0%})")
    b.axvline(10000, color="k", alpha=0.3)
    b.set_ylabel("dB"); b.set_xlabel("Hz"); b.legend(); b.grid(True, which="both", alpha=0.3)
    b.set_xlim(20, 20000)
    out = ROOT / "docs" / "s12-ultra-l0.png"
    fig.tight_layout(); fig.savefig(out, dpi=110)
    print(out)


if __name__ == "__main__":
    main()
