# Faz 0 — Kararlar ve bulgular (2026-10-28)

## Ortam
- MacBook Air M1 (MacBookAir10,1), 8 GB, **macOS 26.6.2 (Tahoe)**.
- Swift 6.2.3 (Command Line Tools 26.2). Tam Xcode yok → Emir kuracak.
  - **CLT'deki SwiftPM bozuk:** boş bir paket bile `PackageDescription` linker hatası veriyor (manifest dylib ile modül sürümleri uyuşmuyor). Xcode kurulunca `xcode-select -s /Applications/Xcode.app` ile çözülür.
- Python: 3.13 (sistem), 3.11 (Homebrew), `uv` var. AutoEq 4.1.2 numpy 1.24'e sabitli olduğundan `tools/.venv` **Python 3.11** ile kuruldu. Faz 5 sidecar için 3.12 ayrıca kurulacak.
- **eqMac kurulu ve varsayılan çıkış şu an `External Headphones (eqMac)`.** Çifte işleme olur (Bölüm 8.5); Faz 1 testlerinden önce kapatılmalı, uygulama da bunu algılayıp uyarmalı.

## Emir'in cevapları
| Soru | Cevap |
|---|---|
| Bağlantı | Dahili 3,5 mm jak (harici DAC yok) → ses seviyesi macOS'tan okunabilir olmalı, L2 mümkün (Faz 6'da doğrula) |
| Kaynak | Music.app → tap yalnızca Music sürecine bağlanabilir (ya da küresel tap; Faz 1'de karar) |
| Xcode | Kuracak |
| mediaremote-adapter | İzin var, isteğe bağlı/kapatılabilir |
| Uygulama adı | Açık (geçici: "S12 Adaptive EQ") |
| Test seti türleri | Açık |

## L0 profili
- Veri: RAA rapor sayfası (id 6146) grafikleri sunucuda vektör çizim komutu olarak gömüyor. `tools/raa_extract.py` eksenleri etiketlerden kalibre edip eğrileri çıkarıyor (çözünürlük ~0,03 dB, 251 nokta). Ham sayfa: `data/raa/s12-ultra-report-6146.html`.
  - Grafik aracı (`param6.php`, dışa aktarma) şu an giriş/CAPTCHA istiyor; kullanılmadı.
  - Çıkarılan "hedef − ölçüm" farkı RAA'nın kendi "Recommended equalization" eğrisiyle 3 kHz altında ±0,2 dB uyuşuyor.
- Hedef: RAA'nın SIEC düzeneği için düzelttiği Harman In-Ear 2019 (+ smoothing).
- `tools/generate_profile.py` → `profiles/s12-ultra.json`: 7 filtre, 20 Hz–10 kHz RMS hata 0,22 dB, en büyük hata 0,75 dB, tam güçte preamp −7,74 dB, varsayılan strength 0,55.
- Grafik: `docs/s12-ultra-l0.png`.
- **Not:** CLAUDE.md "bas hedefle neredeyse üst üste" diyor; bu, RAA grafiğinin dikey hizalamasına bağlı. 100 Hz–10 kHz ortalamasına hizalayınca S12 Ultra bas/alt-ortada hedefin ~3 dB üstünde, 3–4 kHz'te ~7 dB altında. AutoEq (min_mean_error) bu yüzden bası ~3 dB kısıp 3,6 kHz'i ~7 dB yükseltiyor. Aynı şekil, sadece seviye referansı farklı. Kulakla "bas azaldı" gibi gelirse L1 bas kaydırıcısı bunu telafi eder.
