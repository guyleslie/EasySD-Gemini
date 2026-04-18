# EasySD – Plugin fejlesztői quickstart (2026)

Ez a dokumentum röviden, közérthetően bemutatja, hogyan lehet plugint készíteni az EasySD rendszerhez.

## Mi az a plugin?
A plugin egy különálló program, amit a C64 menüje tölt be speciális fájltípusok (pl. .PRG, .WAV, .KOA) kezelésére.

## Plugin életciklus
1. A menü betölti a plugint, átadja a kiválasztott fájl nevét
2. A plugin elvégzi a szükséges műveletet (pl. betölt, lejátszik, megjelenít)
3. A plugin visszatér a menübe

## Kötelező szabályok
- Mindig mentsd el a VIC/CPU állapotot belépéskor, és állítsd vissza kilépés előtt
- Használd a közös makrókat és API-kat (lásd: APIMacros.s, SystemMacros.s)
- Hibakezelés: minden fájlművelet után ellenőrizd a visszatérési értéket
- Csak a dokumentált ZP címeket használd ideiglenes változónak

## Minimális plugin váz
```
; Plugin belépési pont
SAVESTATE
; ...fő logika...
JSR PROT_ExitToMenu
```

## További információk
- Részletes ZP címek: lásd Memória térkép dokumentum
- API makrók: lásd APIMacros.s, SystemMacros.s
- Hibakereséshez használd a debug buildet

---
Ez a leírás kizárólag a jelenlegi működésre vonatkozik. Bővebb példák és részletek a forráskódban.