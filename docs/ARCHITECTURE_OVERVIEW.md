# EasySD – Rendszer-architektúra (2026)

Ez a dokumentum röviden, közérthetően bemutatja az EasySD rendszer jelenlegi működését, főbb részeit és adatáramlását.

## Áttekintés
Az EasySD egy SD kártya olvasó megoldás Commodore 64-hez. Két fő részből áll:
- **C64 oldali szoftver**: Menü, plugin rendszer, fájlkezelés (6502 assembly)
- **Arduino oldali firmware**: SD kártya kezelése, fájlrendszer, kommunikáció (C++)

## Fő komponensek
- **C64 cartridge**: Hardver, ami összeköti a C64-et az Arduinóval
- **Menü program**: A C64-en futó böngésző, amivel a felhasználó fájlokat választhat
- **Plugin rendszer**: Speciális fájltípusokhoz külön betölthető programok
- **Arduino firmware**: Kezeli az SD kártyát, könyvtárakat, fájlokat, és kommunikál a C64-gyel

## Adatáramlás
1. A C64 elindítja a menüt, ami kommunikál az Arduinóval
2. Az Arduino beolvassa az SD kártya tartalmát, visszaküldi a könyvtárlistát
3. A felhasználó kiválaszt egy fájlt, a C64 kéri az adatot
4. Az Arduino elküldi a fájlt, a C64 betölti vagy pluginba továbbítja

## Kommunikáció
- Egyedi soros protokoll, amelyen keresztül a C64 és az Arduino bájtonként adatot cserél
- A kommunikáció megbízhatóságát szoftveres ellenőrzések biztosítják

## Hardver kapcsolat
- A cartridge a C64 bővítőportján keresztül csatlakozik
- Az Arduino közvetlenül vezérli az SD kártyát és a C64 adatvonalait

## C64-specifikus környezet és hardver sajátosságok

- **ROML cartridge**: Az EasySD egy ROML típusú cartridge-ként jelenik meg a C64 számára. Ez azt jelenti, hogy a cartridge a C64 memóriatérképének ROML tartományába (pl. $8000-$9FFF) csatlakozik, így a menü és a kommunikációs rutinok közvetlenül, gyorsan elérhetők. Ez eltér a RAM vagy ROMH cartridge-ektől, és fontos a kompatibilitás, valamint a stabil működés szempontjából.

- **Időzítések és busz-hozzáférés**: A C64-en a cartridge-nek figyelembe kell vennie a CPU ciklusokat, az NMI (Non-Maskable Interrupt) és /RESET vonalakat. Az Arduino a C64 /RESET vonalát is vezérli a stabil indulás érdekében, és a kommunikáció során gondoskodik arról, hogy a C64 adatbusza tri-state (lebegő) állapotba kerüljön, amikor szükséges. Az EXROM vonal kezelése biztosítja, hogy a cartridge csak akkor legyen aktív, amikor kell.

- **Arduino Nano 3.x (ATmega328P)**: Az EasySD hardveres központja egy Arduino Nano 3.x (ATmega328P) mikrokontroller, amely közvetlenül csatlakozik a C64 cartridge porthoz és az SD kártyához. Ez a típus stabil, jól támogatott, és a PCB kialakítás is ehhez igazodik. Az Arduino firmware gondoskodik a C64-hez szükséges időzítésekről, a gyors SD elérésről, és a megbízható kommunikációról.

- **PCB és csatlakozások**: A nyomtatott áramköri lap (PCB) úgy lett tervezve, hogy a C64 bővítőportján keresztül minden szükséges jelet (adat, cím, vezérlővonalak) elérjen, és az Arduino, valamint az SD kártya stabilan, megbízhatóan működjön. A hardveres kialakításnál figyelembe kell venni a C64 érzékenységét a busz- és tápellátási problémákra.

Ezek a sajátosságok elengedhetetlenek a rendszer stabil működéséhez, és minden fejlesztésnél, hibakeresésnél figyelembe kell venni őket.

---
Ez a leírás kizárólag a jelenlegi, működő rendszerre vonatkozik. További részletek: plugin interfész, memória térkép, protokoll külön dokumentumban.