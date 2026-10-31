# Faz 2 — L0 sabit düzeltme + güvenlik (2026-10-28)

## Zincir (RenderKernel, IO thread)
```
tap ─┬─ 7× biquad (RBJ, Float64, TDF-II) ─ preamp ─┬─ look-ahead limiter (2 ms, −0,5 dBFS) ─┐
     └──────────────── dry ────────────────────────┴─ aynı gecikme ─ seviye eşitleme ───────┴─ 50 ms çapraz geçiş ─ açılış rampası ─ çıkış
```
- Parametreler kontrol tarafında `EQDesign` → `DSPSettings` (sabit boyutlu, referanssız) olarak hesaplanır, `TripleBuffer` ile kilitsiz aktarılır.
- Katsayılar IO thread'de bant parametrelerinden (saf matematik, ayırma yok) **32 karelik bloklarda** hesaplanır. Bant kazançları, preamp ve bypass kazancı dB cinsinden aynı zaman sabitiyle (40 ms, ~120 ms'de oturur) birlikte yumuşar, böylece kuvvet değişiminde zipper veya aşma olmaz (ölçülen aşma +0,03 dB).
- **Otomatik preamp:** 20 Hz–20 kHz arasında toplam yanıtın en büyük artışı + 0,5 dB pay + **1,5 dB kaynak taşma payı**. Tam güçte −9,24 dB (AutoEq'in −7,74'ü + 1,5), %55'te −6,03 dB. Kuvvet %0'da preamp 0 (bit-saydam).
- **Toplam artış tavanı +10 dB:** aşılırsa tüm bantlar orantılı küçültülür (S12 profilinde tam güçte 7,2 dB, devreye girmiyor).
- **Limiter:** stereo bağlı, kayan pencere minimumu + release (100 ms) + kutu ortalaması. Tavanı matematiksel olarak garanti eder. Dry yol aynı gecikmeden geçer ama limiter'e girmez, yani bypass bit düzeyinde aynı kalır.
- **Seviye eşitlemeli A/B:** EQ'nun algısal ses değişimi = A-ağırlıklı, −4,5 dB/oktav (pop LTAS) spektrumda güç ortalaması + preamp. Daha yüksek olan yol kısılır (asla yükseltilmez). %55'te bypass −6,63 dB.
- EQ aç/kapa: 50 ms doğrusal çapraz geçiş.

## Testler (`swift test`, 16 test)
| Test | Sonuç |
|---|---|
| RBJ katsayıları vs AutoEq (44,1/48/96 kHz) | < 1e-9 fark |
| **Gerçek kernel'den impuls → DFT, AutoEq yanıtıyla** (48/96 kHz) | en büyük sapma **2e-7 dB** (kabul ±0,3 dB) |
| Bypass bit-düzeyinde aynılık (tam ölçekli gürültü, tavan üstü tepeler dahil) | 0 fark (sabit 2 ms gecikme dışında) |
| Kuvvet %0 = bypass | bit düzeyinde aynı |
| Tam güç + tam ölçek (3,6 kHz ton + gürültü) | tepe ≤ −0,5 dBFS, limiter devrede |
| −6 dBFS sinüs, tam güç (1 kHz / 3,6 kHz) | limiter boşta, THD+N −149 / −155 dB |
| Kuvvet 0→1 anlık değişim | adım sınırı içinde, aşma +0,03 dB, hedefe ±0,1 dB oturuyor |
| Otomatik preamp / seviye eşitleme | AutoEq preamp'iyle < 0,3 dB fark |
| Triple buffer | en son değer, ara değerler atlanıyor |
| İşleme maliyeti (96 kHz stereo, release) | gerçek zamanın ~%0,5–0,9'u |

## Canlı (MacBook Air M1, 96 kHz, tampon 256)
`eq=true bands=7 preamp=-6.03 dry=-6.63 limited=0 overloads=0`, ölçülen gecikme 58 ms (limiter +2 ms).

### Kaynak taşmaları (2026-10-28)
- İlk sürümde (preamp −4,53) yüksek seviyeli bir parçada limiter zamanın ~%35'inde devredeydi, en fazla −0,9 dB.
- Teşhis log'u (`limiter: … peaks in X / EQ Y dBFS`): **Music.app'in tap'e verdiği ses +1,22 dBFS** tepe yapıyor (AAC çözümleme + 48→96 kHz dönüşümünde örnekler arası taşmalar). EQ tepeyi düşürüyordu (+0,29 dBFS), ama tavanın (−0,5) üstünde kalıyordu.
- Uygulama kapalıyken bu taşmalar Mac'in DAC'ında **sert kırpılıyor**. Uygulama açıkken limiter yumuşakça tutuyordu.
- Çözüm: preamp'e 1,5 dB kaynak taşma payı. Aynı parçada limiter 0 ms.
- Limiter devreye girerse 10 sn'de bir `limiter:` satırı yazılır (süre, en büyük kısma, giriş/EQ tepeleri). Menüde ⚠️ görünür.

## Menü
- **EQ (S12 Ultra → Harman)**: aç/kapa (menü açıkken `E`).
- **A/B'de seviyeyi eşitle**: açıkken bypass, EQ ile aynı algısal seviyeye kısılır. Kapalıyken bypass orijinalle bit düzeyinde aynı.
- **Kuvvet**: %0 / 25 / 40 / 55 (varsayılan) / 70 / 85 / 100.
- Ayarlar kalıcı (UserDefaults).

## Emir'in ilk dinlemesi (2026-10-28)
- "EQ" aç/kapa (seviye eşit, %55): **çok az fark**.
- "Etkin" aç/kapa (uygulama tamamen kapalı ↔ EQ açık): **belirgin fark, Etkin açık tercih**.
- Yorum: "Etkin" karşılaştırması seviye eşitlemesiz. EQ yolu ~4,5–6 dB daha sessiz ve orijinal yol kaynak taşmalarını DAC'ta kırpıyor. Tercih daha sessiz olana gitmiş; bu, yükseklik yanlılığına karşı bir işaret. Ama tonal düzeltmenin değeri için geçerli test seviye eşitlemeli "EQ" anahtarı ve orada fark küçük.
- Faz 2 kabulü: **"kabul edilebilir"**. Daha yüksek kuvvette (%85–100) seviye eşitlemeli A/B ile tekrar denenmeli.
