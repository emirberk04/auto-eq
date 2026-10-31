# Faz 3 — Menü çubuğu arayüzü ve kişisel ofsetler

## Ne eklendi

- **L1 kişisel ofset** (`EQDesign.bassDb` / `trebleDb`): bas rafı 100 Hz Q0,7 (−3…+6 dB), tiz rafı 8 kHz Q0,7 (−3…+3 dB). Her zaman zincirde (0 dB'de düz), L0 × kuvvetin üstüne eklenir; +10 dB toplam kıskacı ve otomatik preamp bunları da kapsar.
- **Popover arayüzü** (`PopoverView.swift`, SwiftUI, menü çubuğu simgesine tıkla):
  - Etkin anahtarı ve durum satırı
  - Canlı spektrum: giriş (gri, tap'ten gelen) ve çıkış (mavi, EQ + preamp + limiter sonrası), 96 log bant, 20 Hz–20 kHz, 4096 noktalı FFT. Sadece popover açıkken 20 Hz'de hesaplanır.
  - EQ eğrisi: L0 × kuvvet + bas/tiz (düz çizgi) ve preamp dahil hâli (kesikli)
  - EQ / seviye eşitleme onay kutuları, Kuvvet / Bas / Tiz kaydırıcıları (başlığa çift tık = varsayılan)
  - Uyarılar (izin, limiter, profil, cihaz) yalnızca varsa görünür
  - "Durum" açılır bölümü: çıkış, örnekleme hızı, tampon, ölçülen gecikme, preamp, bypass seviyesi, aşırı yük / uyumsuz blok sayaçları, limiter toplam süresi, yeniden kurulum sayısı
  - Yakalama modu (Music.app / tüm sistem), girişte başlat, çık
- **Kalıcılık:** tüm ayarlar UserDefaults'ta (`enabled`, `captureMode`, `eqEnabled`, `levelMatch`, `strength`, `bassDb`, `trebleDb`). Tek yer: `AppModel`.
- **Girişte başlat:** `SMAppService.mainApp`. Onay gerekirse arayüz söyler.
- **Simge:** kulaklık (EQ açık), daireli kulaklık (bypass / kapalı / bekleme), üçgen (uyarı/hata).
- `scripts/install.sh`: derler, çalışan kopyayı kapatır, `~/Applications/S12AdaptiveEQ.app`'e kurar ve açar. Girişte başlatma çalışan kopyayı kaydettiği için kurulu olanı kullan.
- `--render-ui <png> [--dark] [--visualizer ascii|ridges|ring|lava|warp|creature]`: arayüzü sahte verilerle PNG'ye çizer (düzen kontrolü için).

## Testler

`Phase3Tests.swift` (toplam 23 test geçiyor):
- Bas/tiz rafları L0'a doğru eklenir (30 Hz'de +4, 1 kHz'de 0, 16 kHz'de −2, ±0,3 dB)
- Ofsetler aralıklara kıskaçlanır
- Kuvvet 0 + ofsetler 0 + seviye eşitleme kapalı → EQ açıkken bile bit düzeyinde saydam
- Bas artışı preamp'i düşürür
- Ring buffer sırası, analizörde sinüs seviyesi/bandı, kernel'in giriş/çıkış geçmişini doldurması

## Canlı kontrol (2026-10-29)

Kurulu kopya: Music.app modu, External Headphones 96 kHz, tampon 256, 9 bant (7 L0 + 2 L1), sessizlik/aşırı yük/limiter 0, ölçülen gecikme 58,2 ms.

## Kabul — Emir'in yapacakları

1. Menü çubuğundaki simgeye tıkla; spektrum müzikle hareket ediyor mu?
2. Kuvvet/bas/tiz'i değiştir, uygulamadan çık (`Çık`), `~/Applications/S12AdaptiveEQ.app`'i tekrar aç: ayarlar korunmuş mu?
3. "Girişte başlat"ı işaretle, oturumu kapatıp aç (veya yeniden başlat): uygulama kendiliğinden geliyor mu? (Sistem Ayarları → Genel → Giriş Öğeleri'nde görünmeli.)
4. Kaydırıcıları sürüklerken cızırtı/tık var mı?
