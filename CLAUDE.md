# S12 Adaptive EQ — macOS için şarkıya duyarlı, LETSHUOER S12 Ultra'ya özel EQ uygulaması

Bu dosya Claude Code için proje şartnamesidir. Kod yazmaya başlamadan önce baştan sona oku.
Proje sahibi Emir, iletişim dili **Türkçe**. Kod, değişken adları ve commit mesajları İngilizce olabilir; açıklamalar ve sorular Türkçe.

---

## 0. Çalışma kuralları (Claude Code için)

1. **Önce Faz 0'ı yap** (Bölüm 9). Açık soruları Emir'e sor, sonra kodla.
2. **Faz faz ilerle.** Bir fazın "kabul kriterleri" geçmeden sonrakine geçme. Her faz sonunda çalışan bir şey olmalı.
3. **Gerçek zamanlı ses iş parçacığı kurallarına** (Bölüm 7) uy. İhlal ederse ses cızırdar. Bu projede en sık yapılan hata budur.
4. **Ses kalitesini bozma.** Bypass modunda ses, uygulama hiç yokmuş gibi duyulmalı (Bölüm 8).
5. **Kulak son hakemdir.** Bu dosyadaki sayısal değerler araştırmaya ve ölçümlere dayalı *başlangıç hipotezleridir*. Emir'in kulağıyla A/B testi yapılmadan "doğru" kabul edilmez.
6. **Yakalanan sesi asla diske yazma.** Sadece türetilmiş sayısal özellikler (spektrum, tilt, LUFS vb.) saklanır. (Gizlilik + Apple Music DRM/kullanım koşulları.)
7. Belirsiz kalan bir şey varsa tahmin etme, sor. Bu dosyada "DOĞRULA" işaretli yerler henüz doğrulanmamış bilgidir.
8. Her fazda test yaz (Bölüm 10). Commit'leri küçük tut.

---

## 1. Amaç ve kapsam

**Ne yapıyoruz:** Mac'te Apple Music (ve istenirse tüm sistem sesi) çalarken sesi gerçek zamanlı yakalayan, şu katmanlarla işleyen, kulaklığa gönderen bir menü çubuğu uygulaması:

1. S12 Ultra'yı Harman In-Ear 2019 hedefine yaklaştıran **sabit düzeltme** (her zaman açık).
2. Emir'in **kişisel tercih** ayarı (bas/tiz).
3. İsteğe bağlı **ses seviyesine bağlı** loudness telafisi (ISO 226).
4. Şarkının tonal dengesine göre **yavaş ve sınırlı** uyarlama.
5. Tür/stil bilgisinden gelen **küçük** ayarlar (v1'de kapalı, sonra açılacak).
6. Güvenlik katmanı: otomatik preamp + limiter.

**Kullanıcı:** Sadece Emir. Dağıtım, App Store, çoklu kulaklık desteği, hesap sistemi yok. Tek kulaklık: LETSHUOER S12 Ultra.

**Platform:** MacBook (Apple Silicon M1, bellek kayıtlarına göre). macOS sürümü Faz 0'da doğrulanacak. Minimum hedef **macOS 14.4**.

**Başarı ölçütü:** Emir, "EQ kapalı" ile "EQ açık" seviyesi eşitlenmiş A/B testinde çoğunlukla açık hâli seçiyor ve aylarca açık bırakıyor.

---

## 2. Kulaklık gerçekleri (S12 Ultra)

- 14,8 mm planar manyetik sürücü, 16 Ω, 101 dB duyarlılık, 20 Hz–40 kHz (üretici). Telefon dongle'ından sürülebilir, iyi DAC/amfiyle ölçeklenir.
- Ses karakteri (incelemelere göre): S12 Pro'dan daha sıcak ve daha pürüzsüz. Bas dengeli, alt bas güçlü.
- S12 serisi bas EQ'yu bozulmadan kaldırıyor (TechPowerUp S12 incelemesi). Yine de büyük bas artışlarında kısa bir bozulma kontrolü yap (Faz 2).
- **Ölçüm (Reference Audio Analyzer, SIEC düzeneği, Harman In-Ear 2019 hedefi, ham/kompanzasyonsuz):**
  - Bas ve alt-orta (30 Hz–1 kHz): hedefle neredeyse üst üste.
  - 2,5–5 kHz: hedef bu bölgede belirgin tepe yapıyor (yaklaşık +8 dB), S12 Ultra yaklaşık 4–6 dB altında.
  - 6–7 kHz: hedefin 2–3 dB altında. 10 kHz civarı: hedefe yakın.
  - RAA'nın "Recommended equalization" eğrisi: ~0 dB (30 Hz–500 Hz), +1,5…+2 dB (600 Hz–1 kHz), ~+1 dB (2 kHz), **~+8,5 dB zirve (3,5–4 kHz)**, ~+5 dB (6–10 kHz).
  - **Bu sayılar ekran görüntüsünden gözle okundu, kesin değildir.** Gerçek filtreler Faz 2'de ölçüm verisinden üretilecek (Bölüm 5.1).
- Kaynak sayfa: https://reference-audio-analyzer.pro/en/report-pro-hp-target.php?id=6146

### Ölçümlerin sınırları (EQ tasarımını etkiler)
- Ölçüm kaplinleri genelde ~10 kHz'e kadar güvenilir. **8 kHz üstündeki dar tepe ve çukurlara güvenme.**
- Ekleme derinliği ve uç (tip) farkı 2 kHz üstünü değiştirir; bas ise sızdırmazlığa (seal) bağlıdır.
- Birim farkı (unit variation) gerçek: Emir'in cihazı ölçülenden farklı olabilir.
- Sonuç: Yüksek frekansta **geniş Q, düşük gain**; dar ve yüksek gain'li filtre yok.

---

## 3. Temel kararlar ve gerekçeleri

| Konu | Karar | Gerekçe |
|---|---|---|
| Ses yakalama | **Core Audio process tap** (`AudioHardwareCreateProcessTap`) + private aggregate device | BlackHole gibi sanal sürücü gerekmiyor, sistem ses seviyesi kontrolü korunuyor, DRM'li sesi bozmadığı belirtiliyor (iQualize mimari sayfası). macOS 14.2'de geldi; izin penceresi ve kararlılık için 14.4+ hedefle. |
| Yakalama alternatifleri | ScreenCaptureKit (yedek), BlackHole (son çare) | SCK ekran yakalama bağlamı ister. BlackHole kurulum ve yönlendirme yükü getirir. |
| Ses motoru dili | **Swift** (Accelerate/vDSP, AVFAudio, Core Audio) | Gerçek zamanlı iş parçacığında GIL, GC, ayrılan bellek sorunu yok. Python ses motoru için riskli. |
| Analiz (ağır) | **Python yan süreç (sidecar)**: Essentia + librosa | Tür/stil ve BPM modelleri Python'da hazır. Ses iş parçacığından ayrı süreçte çalışır. |
| Hafif analiz | Swift içinde vDSP FFT | LTAS, tilt, LUFS, crest factor gibi ucuz özellikler gecikmesiz hesaplanır. |
| Filtre | Parametrik biquad (RBJ cookbook), **Float64 işleme**, minimum faz IIR | Düşük frekansta yüksek Q'da Float32 gürültü ve kararlılık sorunu çıkarabilir. FIR gecikme ekler, gerek yok. |
| Hedef eğri | **Harman In-Ear 2019** (başlangıç) | Olive'ın 2024 çalışmasında en çok tercih edilenlerden biri (SoundGuys eğrisiyle istatistiksel eşit). Dinleyicilerin bir kısmı farklı bas tercih eder (aşağıda). |
| Filtre üretimi | **AutoEq** algoritması (Python) | Ölçüm → hedef → PEQ filtreleri. Preamp'i de hesaplıyor. |
| Şarkı kimliği | Önce **ses tabanlı** değişim algılama. İsteğe bağlı `mediaremote-adapter` | Aşağıdaki "metadata" notuna bak. |

### Metadata hakkında önemli not (DOĞRULA)
- Music.app'in AppleScript `current track` özelliği macOS Tahoe'da kütüphanede olmayan (streaming) parçalar için hata veriyor. Apple Developer Forums ve Keyboard Maestro forumunda raporlar var. **Bu yoldan `genre`/`bpm` okumaya güvenme.**
- macOS 15.4'ten beri MediaRemote'a normal uygulamalar erişemiyor. `ungive/mediaremote-adapter` sistemin entitlement'lı `/usr/bin/perl`'ünü kullanarak bunu 15.4 ve üstünde aşıyor (proje bunu iddia ediyor; ayrı bir JXA yönteminin macOS 26 beta 1'de çalıştığı da bildirilmiş; Emir'in sürümünde DOĞRULA). Özel API'ye dayandığı için **kırılabilir**; sadece "parça değişti / başlık / sanatçı" için isteğe bağlı kullan.
- Streaming parçalarda Music.app BPM etiketi genelde 0 döner (bir Apple Music MCP projesinin notu). **BPM'i metadata'dan değil sesten hesapla.**
- ShazamKit parça kimliği ve `genres` döndürebilir, ama Apple Developer hesabı/yetkilendirme gereksinimleri belirsiz. Faz 5'te değerlendir, zorunlu değil.
- Parça değişimini metadata'sız da algıla: sessizlik/çapraz geçiş + spektral yenilik (novelty) + uzun süreli LUFS sıçraması.

---

## 4. Mimari

```
Apple Music / tarayıcı / diğer
          │  (sistem çıkışı)
          ▼
 [Core Audio Process Tap]  ← kendi çıkışımız hariç (geri besleme önlenir), orijinal sessize alınır
          │  IOProc (gerçek zamanlı, sabit zamanlama)
          ▼
 [Ring Buffer, kilitsiz] ─────────────► [Analiz Kuyruğu] ─► Swift analiz (LTAS, tilt, LUFS, crest)
          │                                         │                    │
          ▼                                         └──► Python sidecar (tür/stil, BPM, enerji) [Faz 5]
 [DSP Zinciri — Float64]                                                   │
   L0 sabit Harman düzeltmesi (PEQ)                                        ▼
   L1 kişisel bas/tiz ofseti                                      [Adaptasyon Kontrolcüsü]
   L2 ses seviyesi telafisi (ISO 226) [isteğe bağlı]    ◄──── hedef eğri farkı → sınırlı, yavaş filtre güncellemesi
   L3 şarkıya uyarlanan geniş bantlı EQ
   L4 tür öncelikleri (küçük) [v1 kapalı]
   preamp (otomatik) → limiter
          │
          ▼
 [Çıkış: harici DAC / kulaklık]

 Menü çubuğu UI: aç/kapa, bypass (seviye eşitlemeli), kuvvet kaydırıcısı, bas/tiz ofseti, spektrum, durum
```

**Önemli tasarım ilkesi:** Analiz, **EQ'dan önceki** (yakalanan) sinyal üzerinde yapılır. Böylece EQ çıkışı analizi etkilemez, geri besleme döngüsü ve salınım oluşmaz.

### Referans projeler (okumadan kod yazma)
- `insidegui/AudioCap`: process tap kurulumu için en iyi açık referans.
- `dariuscorvus/iqualize` (özellikle Wiki → Architecture): tap → ring buffer → AVAudioEngine → AVAudioUnitEQ → limiter; menü çubuğu uygulaması. Aggregate cihaz, örnekleme hızı ve cihaz değişimi ayrıntıları sayfada yok, bunları kendin çöz.
- `loganrooks/tap-n-filter`, `makeusabrew/audiotee`, `sbetko/catap` (Python sarmalayıcı).
- SignalKit (Swift forum duyurusu): parametrik EQ, look-ahead limiter, BS.1770 LUFS ölçer, kilitsiz ring buffer; Accelerate tabanlı. Kullanılabilir mi diye lisansına bak; yoksa kendin yaz.
- `jaakkopasanen/AutoEq`: filtre üretimi.

---

## 5. EQ stratejisi

### 5.1 L0 — Sabit S12 Ultra düzeltmesi (omurga)
**Üretim hattı:**
1. RAA grafiğindeki indirme simgesinden (yeşil ok) veya sitenin sunduğu veriden **S12 Ultra frekans yanıtı verisini** al. Ulaşılamazsa Emir'den dosyayı/ekran görüntüsünü iste. Gözle okumayla yetinme.
2. AutoEq ile hedef = Harman In-Ear 2019; en fazla **8 PEQ filtresi**; **10 kHz üstüne düzeltme yok**.
3. Kısıtlar: 4 kHz üstünde Q ≤ 2; her filtrede |gain| ≤ 6 dB (üstü gerekiyorsa iki filtreye böl); dar tepeleri (Q > 3) yoksay.
4. Çıkan filtreleri `profiles/s12-ultra.json` olarak sakla (tür, frekans, Q, gain). Kod bu dosyayı okur; sabit sayı gömülmez.
5. **Kuvvet çarpanı (strength) varsayılan 0,5–0,6.** Gain'lerin yarısıyla başla. Gerekçe: birim farkı, tip/ekleme farkı, kişisel HRTF. Emir kulağıyla artırır.

**Tohum (yalnızca AutoEq çıktısı gelene kadar geçici):** Peak 600 Hz +1,5 dB Q0,7; Peak 3500 Hz +4,5 dB Q1,0; High shelf 5000 Hz +4,5 dB Q0,7; preamp −9 dB (tam güç). Yarı güçte: Peak 3500 Hz +2,5; shelf +2,5; preamp ≈ −5 dB.

### 5.2 L1 — Kişisel tercih ofseti
Harman'ın dinleyici segmentasyonu: dinleyicilerin çoğu hedef eğriyi sever; yaklaşık %21'i hedeften 2–3 dB az bas, yaklaşık %15'i 3–6 dB fazla bas tercih eder (Olive vd., AES 2019). Bu yüzden:
- Bas raf (low shelf, ~100 Hz, Q0,7): kaydırıcı **−3…+6 dB**, varsayılan 0.
- Tiz raf (high shelf, ~8 kHz, Q0,7): kaydırıcı **−3…+3 dB**, varsayılan 0.
- Ayarlar kalıcı saklanır.

### 5.3 L2 — Ses seviyesine bağlı loudness telafisi (isteğe bağlı, varsayılan KAPALI)
Düşük sesle bas ve tiz daha az duyulur (ISO 226 eş-gürültülülük eğrileri). Wavelet bunu "equal loudness" modu olarak sunuyor. Bu projede:
- Telafi = referans seviyedeki eğri ile mevcut seviyedeki eğri arasındaki fark, 1 kHz'e normalize.
- **Sorun:** Gerçek SPL'i bilmiyoruz. Çözüm: Emir bir kez "referans sistem ses seviyesi" belirler; `kAudioDevicePropertyVolumeScalar`/dB okunur; referansın altındaki her dB için telafi uygulanır.
- Sınırlar: bas en fazla **+6 dB**, tiz en fazla **+3 dB**; referans ve üstünde telafi sıfır.
- **Koşul (DOĞRULA):** Harici DAC'ın ses seviyesi donanımsa ve macOS'tan okunamıyorsa bu özellik devre dışı kalır, kullanıcıya söyle.

### 5.4 L3 — Şarkıya uyarlanan tonal denge (asıl "akıllı" katman)
Fikir: Şarkının uzun süreli ortalama spektrumunu (LTAS) hedef bir eğriyle kıyasla, farkın **küçük bir kısmını** geniş, yumuşak filtrelerle düzelt.

Araştırmadan çıkan dayanaklar:
- Pop müzikte LTAS yaklaşık −4,5 dB/oktav eğimine yakın; HoRNet BalancEQ ve Pinky 2 gibi otomatik spektral dengeleyiciler bu hedefi kullanıyor (pembe gürültü −3, kahverengi −6 dB/oktav arası). Pestana vd. (AES 2013) 100 Hz–4 kHz arasında yaklaşık 5 dB/oktav azalma bildiriyor.
- Pinky 2 bile, **bant başına en fazla ±1 dB** ile çalışıyor ve "büyük tonal sorunları düzeltmek için tasarlanmadı" diyor. Bu araçlar **miks** içindir; bitmiş ticari müziğe uygulamanın dinleyici tercihini artırdığına dair bir çalışma **bulamadık**. Bu yüzden katman muhafazakâr ve kapatılabilir olmalı.

Tasarım:
- Analiz bantları: 1/3 oktav (veya ~20 bant), 40 Hz–12 kHz. Sessiz bölümleri (LUFS kapısı, örn. −50 LUFS short-term altı) analize dahil etme.
- Zaman sabitleri: **uzun** (saniyeler). Atak ~8–15 sn, bırakma ~15–30 sn. Hızlı değişim "pompalama" yapar ve rahatsız eder.
- Parça değişince yeni parçanın ilk ~10 sn'sinde kontrolcü dondurulur, sonra yumuşakça uyarlanır. Parça önbelleğinden (Bölüm 6) geçmiş ölçüm varsa hemen kullanılır.
- Çıktı: 6–8 geniş bantlı (Q ≈ 0,5–0,8) peak/shelf; her biri **±2 dB** ile sınırlı; toplam eğri düzgünleştirilmiş.
- **Genel kuvvet kaydırıcısı 0–100 %**, varsayılan **%30**. 0 = L3 kapalı.
- Filtre katsayıları değişirken 50–200 ms'de enterpolasyon yap (zipper gürültüsü olmasın).
- **Özel kural (S12 Ultra'ya özgü):** L0, 3–5 kHz'e ciddi artış ekliyor. Parça zaten parlaksa (tilt hedefe göre dik, 3–6 kHz enerjisi yüksek), L0'ın bu bölgedeki artışını **0,5–1,0 çarpanıyla azalt**. Bu bir hipotez; A/B testiyle doğrula.
- Uç durumlar: mono kayıt, çok düşük dinamik, klasik/akustik (varsayılan olarak daha düşük kuvvet), sessizlik, parçalar arası geçiş.

### 5.5 L4 — Tür/stil öncelikleri (v1'de KAPALI)
Etiketler (Essentia Discogs-EffNet 400 stil, MAEST) şunları **küçük** ölçüde etkileyebilir:
- Hedef eğim: ±0,5 dB/oktav
- Adaptasyon kuvveti: klasik/caz/akustikte düşür, bas ağırlıklı elektronik/hip-hopta olduğu gibi bırak
- Kıskaç (clamp) sınırı

Tümü `config/genre-priors.json` içinde ayarlanabilir, **varsayılan sıfır**. Emir kulağıyla değer girmeden açılmaz. Etiket yanlış çıkabilir; yanlış etiketin zararı sınırlı kalmalı.

### 5.6 BPM hakkında dürüst not
BPM ile ideal EQ arasında doğrudan nedensel bir bağ yok. BPM'i **EQ kararı için kullanma**. Sadece gösterim, günlük ve ileride "tempo/enerjiye göre otomatik çalma listesi" için sakla. EQ'yu asıl belirleyecek özellikler: LTAS/tilt, düşük frekans oranı, parlaklık (spektral centroid), dinamik aralık (crest factor, PLR), LUFS.

### 5.7 L5 — Güvenlik
- **Otomatik preamp:** Tüm katmanlar toplandığında oluşan en büyük pozitif gain'in negatifi kadar (+0,5 dB pay) ses düşür. Preamp'i AutoEq çıktısındaki değerle de karşılaştır.
- **Limiter:** Look-ahead (≈1–5 ms), tavan −0,5 dBFS. Normal kullanımda devreye girmemeli; devreye giriyorsa durum göstergesi yansın.
- Toplam gain tavanı: hiçbir frekansta toplam artış **+10 dB**'yi aşmaz (kıskaç).
- Açılış/kapanış/bypass geçişlerinde 50 ms gain rampası. Ani ses patlaması olmayacak.
- Uygulama başlarken sessizlikten yükselt.

---

## 6. Şarkı analizi ve önbellek

**Swift (hafif, her zaman çalışır):** 2048–4096 noktalı FFT, Hann pencere, vDSP; LTAS (1/3 oktav), tilt (100 Hz–8 kHz doğru uydurma), 20–120 Hz enerji oranı, centroid, short-term/integrated LUFS (BS.1770), crest factor/PLR, stereo genişliği, sessizlik ve parça değişimi dedektörü.

**Python sidecar (ağır, Faz 5):**
- `essentia-tensorflow`: Discogs-EffNet (400 stil), TempoCNN, enerji/ruh hâli sınıflandırıcıları. PyPI'da macOS arm64 wheel'leri yayınlı; **Python sürümünü sabitle (3.12 öneri) ve kurulumu doğrula**. Yedek: `librosa` (BPM, spektral özellikler).
- Haberleşme: Unix domain socket veya stdin/stdout JSON. Ses, analiz için kısa pencerelerle (örn. 30 sn) mono 11,025–16 kHz'e indirilmiş hâlde gider; **diske yazılmaz**.
- Sidecar çökerse ana ses zinciri etkilenmez; L4 sessizce devre dışı kalır.

**Önbellek:** SQLite, anahtar = (başlık, sanatçı, süre) ya da metadata yoksa özellik parmak izi. Değerler: LTAS vektörü, tilt, LUFS, stil etiketleri, BPM. **Ses saklanmaz.**

---

## 7. Gerçek zamanlı ses iş parçacığı kuralları (ZORUNLU)

IOProc / render callback içinde **yasak:**
- bellek ayırma (`malloc`, Swift Array büyütme, closure yakalama), kilit/mutex, `print`, Objective-C mesajlaşma, Swift runtime/ARC yoğun kod, disk/ağ I/O.

**Zorunlu:**
- Tüm tamponlar önceden ayrılır. Parametre aktarımı kilitsiz (atomik/çift tamponlu, indeks çevirme).
- Filtre katsayıları UI/analiz iş parçacığında hesaplanır, ses iş parçacığına çift tamponla verilir.
- Biquad durumları Float64; denormal sayılar sıfırlanır.
- Ring buffer: tek yazar, tek okuyucu, kilitsiz. Doluluk/boşluk (underrun/overrun) sayaçları tutulur, UI'da gösterilir.
- Örnekleme hızı değişimini (Apple Music kayıpsız parçalarda cihaz hızını değiştirebilir: 44,1/48/96/192 kHz) ve cihaz çıkarma/takma, uyku/uyanma olaylarını yakala; aggregate cihazı ve katsayıları yeniden kur.
- Tap biçimi cihazın kanal düzenine göre değişebilir; bir kaynakta stereo tap'in kanal düzeni değişince hata verdiği, mono küresel tap'in daha kararlı olduğu bildirilmiş. Stereo tap kullanıp düzen değişimini yakala.

**İzin ve paketleme:**
- Uygulama bir **.app paketi** olmalı (komut satırı aracı değil). İzin, paketin kimliğine bağlanır; terminalden çalıştırılırsa izin terminale yazılır.
- `Info.plist` içine `NSAudioCaptureUsageDescription` ekle. Menü çubuğu uygulaması için `LSUIElement = true`.
- Ayrı bir sistem-sesi yetkisi (entitlement) gerekmiyor; yine de DOĞRULA.
- **İzin reddedilirse tap hata vermek yerine sessizlik döndürebilir.** Girişte uzun süre tam sessizlik varsa kullanıcıya "izin verilmemiş olabilir" uyarısı göster.
- Yerel imza: ad-hoc veya ücretsiz geliştirici sertifikası yeterli (tek kullanıcı).
- **Çökme güvenliği:** Tap "muted" olduğundan uygulama çökerse orijinal sesin geri geldiğini test et (Faz 1 kabul kriteri).

---

## 8. Ses kalitesi ilkeleri

1. **Seviye eşitlemeli A/B:** Daha yüksek ses hep "daha iyi" duyulur. Bypass ile EQ arasında geçişte, EQ'nun getirdiği algısal ses artışı (basit: A-ağırlıklı kısa süreli LUFS farkı) preamp ile eşitlenir. Bu olmadan yapılan her "iyileşti" yargısı geçersizdir.
2. **Bypass saydam olmalı:** EQ kapalıyken ses, orijinalle bit düzeyinde aynı (Float32 → Float32) veya ölçülebilir şekilde eşdeğer olmalı. Birim kazanç (unity gain) testi yap. Bir Apple forum konusunda tap'te çıkış çiftlerinin sayısına bağlı seviye düşüşü bildirilmiş: bunu kendi cihazında ölç.
3. **Faz ve gecikme:** Minimum faz IIR kullan, ek gecikme sadece ring buffer + hesaplama kadar olsun (hedef < 20 ms). Video izlerken ses kayması fark edilirse bypass önerisi göster.
4. **Bozulma kontrolü:** Faz 2'de en yüksek EQ ayarında sinüs/gürültü ile THD+N ve kırpılma (clipping) kontrolü.
5. **Apple Music tarafı:** Ses İyileştirici, Apple EQ, Dolby Atmos/Spatial Audio kapalı olmalı (çifte işleme). eqMac veya başka sistem EQ'su açıksa uygulama uyarsın. Ses Kontrolü (Sound Check) açık kalabilir.

---

## 9. Fazlar ve kabul kriterleri

**Faz 0 — Hazırlık ve sorular**
- Sor/doğrula: macOS sürümü ve Mac modeli, Xcode kurulu mu, Python sürümü, harici DAC kullanıyor mu (modeli, donanım ses seviyesi var mı), müziği Music.app'ten mi tarayıcıdan mı dinliyor, uygulama adı, `mediaremote-adapter` gibi özel API tabanlı yedeklere izin veriyor mu.
- RAA'dan S12 Ultra frekans yanıtı verisini temin et (veya Emir'den iste).
- `profiles/s12-ultra.json` için AutoEq çalıştır, çıktıyı Emir'e göster.
- Kabul: Proje iskeleti, `CLAUDE.md` onaylı, açık sorular cevaplı.

**Faz 1 — Saydam geçiş (pass-through)**
- Process tap ile sistem sesini yakala, kendi çıkışımız hariç; seçili çıkış cihazına ver.
- Kabul: Apple Music çalarken kesintisiz, cızırtısız ses; sistem ses tuşları çalışıyor; cihaz/örnekleme hızı değişince toparlanıyor; uygulama çökerse ses geri geliyor; izin reddi uyarısı çalışıyor; gecikme ölçüldü.

**Faz 2 — L0 sabit düzeltme + güvenlik**
- Float64 biquad zinciri, JSON profilden yükleme, strength, otomatik preamp, limiter, 50 ms rampalı bypass, seviye eşitlemeli A/B.
- Kabul: Birim testlerde ölçülen toplam yanıt AutoEq hedefiyle ±0,3 dB uyuşuyor; bypass saydam; en yüksek ayarda kırpılma/bozulma yok; Emir A/B yapıp "kabul edilebilir/tercih ediyorum" diyor.

**Faz 3 — Menü çubuğu arayüzü ve kişisel ofsetler**
- Aç/kapa, bypass, strength, bas/tiz ofseti, durum (örnekleme hızı, buffer sağlığı, limiter etkinliği), canlı spektrum (ön/son).
- Kabul: Tüm ayarlar kalıcı; login'de başlama (`SMAppService`).

**Faz 4 — Swift analiz + L3 uyarlama**
- LTAS/tilt/LUFS/crest, parça değişimi dedektörü, uyarlama kontrolcüsü (Bölüm 5.4), SQLite önbellek.
- Kabul: Sabit bir test parçasında filtre eğrisi zamanla sabitleniyor, salınım/pompalama yok; parça değişiminde ani sıçrama yok; kuvvet %0'da çıktı L3'süz ile birebir; Emir en az 10 farklı türde A/B yaptı ve sonuçları kaydedildi.

**Faz 5 — Python sidecar: tür/stil, BPM, enerji; L4 altyapısı**
- Sidecar süreç yönetimi, protokol, çökme dayanıklılığı. L4 tablosu hazır ama varsayılan sıfır.
- İsteğe bağlı: `mediaremote-adapter` ile başlık/sanatçı; ShazamKit değerlendirmesi.
- Kabul: Ses motoru sidecar olmadan da kusursuz çalışıyor; etiketler önbelleğe yazılıyor.

**Faz 6 — L2 loudness telafisi (isteğe bağlı)**
- Cihaz ses seviyesi okuma, referans kalibrasyonu, ISO 226 farkı, sınırlar.
- Kabul: Donanım ses seviyesi okunamıyorsa özellik kibarca devre dışı; seviyeye göre yumuşak değişim.

**Faz 7 — Değerlendirme araçları ve cilalama**
- ABX/kör A/B modu (rastgele sıra, seviye eşitlemeli, sonuç günlüğü), "bu şarkıda iyi/kötü" geri bildirim düğmesi, günlük dışa aktarma.
- İleri fikir (zorunlu değil): Geri bildirimden kişisel tercih ofseti öğrenme. Az veriyle aşırı uyum riski yüksek; sadece küçük, kıskaçlı düzeltme.

---

## 10. Doğrulama ve test

- **DSP birim testleri:** RBJ katsayıları, bilinen referans yanıtlarla karşılaştırma; pembe gürültü ve log-sweep ile zincirin ölçülen büyüklük yanıtı (Python/numpy ile çevrimdışı), hedefle ±0,3 dB.
- **Birim kazanç ve bit-saydamlık testi:** Bypass'ta null testi.
- **Gerçek zamanlılık:** Çalışırken bellek ayırma/kilit denetimi (Instruments / `os_signpost`), buffer underrun sayacı sıfır kalmalı; uzun süreli (saatlerce) çalıştırma testi, uyku/uyanma, DAC çıkar/tak.
- **Uyarlama testleri:** Sentetik spektrumlarla (eğimli gürültü) kontrolcü doğru yöne gidiyor mu, sınırlar tutuyor mu, durağan sinyalde salınım var mı.
- **Dinleme testleri:** Seviye eşitlemeli A/B; farklı türlerden parça seti (pop, hip-hop, elektronik, rock, akustik, klasik, caz, vokal ağırlıklı, parlak mastering, çok bas). Sonuçlar `docs/listening-log.md` dosyasına.
- **Kendi kendini kandırmama:** Ölçüm cihazın ölçüm düzeneği insan kulağından hassastır; her fark duyulmaz. "Duyduğunu sandığın" iyileşmeleri kör testle doğrula.

---

## 11. YAPILMAYACAKLAR (kasıtlı)

- **Hızlı/agresif dinamik EQ:** Pompalama yapar. Zaman sabitleri saniyeler olacak.
- **Büyük kazançlar:** Tek filtrede 6 dB üstü, toplamda +10 dB üstü yok.
- **8 kHz üstünde dar, yüksek Q'lu düzeltme:** Ölçümler ve ekleme farkı yüzünden güvenilmez.
- **Etiket tabanlı sert preset'ler** ("hip-hop = +5 dB bas" gibi): Etiket yanlış çıkabilir, S12 Ultra zaten güçlü bas veriyor.
- **BPM ile EQ kararı vermek.**
- **Dinamik aralık sıkıştırma/"mastering" ekleme** (v1'de yok). Şarkının dinamiğine dokunmuyoruz.
- **Yapay zeka "her şeyi öğrenir" yaklaşımı:** Az veriyle kişisel model eğitmek erken; önce sabit kurallar ve kulak testi.
- **Bulut/ağ:** Hiçbir ses veya özellik dışarı gönderilmez. Her şey yerel.
- **Ses kaydetmek.**
- **Dolby/Spatial/crossfeed/stereo genişletme** ve benzeri efektler (v1 kapsamı dışı; ileride ayrı değerlendirilir).

---

## 12. Bilinen riskler ve açık sorular

| Risk / soru | Etki | Plan |
|---|---|---|
| Process tap davranışı macOS sürümüne göre değişebilir, belgeleri zayıf | Yakalama kırılır | Faz 1'de erken ve kapsamlı test; SCK yedeği |
| Apple Music kayıpsız parçada cihaz hızını değiştiriyor | Katsayılar yanlış kalır | Hız değişimini dinle, yeniden kur |
| DAC'ta donanım ses kontrolü | L2 çalışmaz | Özelliği devre dışı bırak |
| Metadata yolları (AppleScript/MediaRemote) kırılgan | Parça adı/türü alınamaz | Sesle parça değişimi algılama; metadata isteğe bağlı |
| RAA ölçümü Emir'in birimiyle farklı olabilir | L0 yanlış yönde | Strength 0,5–0,6 ile başla; kulakla ince ayar; gerekirse kendi ölçümüne dayalı düzeltme |
| L3'ün yararı kanıtlı değil | Zaman kaybı | Küçük kuvvetle başlat, kör A/B ile kanıtla; olmazsa kapat |
| Tür modelleri Discogs taksonomisinde, "pop/rock" gibi geniş sınıflar zayıf | Etiket gürültülü | L4 varsayılan kapalı |
| Python sidecar kurulum zorluğu (TensorFlow wheel uyumu) | Faz 5 gecikir | Sürümü sabitle; librosa yedeği |
| Çökme anında sessizlik | Kötü deneyim | Faz 1 kabul kriteri |

**Emir'e sorulacaklar (Faz 0):** macOS sürümü; harici DAC var mı ve modeli; Music.app mi tarayıcı mı; uygulama adı; özel API'li yedeklere (mediaremote-adapter) izin; en çok dinlediği türler (test seti için).

---

## 13. Kaynaklar

**Ses yakalama ve macOS**
- https://github.com/insidegui/AudioCap
- https://github.com/dariuscorvus/iqualize/wiki/Architecture
- https://github.com/loganrooks/tap-n-filter
- https://github.com/makeusabrew/audiotee
- https://pypi.org/project/catap/
- https://www.recall.ai/blog/core-audio-taps
- https://github.com/ungive/mediaremote-adapter
- https://developer.apple.com/documentation/shazamkit/shmanagedsession
- Swift forum: SignalKit (gerçek zamanlı Swift DSP)

**EQ, hedef eğri, ölçüm**
- https://reference-audio-analyzer.pro/en/report-pro-hp-target.php?id=6146
- https://github.com/jaakkopasanen/AutoEq
- https://iem-eq-guide.pages.dev/ (IEM EQ rehberi: birim farkı, hedefler)
- https://www.soundguys.com/harman-research-targets-the-bruel-kjaer-5128-112247
- https://aes2.org/publications/elibrary-page/?id=22696 (Olive 2024, B&K 5128 IE hedefleri)
- https://aes2.org/publications/elibrary-page/?id=20289 (Olive vd. 2019, dinleyici segmentasyonu)
- https://techpowerup.com/review/letshuoer-s12-planar-in-ear-monitors/4.html
- https://www.headphoneer.com/letshuoer-s12-ultra-review/
- https://theheadphonelist.com/letshuoer-s12-ultra-review-its-different/

**Uyarlanabilir tonal denge ve loudness**
- https://aes2.org/publications/elibrary-page/?id=18638 (pop müzikte LTAS)
- https://www.hornetplugins.com/how-hornet-balanceq-works-a-deep-dive-into-its-algorithm/ (−4,5 dB/oktav hedefi)
- https://www.kvraudio.com/product/pinky-2-by-noisebud (bant başına ±1 dB uyarlama)
- https://androidauthority.com/wavelet-equal-loudness-3466696 (ISO 226 loudness modu)

**Müzik analizi**
- https://essentia.upf.edu/models.html
- https://pypi.org/project/essentia-tensorflow/
- https://arxiv.org/pdf/2411.00469 (MIRFLEX: Essentia tabanlı özellik çıkarımı)

---

## 14. Karar güncellemesi (2026-10-29, Emir'in dinleme sonucu)

Emir, seviye eşitlemeli A/B'de Harman düzeltmesini (L0) sevmedi: S12 Ultra'nın kendi sıcak, "saran" sesini tercih ediyor. L0, RAA'nın önerdiği EQ ile ±1 dB uyuşuyor; yani sorun uygulamada değil, hedefte (100–300 Hz'i kısıp 3–4 kHz'i öne çıkarıyor). Emir'in istediği: uygulama açıkken müzik keyfi genel olarak artsın, üstüne müziğe göre değişsin. Yeni varsayılanlar:

- **Ton: Doğal** (varsayılan). L0 bantları zincirde 0 dB'de kalır; Harman seçilebilir, kuvvet kaydırıcısı sadece onda.
- **L2 kısık ses telafisi açık** (Faz 6 öne alındı). ISO 226:2003; referans ses seviyesi 83 phon kabul edilir; varsayılan referans = ilk okunan ses seviyesi + 10 dB; bas ≤ +6, tiz ≤ +3 dB.
- **L3 hedefi: Emir'in kütüphanesinin ortalama dengesi** (≥ 8 parça, ≥ 60 sn analiz). O zamana kadar −4,5 dB/okt. Böylece L3 sesi dışarıdaki bir kurala değil, Emir'in alışık olduğu dengeye çeker; sadece aykırı mastering'ler (fazla parlak/koyu/ince/boğuk) düzeltilir.
- Seviye eşitleme A-ağırlığı yerine K-ağırlığı (BS.1770) kullanır (bas değişimlerini daha doğru tartar).
- §11'deki yasaklar (dinamik sıkıştırma, stereo genişletme, büyük kazançlar) yerinde.

## 15. Karar güncellemesi (2026-10-31): Keşfet özelliği ve ağ istisnası

Emir, dinledikleriyle **ilgisiz**, az bilinen ve sesi iyi şarkılar öneren bir "Keşfet" özelliği istedi ve §11'deki ağ yasağına şu istisnayı onayladı:
- Dışarı giden tek şey: rastgele seçilen tür adıyla MusicBrainz kayıt araması ve aday "sanatçı + şarkı" ile iTunes Search araması. Anahtar/hesap yok.
- Emir'in dinledikleri, önbellek, yakalanan ses veya ölçümler **asla** gönderilmez. Kişisel bilgi (e-posta vb.) User-Agent'a konmaz.
- 30 sn'lik iTunes önizlemesi indirilir, **yalnızca bellekte** çözülüp ölçülür (PLR, kırpılma, bas/tiz uzanımı, eğim), diske yazılmaz.
- MusicBrainz kuralı: saniyede en fazla 1 istek, anlamlı User-Agent.
- Öneri Music.app'te açılır (MusicKit ücretli üyelik istediği için doğrudan çalma/kütüphaneye ekleme yok).
