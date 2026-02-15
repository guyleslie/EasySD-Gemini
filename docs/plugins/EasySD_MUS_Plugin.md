# EasySD – MUS Player Plugin

Dátum: 2025-12-19  
Projekt: **IrqHack64 / EasySD**

Ez a dokumentum az **MUS Player plugin** működését, fájlstruktúráját és integrációját írja le.

---

## 1. Mi ez a plugin?

Az **EasySD MUS plugin** a klasszikus **Compute! Enhanced SID Player** segítségével képes
`.MUS` zenefájlok lejátszására Commodore 64-en.

Támogatott formátumok:
- ✅ **RAW MUS** (header nélküli)
- ✅ **PRG-fejléces MUS** (2 byte load address)

Nem támogatott:
- ❌ PSID / RSID
- ❌ modern SID dump formátumok

---

## 2. Architektúra – mi miért így van?

### Miért külön SIDPLAYER.PRG?
- A pluginok a projektben **$C000 környékén futnak** (≈4 KB biztonságos ablak).
- A Compute SID Player önmagában ~3153 byte.
- Beégetve **túl nagy lenne**, instabilitást okozhatna.

➡️ Ezért a player **külön PRG**, és a plugin tölti be.

---

## 3. Memória térkép

### SIDPLAYER.PRG (Compute Player)

```
$9000-$9155  Working Data
$9156-$915E  Preserved Data
$915F-$9161  AUX routine
$9162-$91CE  Lookup tables
$91CF-$91FF  INSTALL_SID_PLAYER
$9200-$92E8  INIT_SONG
$92E9-$930E  HUSH_PLAYER
$930F-$9325  REMOVE_SID_PLAYER
$9326-$9C50  IRQ handler
```

### MUS adat
- Betöltési cím: **$8000**

---

## 4. Fájlrendszer felépítés (ajánlott)

```
/PLUGINS/
  MUSPLUGIN.PRG
  SIDPLAYER.PRG

/MUSIC/
  *.MUS
```

A `.MUS` fájl **bárhol lehet**, a plugin mindig a `/PLUGINS` könyvtárból tölti be a playert.

---

## 5. Betöltési folyamat

1. Menüben kiválasztasz egy `.MUS` fájlt
2. EasySD:
   - felismeri a `.mus` kiterjesztést
   - betölti `/PLUGINS/MUSPLUGIN.PRG`
3. A plugin:
   - betölti `/PLUGINS/SIDPLAYER.PRG` → `$9000`
   - betölti a `.MUS` fájlt → `$8000`
   - felismeri RAW / PRG MUS típust (skip 0 / 2)
   - elindítja a lejátszást

Kilépés:
- **SPACE vagy STOP**
- zene leáll
- IRQ és CIA visszaáll
- visszatérés a menübe

---

## 6. MUS felismerési logika

A plugin **nem találgat**, hanem ellenőrzi:

- voice1 + voice2 + voice3 hossz
- +6 byte header
- nem lépi túl a file méretet

Ha:
- offset 0 valid → RAW MUS
- offset 2 valid → PRG MUS
- egyik sem → nem MUS → abort

---

## 7. Build integráció

### Projekt oldalon
- `Plugins/MusPlayer/`
  - `MusPlayer.s`
  - `ComputePlayerSymbols.inc`
  - `compile.bat`

A fő build script (`Build - EasySD.bat`) meghívja a MusPlayer compile lépést.

### SD kártyán
**Ajánlott (új):**
- `/PLUGINS/MUSPLUGIN.PRG`
- `/PLUGINS/SIDPLAYER.PRG`

**Visszafelé kompatibilis (régi layout):**
- `SIDPLAYER.PRG` (SD gyökérben)

> A plugin először a `/PLUGINS/SIDPLAYER.PRG` útvonalat próbálja, és ha nem találja,
> akkor visszaesik a `SIDPLAYER.PRG` névre (legacy).

---

## 8. Miért jó ez a megoldás?

✔️ Klasszikus Compute! kompatibilitás  
✔️ Kicsi, stabil plugin  
✔️ PAL/NTSC független (CIA Timer A, 60 Hz)  
✔️ Nem ütközik a későbbi `$C800` RAM API-val  
✔️ Bővíthető (STR / WDS később)

---

## 9. Összefoglalás

Ez a MUS plugin:
- **történelmileg hiteles**
- **projekt-kompatibilis**
- **stabil és bővíthető**

Ajánlott megoldás EasySD környezetben `.MUS` zenék lejátszására.

---
