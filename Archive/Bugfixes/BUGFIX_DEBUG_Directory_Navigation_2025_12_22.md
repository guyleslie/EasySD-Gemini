# DEBUG Mód Könyvtárnavigációs Hiba Javítás

**Dátum:** 2025-12-22
**Fájl:** `IRQHack64/Menus/EasySD/IrqLoaderMenuNew.s`
**Verzió:** v2.0.2

---

## Tünet

DEBUG módban (`DEBUG=1`):
1. A könyvtárnevek **megjelennek** a képernyőn
2. ENTER-re **nem lehet belépni** a könyvtárakba
3. Helyette a képernyő **keret színe változik** (végtelen ciklus)
4. **~3 belépés után** a menü **megakad/instabil** lesz

---

## Gyökérok Elemzés

### 1. **Directory Marker Pozíció Hiba**

**Probléma:**
- Az `ISDIRECTORY` rutin (sor 945-953) a **32. byte-ot** (offset 31) vizsgálja, és `$04` értéket vár directory esetén
- A DEBUG mock adatok (`DIR1/DIR2/DIR3`) **33 byte méretűek voltak**, így a marker 1 byte-tal arrébb került
- A padding számítás hibás volt: `(31-N)` helyett `(30-N)` kellett volna

**Következmény:**
- Az `ISDIRECTORY` nem találta a `$04` markert a helyes pozíción
- Minden bejegyzést **fájlnak** azonosított
- ENTER-re a fájl-kezelés ágba esett, ahol típusdetektálás → ERROR → végtelen színváltás ciklus

### 2. **DIRLEVEL Overflow/Underflow**

**Probléma:**
- DEBUG módban a `DIRLEVEL` változó nyomon követi a mélységet (0, 1, 2)
- Csak 3 mock directory van: `DIR1` (szint 0), `DIR2` (szint 1), `DIR3` (szint 2)
- Ha `DIRLEVEL ≥ 3`, nem töltődött be semmilyen mock adat
- Ha `DIRLEVEL` underflow (0-ról DEC), `$FF` lett

**Következmény:**
- 3+ belépés után **értelmetlen buffer tartalommal** dolgozott
- Instabil működés, crash

---

## Javítások

### Fix #1: DIR1/DIR2/DIR3 Rekord Formátum Javítása

**Régi (HIBÁS) formátum:**
```asm
.TEXT "merhaba"    ; 7 byte
.BYTE 0             ; 1 byte (null)
.FILL (31-7), 0     ; 24 byte ← ROSSZ!
.BYTE $04           ; 1 byte (type marker)
; ÖSSZESEN: 33 byte ← 1 byte túlcsordulás!
```

**Új (HELYES) formátum:**
```asm
.TEXT "merhaba"    ; 7 byte (offset 0-6)
.BYTE 0             ; 1 byte (offset 7, null terminator)
.FILL (30-7), 0     ; 23 byte (offset 8-30, padding)
.BYTE $04           ; 1 byte (offset 31, type marker)
; ÖSSZESEN: 32 byte ← HELYES!
```

**Érintett sorok:**
- DIR1: 1612, 1617, 1622, 1627, 1632
- DIR2: 1642, 1647, 1652, 1657, 1662, 1667
- DIR3: 1677, 1682, 1687, 1692, 1697, 1702

**Változtatás:**
```diff
- .FILL (31-N), 0
+ .FILL (30-N), 0
```

ahol `N` = a fájlnév hossza.

---

### Fix #2: DIRLEVEL Underflow Védelem

**Hely:** Sor 229-235

**Probléma:**
Amikor ".." directory-ra lépünk, a `DEC DIRLEVEL` végrehajtódik, de nincs védelem `DIRLEVEL=0` esetén.

**Javítás:**
```asm
.if DEBUG = 1
	; Prevent DIRLEVEL underflow
	LDA DIRLEVEL
	BEQ +
	DEC DIRLEVEL
+
.endif
```

**Eredmény:**
- Ha `DIRLEVEL` már 0, nem csökken tovább
- Nincs `$FF` overflow

---

### Fix #3: DIRLEVEL Overflow Clamp

**Hely:** Sor 358-365 (ENTERDIR), sor 795-802 (GOBACK)

**Már létezett, de dokumentáltuk:**
```asm
INC DIRLEVEL
; DEBUG mock supports DIRLEVEL 0..2 only (DIR1..DIR3)
LDA DIRLEVEL
CMP #3
BCC +
LDA #2
STA DIRLEVEL
+
```

**Eredmény:**
- Ha `DIRLEVEL ≥ 3`, visszaáll 2-re
- Mindig érvényes DIR1/DIR2/DIR3 buffer töltődik be

---

### Fix #4: Felesleges GAMELIST Teszt Adatok Eltávolítása

**Hely:** Sor 1526-1540 (régi)

**Probléma:**
A `GAMELIST` bufferben voltak hardcoded teszt adatok, amik:
- Félinformációk voltak (csak név, nincs type marker)
- DEBUG módban felülíródtak `SETDIR1/2/3` hívásokkal
- Félrevezetőek voltak

**Javítás:**
```asm
; Directory entries buffer - populated at runtime
GAMELIST
DIRLOAD = GAMELIST - 2

; Reserve space for 20 directory entries (20 * 32 bytes = 640 bytes)
; In DEBUG mode: SETDIR1/2/3 copies DIR1/2/3 data here
; In release mode: IRQ_ReadDirectory fills this from SD card
	.FILL (20 * 32), 0
```

**Eredmény:**
- Tiszta, inicializálatlan buffer
- DEBUG/release működés egyértelmű
- Nincs félinformáció

---

## Tesztelés

### Elvárt Működés DEBUG=1 Módban

1. **Indításkor:** DIR1 tartalom jelenik meg (5 item)
   - `merhaba` (DIR)
   - `televole` (DIR)
   - `hello.prg` (FILE)
   - `africa.koa` (FILE)
   - `guzel.petg` (FILE)

2. **ENTER `merhaba`-ra:** DIR2 tartalom töltődik be (6 item)
   - `..` (DIR) ← vissza
   - `deneme1` (DIR)
   - `deneme2` (DIR)
   - `firzt.prg` (FILE)
   - `latina.koa` (FILE)
   - `spell.petg` (FILE)

3. **ENTER `deneme1`-re:** DIR3 tartalom töltődik be (6 item)
   - `..` (DIR)
   - `kubakuba` (DIR)
   - `firzt.prg` (FILE)
   - `latiya.koa` (FILE)
   - `spelz.petg` (FILE)
   - `son.prg` (FILE)

4. **ENTER `kubakuba`-ra:** Nem lép mélyebbre (DIRLEVEL clamp 2-re)

5. **ENTER `..`-ra:** Vissza DIR2-be (DIRLEVEL=1)

6. **ENTER `..`-ra:** Vissza DIR1-be (DIRLEVEL=0)

7. **ENTER `..`-ra:** Marad DIR1-ben (underflow védelem)

---

## Build Utasítás

```bash
cd IRQHack64
make clean
make DEBUG=1
```

Vagy ha ACME assemblert használsz közvetlenül:
```bash
acme -D DEBUG=1 -o output.prg Menus/EasySD/IrqLoaderMenuNew.s
```

---

## Összefoglalás

| Hiba | Javítás | Státusz |
|------|---------|---------|
| DIR1/DIR2/DIR3 padding számítás (33 byte → 32 byte) | `.FILL (31-N)` → `.FILL (30-N)` | ✅ KÉSZ |
| DIRLEVEL underflow (DEC 0 → $FF) | BEQ védelem hozzáadva | ✅ KÉSZ |
| DIRLEVEL overflow (INC 2 → 3+) | Clamp már létezett, dokumentálva | ✅ OK |
| Felesleges GAMELIST teszt adatok | Eltávolítva, .FILL 640 byte | ✅ KÉSZ |

---

## Megjegyzések

- A javítás **csak DEBUG módra** vonatkozik (`DEBUG=1`)
- Release módban (`DEBUG=0`) ezek a mockk adatok **nem fordulnak le**
- A valódi SD kártyás működés **nem érintett**
- A DIRSTACK runtime verem (DIRSTACK buffer, `$FD00`) **más**, mint a DIR1/DIR2/DIR3 mock adatok

---

**Státusz:** ✅ **Tesztelhető**
**Következő lépés:** Build + teszt VICE emulátorban DEBUG=1 móddal
