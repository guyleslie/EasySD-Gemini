# IRQHack64/Loader - C64 Oldali Könyvtárak és Loader Fájlok

**Utoljára frissítve:** 2026-01-01

Ez a könyvtár tartalmazza a C64 oldali cartridge kommunikációs könyvtárakat, API makrókat, valamint a loader programokat.

---

## 📁 Könyvtárstruktúra

```
Loader/
├── Apps/              - Type B standalone alkalmazások (pl. BurstLoader)
├── Bridges/           - I/O bridge layers (e.g. KernalBridge)
├── Common/            - Közös include fájlok (System.inc, EasySD.inc)
├── _archive/          - Elavult/nem használt fájlok (archivált)
└── (library files)    - Aktív cartridge library fájlok
```

---

## 📚 Aktív Library Fájlok

### Low-Level Cartridge API

| Fájl | Méret | Leírás |
|------|-------|--------|
| **CartLib.s** | 7.4 KB | Low-level cartridge kommunikációs primitívek (IRQ_StartTalking, IRQ_Send, IRQ_ReceiveFragment). Cassette buffer-be relocálható ($033C). |
| **CartLibCommon.s** | 652 B | Közös konstansok és konfigurációs értékek (CARTRIDGE_BANK_VALUE). Normál ROM verzióhoz ($80AB). |
| **CartLibDebug.s** | 7.0 KB | Debug infrastruktúra (DEBUG=1 módban aktív). Loader állapot dump-olása fix memóriacímre ($CF00-$CF42). |

### High-Level API

| Fájl | Méret | Leírás |
|------|-------|--------|
| **CartLibHi.s** | 18 KB | High-level API függvények: IRQ_OpenFile, IRQ_ReadFile, IRQ_CloseFile, LoadFileBySize (általános fájlbetöltő <64KB). |
| **CartLibStream.s** | 5.0 KB | Streaming API (StreamLargeFile_Internal). Low-level IO2 streaming loop, NEM publikus API! |
| **SafeStreamImpl.s** | 2.9 KB | Publikus streaming wrapper. SafeStream API különböző teljesítményprofilokkal (SAFE/NORMAL/FAST). |

### Memory Maps és Zero Page

| Fájl | Méret | Leírás |
|------|-------|--------|
| **CartMemoryMap.inc** | 7.8 KB | High memory szimbólumok (TRANSFER_BUFFER_ADDR, NMI_HANDLER_REGION, BURST_BUFFER_ADDR). Referencia, nem kötelező használat. |
| **CartZpMap.inc** | 18 KB | Zero Page API paraméterek ($64-$95). ZP pointer-alapú API (ZP_IRQ_API_DATA_LO/HI, ZP_IRQ_API_DATA_LENGTH). KÖTELEZŐ minden API használónak. |

### Makrók

| Fájl | Méret | Leírás |
|------|-------|--------|
| **APIMacros.s** | 6.0 KB | API helper makrók (#SETADDR, #SETLENGTH, #CHANGEBANK stb.). Pluginok és menük használják. |
| **SystemMacros.s** | 11 KB | Rendszer szintű makrók (SAVESTATE, RESTORESTATE, hardware vezérlés). |
| **DebugMacros.s** | 2.6 KB | Debug makrók (DEBUG=1 módban). Opcionális, csak fejlesztés során. |
| **DebugStrings.s** | 1.6 KB | Debug üzenetek (DEBUG=1 módban). Opcionális. |

---

## 🚀 Loader Programok (ROM és Stub)

| Fájl | Méret | Leírás | Build kimenet |
|------|-------|--------|---------------|
| **IRQLoader.65s** | 7.2 KB | Fő cartridge ROM loader ($8000-ban). Autostart, NMI handler setup, file betöltés. | `build/IRQLoaderRom.bin` (Arduino EEPROM) |
| **LoaderStub.65s** | 2.8 KB | Cassette buffer-be másolandó launcher stub. Cartridge kikapcsolás szinkronizálása. | `build/LoaderStub.h` (Arduino C header, stubData[]) |

**Build Process:**
1. `build_core.bat` → Compiles IRQLoader.65s és LoaderStub.65s
2. `PostBuild.bat` → Konvertálja Arduino header formátumba (Bin2ArdH.exe, CreateEpromLoader.exe)

---

## 📂 Common/ Alkönyvtár

| Fájl | Méret | Leírás |
|------|-------|--------|
| **System.inc** | 1.5 KB | System konstansok (VIC, SID, CIA címek, KERNAL rutinok). |
| **EasySD.inc** | 1.4 KB | IRQHack64-specifikus konstansok (cartridge címek, protokoll értékek). |

---

## 🗄️ Archiváltak (_archive/)

A következő fájlok **NEM használtak** az aktív projektben, archiválva lettek:

| Fájl | Eredeti méret | Archiválás oka |
|------|---------------|----------------|
| **CartLibDE.s** | 7.4 KB | Csak KernalIOShimStub.s használta (elavult stub verzió). Megegyezik CartLib.s-szel, csak régebbi kommentek. |
| **CartLibHiDE.s** | 15 KB | Csak KernalIOShimStub.s használta (elavult stub verzió). Régebbi CartLibHi verzió. |
| **CartLibCommonDE.s** | 242 B | Csak KernalIOShimStub.s használta. Régebbi CartLibCommon verzió (minimális kommentek). |
| **Transfer.65s** | 0 B | **ÜRES FÁJL**, soha nem használt. |

**"DE" verzió jelentése:** Nem egyértelmű, valószínűleg egy régebbi development snapshot vagy egyszerűsített verzió. Csak az elavult PrgPluginStub.s használta, ami már nem része az aktív buildnek (compileStub.bat.old).

---

## 📖 Használati Útmutató

### Pluginok (Type A, $C000+)

Minden Type A pluginnak be kell includeolnia:
```assembly
.include "../../Loader/APIMacros.s"     ; API helper makrók
.include "../../Loader/CartLibStream.s" ; Ha streaming kell (WavPlayer, stb.)
```

CartLibHi.s és CartLib.s automatikusan include-olódnak a CartLibStream.s-en keresztül.

### Type B Apps ($080E)

Standalone alkalmazások (BurstLoader):
```assembly
.include "../../CartLibStream.s"  ; Teljes API stack
```

### Shim-ek

Compatibility shim-ek (KernalIOShim):
```assembly
.include "../../DebugMacros.s"
.include "../../APIMacros.s"
.include "../../CartLibStream.s"
.include "../../DebugStrings.s"
```

---

## 🔗 Függőségek (Include Chain)

```
CartLibStream.s
  └─> CartZpMap.inc (Zero Page map - KÖTELEZŐ)
  └─> CartLibHi.s
      └─> CartLib.s
          └─> SystemMacros.s
          └─> CartLibCommon.s
              └─> Common/System.inc
              └─> Common/EasySD.inc
          └─> CartLibDebug.s (ha DEBUG=1)
```

**Fontos:** Elég csak `CartLibStream.s`-t includeolni, a többi automatikusan jön.

---

## 🛠️ Build Környezet

- **Assembler:** 64tass v1.59.3120
- **Build scriptek:** `build_core.bat`, `PostBuild.bat`
- **Debug mód:** `-D DEBUG=1` flag használata build során

---

## 📝 Megjegyzések

1. **Zero Page használat:** Az API $64-$95 ZP régióban működik. Lásd: `CartZpMap.inc` és `docs/ZP_GUIDELINES.md`

2. **Type A vs Type B:** Lásd: `docs/MEMORY_MAP_CANONICAL.md` Section 4

3. **Streaming protokoll:** Lásd: `docs/IO2_PROTOCOL_SPECIFICATION.md`

4. **MyCartLibHi.s speciális eset:** A BurstLoader saját CartLibHi változatot használ optimalizált NMI handler elhelyezéshez. Ez NEM általános használatra szánt library!

---

**Referencia dokumentáció:**
- `docs/MEMORY_MAP_CANONICAL.md` - Type A/B kategóriák, memory layout
- `docs/ARCHITECTURE_REVIEW.md` - Rendszer architektúra áttekintés
- `docs/IO2_PROTOCOL_SPECIFICATION.md` - IO2 streaming protokoll
- `docs/ZP_GUIDELINES.md` - Zero Page használati szabályok

---

**END OF README**
