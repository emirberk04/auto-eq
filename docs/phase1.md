# Faz 1 — Saydam geçiş (2026-10-28)

## Mimari
- `CATapDescription(stereoMixdownOfProcesses: [Music])`, `muteBehavior = .mutedWhenTapped`, private.
  macOS 26'da ayrıca `bundleIDs = ["com.apple.Music"]` + `processRestoreEnabled` (Music yeniden açılınca tap kendini geri bağlar).
  "Tüm sistem sesi" modu: global tap, kendi sürecimiz (PID + bundle ID) hariç.
- Tek private aggregate: ana alt cihaz = varsayılan çıkış (saat kaynağı), + tap (drift compensation açık).
- Tek C IOProc (`renderProc`): tap girişi → `RenderKernel` → cihaz çıkışı. Ses yolunda ring buffer yok; tampon ayırma, kilit, log, ARC yok (`_withUnsafeGuaranteedRef`).
  - CLAUDE.md §4'teki ring buffer bu yüzden ses yolunda gereksiz; Faz 4'te yalnızca analiz için eklenecek.
- Kontrol tarafı ↔ IO thread: yalnızca `Synchronization.Atomic` (bu yüzden minimum macOS 15).
- Yeniden kurulum tetikleyicileri (300 ms debounce): varsayılan çıkış değişimi, çıkış örnekleme hızı / akış yapılandırması / IsAlive, tap formatı, aggregate IsAlive, Music süreç listesi, uykudan uyanma. Hata olursa 2 sn sonra tekrar dener.
- Açılış/kapanış: 50 ms doğrusal gain rampası (sessizlikten yükselme).

## Ölçümler (MacBook Air M1, dahili 3,5 mm, macOS 26.6.2)
| Durum | Sonuç |
|---|---|
| Tap formatı | 48 kHz, 2 kanal, Float32 (cihaz 96 kHz iken de; HAL 48→96 dönüştürüyor, orijinal yol da aynı dönüşümü yapıyordu) |
| İşlenen kare | 10 sn'de ~960 bin (96 kHz), sessizlik 0 |
| Aşırı yük / blok uyumsuzluğu | 0 / 0 |
| Örnekleme hızı 96→48 kHz | ~1 sn içinde otomatik yeniden kurulum (ilk deneme "tap #0" ile düştü, retry kurtardı; artık açıkça yakalanıyor) |
| `kill -9` | Ses anında kulaklığa geri döndü (Emir doğruladı) |
| Cızırtı | Yok (Emir, birkaç dakikalık dinleme) |
| Yeniden derleme sonrası izin | Ad-hoc imzaya rağmen tekrar sorulmadı |

### Gecikme
IOProc'ta `outputTime.mSampleTime − inputTime.mSampleTime` her döngüde ölçülüyor, üstüne cihazın çıkış gecikmesi ekleniyor.

| Ayar | Ölçülen |
|---|---|
| 48 kHz, tampon 512 | 77 ms |
| 48 kHz, tampon 128 | 61 ms |
| 96 kHz, tampon 256 (varsayılan) | ~56 ms |

- **Tap'in kendisi ~1024 kare (48 kHz'te ~21 ms) güvenlik payı bildiriyor**: hem tap+çıkış aggregate'inde hem sadece-tap aggregate'inde aynı. Aggregate çıkış tarafı da ~17 ms ekliyor. Drift compensation kapatmak hiçbir şey değiştirmedi.
- **Sonuç: CLAUDE.md §8.3'teki < 20 ms hedefi process tap ile ulaşılamaz.** Ayrı çıkış IOProc + ring buffer mimarisi tahminen ~35 ms'ye indirir (aggregate çıkış payını atlar), bedeli iki IOProc arasında zamanlama marjı ve karmaşıklık.
- Sadece Music.app dinlerken (dudak senkronu yok) pratik etkisi: play/pause ve ses seviyesi tepkisi ~50 ms gecikmeli.
- Tampon boyutu `defaults write com.emiralan.s12-adaptive-eq ioBufferFrames -int 128` ile değiştirilebilir.

## Emir'in yapacağı kalan testler
- [ ] Ses tuşları (yükselt/kıs/sessiz) uygulama açıkken çalışıyor.
- [ ] Kulaklığı çıkar → hoparlöre geçip çalıyor; geri tak → kulaklıkta devam ediyor.
- [ ] Uyku/uyanma sonrası ses geliyor.
- [ ] Music.app'i kapatıp aç → menü "Music.app bekleniyor" → çalınca otomatik devam.
- [ ] İzin reddi: Sistem Ayarları → Gizlilik ve Güvenlik → Ses Kaydı (Screen & System Audio Recording) → S12 Adaptive EQ'yu kapat, uygulamayı yeniden başlat, Music çalarken ~3 sn sonra menüde ⚠️ uyarısı çıkmalı. Sonra izni geri aç.
- [ ] Saatlerce çalıştırma: `log show --predicate 'subsystem == "com.emiralan.s12-adaptive-eq"' --info` ile 10 sn'lik `health` satırlarında `overloads=0 mismatches=0`.

## Notlar
- eqMac sürücüsü hâlâ kurulu (çıkış yönlendirmiyor). eqMac uygulaması açılırsa veya varsayılan çıkış eqMac cihazı olursa menü uyarır.
- Kalıcı imza için: Xcode → Settings → Accounts'a Apple ID ekle (ücretsiz "Apple Development" sertifikası). Şu an imza kimliği yok; ad-hoc ile izin şimdilik korunuyor.
