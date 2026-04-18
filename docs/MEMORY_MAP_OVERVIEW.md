# EasySD – Memória térkép és ZP szabályok (2026)

Ez a dokumentum röviden, közérthetően bemutatja a jelenlegi Zero Page (ZP) memória kiosztást és a használat fő szabályait.

## Zero Page kiosztás (főbb címek)
| Cím     | Funkció                        |
|---------|-------------------------------|
| $64-$77 | Kommunikációs bufferek         |
| $80-$87 | Fájlbetöltő API (LoadFileBySize)|
| $8B-$8E | Szabad (SafeStream paraméterek törölve) |
| $90-$95 | Nagy fájl streamelés           |
| $FB/$FC | Navigációs pointer (NAMELOW/HIGH) |
| $FD/$FE | Színmemória pointer (COLLOW/HIGH) |

## Fő szabályok
- Csak a dokumentált, pluginoknak szabadon használható címeket használd
- $FB-$FE csak akkor használható, ha nem navigáció vagy színmemória pointerként van szükség
- $80-$87 kizárólag a fájlbetöltő API számára fenntartott
- Ne használj nem dokumentált ZP címeket, mert ütközéshez vezethet

## További információk
- A teljes, naprakész ZP kiosztás: EasySD/Loader/CartZpMap.inc
- Plugin fejlesztéshez lásd a Plugin quickstart dokumentumot

---
Ez a leírás kizárólag a jelenlegi, működő rendszerre vonatkozik.