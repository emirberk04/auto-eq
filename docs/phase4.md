# Faz 4 — Swift analiz + L3 şarkıya uyum

## Akış

```
tap girişi (EQ öncesi) ─► kernel: mid (L+R)/2 ve side (L−R)/2 ring'leri
                              │  (analiz kuyruğu, 100 ms'de bir okur; ses iş parçacığı beklemez)
                              ▼
                     TrackAnalyzer: BS.1770 loudness (M/S/I), 1/3 oktav LTAS (40 Hz–12,5 kHz,
                     −50 LUFS kapısı), eğim, bas oranı, centroid, crest, PLR, stereo genişlik,
                     parça değişimi (sessizlik boşluğu / kalıcı spektral değişim)
                              │  0,5 sn'de bir
                              ▼
                     AdaptationController: hedef −4,5 dB/okt ile fark → 6 geniş filtreye
                     en küçük kareler uydurma → yavaş takip (atak 10 sn, bırakma 20 sn)
                              │
                              ▼
                     EQDesign: × uyum oranı, bant başına ±2 dB kıskaç, L3 seviye telafisi
                              → DSPSettings (triple buffer) → kernel 120 ms'de yumuşatır
```

## Kararlar

- **Hedef eğri:** güç spektral yoğunluğunda (dB/Hz) −4,5 dB/oktav. Bu ölçekte pembe gürültü −3, kahverengi −6. Sadece *şekil* karşılaştırılır; seviye farkı atılır.
- **L3 filtreleri (sabit frekans, sadece kazanç değişir):** low shelf 90 Hz, peak 250 / 600 / 1400 / 3000 Hz (Q 0,7), high shelf 6,5 kHz. Hepsi Q 0,7 → geniş ve yumuşak.
- **Uydurma:** fark eğrisi komşu bantlarla yumuşatılır, 50 Hz altı ve 10 kHz üstü yarım ağırlık (ölçüm güvenilirliği), ridge düzenlileştirmeli ağırlıklı en küçük kareler.
- **Uyum oranı** varsayılan %30; uygulanan kazanç = tam düzeltme × oran, sonra ±2 dB kıskaç. Oran değişikliği anında (kernel yumuşatmasıyla) duyulur; kontrolcünün kendisi yavaştır.
- **Zamanlama:** parça değişince ilk 10 sn ses (duraklatma sayılmaz) kontrolcü donar; önbellekte parça varsa hedef hemen önbellekten gelir. Duraklatılmışken zaman ilerlemez.
- **S12 kuralı (hipotez):** 3,15–5 kHz bantları hedef çizginin üstündeyse (4 dB fazlalıkta tam etki), L0'ın 2,5–5,5 kHz'teki pozitif filtreleri en fazla yarıya iner. Tam etki uyum %30 ve üstünde.
- **Seviye:** L3 dengeyi değiştirir, seviyeyi değil. Preamp, L3'süz bantlardan + sabit 1 dB rezervle hesaplanır, sonra L3'ün A-ağırlıklı loudness değişimi telafi edilir. Rezerv "Şarkıya uyum" kapalıyken de tutulur, böylece uyum A/B'si seviye eşittir. Uyum %0'da rezerv yok: zincir Faz 3 ile bit düzeyinde aynı. Not: bu yüzden genel seviye Faz 3'e göre 1 dB daha düşük.
- **Parça değişimi:**
  - Music.app modunda Music'in herkese açık `com.apple.Music.playerInfo` bildirimi (izin/özel API yok) kullanılır; gelince sesle algılama kapanır (yanlış alarm olmasın).
  - Tüm sistem modunda veya bildirim gelmediyse: ≥0,5 sn sessizlik (< −60 LUFS) ardından ses, ya da parça ≥30 sn iken kısa pencere şekli parça ortalamasından 6 sn boyunca > 6 dB RMS farklı.
  - Bilinen sınırlama: tüm sistem modunda duraklat/devam da "yeni parça" sayılır (zararı: o parça için analiz baştan başlar).
- **Önbellek:** `~/Library/Application Support/S12AdaptiveEQ/tracks.sqlite`, anahtar başlık + sanatçı + süre. LTAS, saniye, LUFS, eğim; BPM/stil sütunları Faz 5 için boş. Ses saklanmaz. Parça bilgisi olmayan (sesle algılanan) parçalar önbelleğe yazılmaz; özellik parmak izi ile eşleştirme yapılmadı.
- **İzin uyarısı:** cihaz IO'yu hiç başlatmazsa (ses kaydı izni reddedildiğinde görülen durum) 3 sn sonra izin uyarısı gösterilir.

## Testler (40 test geçiyor; 17'si yeni)

- BS.1770: 997 Hz sinüs 44,1/48/96 kHz'de −20 LUFS ±0,1; sessizlik ve −10 LU altı kapı dışı; crest 3,01 dB.
- Renkli gürültüde eğim ±0,3 dB/okt (−3, −4,5, −6); stereo genişlik.
- Parça değişimi: 70 sn sabit sinyalde yanlış alarm yok; 1,5 sn sessizlik → tek değişim; eğim −3→−9 değişimi 40–50 sn arasında yakalanıyor; metadata modunda sesle algılama kapalı.
- Uydurma yönü: hedef eğimde düzeltme ≈ 0; koyu parça → bas kısılır, tiz artar; parlak parça → tersi + presence azaltımı.
- Kontrolcü: ilk 10 sn donuk; sonra hedefe monoton, aşmadan yerleşiyor (salınım yok); 1 zaman sabitinde %63; önbellekle anında başlıyor; duraklamada sabit.
- Uyum %0 → ayarlar ve çıkış örnekleri L3'süz zincirle bit düzeyinde aynı.
- L3 açık/kapalı loudness farkı < 0,05 dB; büyük artışlarda pay korunuyor.
- SQLite gidiş-dönüş (Türkçe karakter, −∞ loudness), ölçüm birleştirme, ring taşma algılama.

## Kabul durumu

- [x] Sentetik sabit sinyalde eğri sabitleniyor, salınım yok (test)
- [x] Parça değişiminde ani sıçrama yok (donma + 10/20 sn zaman sabitleri + kernel yumuşatması)
- [x] Kuvvet %0'da çıktı L3'süz ile birebir (test)
- [ ] Canlı kontrol: ses kaydı izni yeniden verilince (aşağıya bak)
- [ ] Emir'in en az 10 türde A/B'si (`docs/listening-log.md`)

## İmza ve izin

Ad-hoc imzada her derleme farklı bir kod imzası (cdhash) üretir; macOS ses kaydı iznini o imzaya bağladığı için her kurulumdan sonra izni tekrar sorar. 2026-10-29'daki ilk kurulumda izin verilmedi ve cihaz IO'yu hiç başlatmadı.

Çözüm (2026-10-29): Emir Xcode'da Apple Development sertifikası oluşturdu; geçerli sayılması için eksik olan Apple WWDR G3 ara sertifikası (apple.com/certificateauthority, SHA-256 DC:F2:18:78…60:1F) login anahtar zincirine eklendi. `scripts/bundle.sh` bu kimliği otomatik bulur. Designated requirement artık `identifier "com.emiralan.s12-adaptive-eq" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: …"`: derlemeden bağımsız, izin korunur.

## Canlı kontrol (2026-10-29, izin yeniden verildikten sonra)

- Music bildirimi çalışıyor: "I Luv U" (Fred again.. & Wallfacer) metadata ile tanındı, sesle algılama kapandı (`metadata=true`).
- Parça: integrated −6,0 LUFS, PLR 6,1, eğim −5,3…−6,3 dB/okt (hedeften koyu). İlk 10 sn donuk, sonra uyarlamaya geçti. Tam düzeltme ≈ [−4,7 −2,2 +0,6 +3,1 +2,5 −1,5] dB, %30'da uygulanan ≈ [−1,4 −0,7 +0,2 +0,9 +0,7 −0,4]. Değerler hedefe monoton yaklaştı, salınım yok. Limiter devreye girmedi, aşırı yük 0.
- Bulunan hata: motor kapatılınca analizörün son loudness değeri "çalıyor" sayıldı ve kontrolcü ilerlemeye devam etti. Düzeltildi (son adımdan beri örnek gelmediyse zaman ilerlemez); henüz kurulmadı.

Sertifikalı kurulumdan sonra (20:56): izin bir kez soruldu ve verildi. "Cairo FM" (Alewya) metadata ile tanındı; 37 sn sonra eğim −5,2 dB/okt, −8,4 LUFS, tam düzeltme ≈ [−1,9 −2,9 +1,1 +0,3 +1,6 +3,1] dB. Başlangıçta 1 aşırı yük (IO'nun ilk saniyesi, izin onayı sırasında), sonra 0; limiter 0.

## Yön değişikliği (2026-10-29)

Ayrıntı: `CLAUDE.md` §14. Kısaca: Ton "Doğal" varsayılan (Harman isteğe bağlı), L2 kısık ses telafisi açık (ISO 226, çıkışın ses seviyesi okunur: dahili jakta okunabiliyor), L3 hedefi kütüphane ortalaması, seviye eşitleme K-ağırlıklı. 46 test geçiyor (ISO 226 referans değerleri, doğal ton bit-saydamlık, L2'nin ses seviyesine göre davranışı ve sınırları, kütüphane hedefi).

Canlı (21:2x): imzalı kurulumlarda izin sorulmadı. Referans −11,5 dB (ses −21,5 dB) → L2 bas +4,5, tiz +1,6 dB. Bulunan ve düzeltilen: Doğal tonda parça başında (L3 nötrken) preamp 0 kalıyordu → Music'in 0 dBFS üstü tepeleri limiter'a takılıyordu (~10 sn/parça) ve L3 başlayınca seviye ~2,5 dB adım atıyordu. Artık uyum açıkken pay baştan tutuluyor; parça geçişinde preamp −7,4 → −7,1 dB, limiter 0. 47 test geçiyor.
