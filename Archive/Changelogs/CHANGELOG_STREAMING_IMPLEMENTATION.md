# CHANGELOG: Streaming Implementation for Large Files (EasySD Gemini)

## 1. Összefoglaló

Ez a dokumentum a 16-bites fájlméret-korlátozás feloldására irányuló módosításokat részletezi az EasySD Gemini firmware-ben és a C64 assembly könyvtárban. A fő cél egy megbízható mechanizmus biztosítása a 64KB-nál nagyobb fájlok (pl. CVID, WAV) betöltésére, miközben fenntartjuk a visszafelé kompatibilitást.

Bevezetésre került egy új C64 assembly rutin (`StreamLargeFile`) és egy ehhez illeszkedő, időtúllépéses mechanizmussal ellátott streaming logika az Arduino firmware-ben. A régi `LoadFileBySize` rutin érintetlen maradt, és továbbra is használható kisebb fájlokhoz.

## 2. A Probléma

A projekt eredeti fájlbetöltő rutinja, a C64 oldali `LoadFileBySize`, 16-bites aritmetikát használt a betöltendő adatblokk méretének (`fájlméret - skip_bytes`) kiszámításához. Ez a megközelítés hatékony volt a legtöbb hagyományos C64 fájl (pl. PRG) esetében, amelyek általában kisebbek, mint 64KB. Azonban ez a 16-bites korlát ellehetetlenítette a 64KB-ot meghaladó fájlok, mint például a modern CVID videók vagy WAV hangfájlok megbízható betöltését. Az `IRQ_GetInfoForFile` már képes volt a 32-bites fájlméret lekérdezésére, de a `LoadFileBySize` nem használta ki ezt a képességet.

Továbbá, az Arduino firmware-ben már létezett egy `COMMAND_STREAM` funkció a streaminghez, de annak lezárási mechanizmusa a `SEL` vonal állapotától függött, amelyet a C64 szoftveresen nem tudott vezérelni, mivel az Arduino `A4` (SEL) lábára kötött C64 `RESET` vonal nem irányítható. Ez azt eredményezte volna, hogy az Arduino beragad a streaming funkcióba, miután a C64 befejezte az adatátvitelt.

## 3. A Megoldás

A probléma megoldására egy dupla pufferelésű, interrupt-vezérelt streaming mechanizmust valósítottunk meg, amely a C64 és az Arduino között kommunikál, és egy időtúllépéses mechanizmussal biztosítja a megbízható lezárást.

### 3.1. Arduino Oldali Módosítások (`Arduino/IRQHack64/CartApi.cpp`)

*   **Időbélyegző változó hozzáadva:** Bevezetésre került egy `volatile static unsigned long lastStreamRequestTime = 0;` nevű változó. Ez az Arduino `millis()` órájával méri az utolsó C64-től érkező bájt-kérés idejét.
*   **`DoubleBufferedStreaming` ISR frissítése:** A `DoubleBufferedStreaming` interrupt szolgáltató rutint módosítottuk, hogy minden C64-től érkező bájt-kéréskor frissítse a `lastStreamRequestTime` változót az aktuális idővel. Ez jelzi az Arduino-nak, hogy a C64 még aktívan fogadja az adatokat.
*   **Időtúllépés kezelés a `HandleStream` függvényben:** A `HandleStream` fő ciklusában implementáltunk egy 100 milliszekundumos (definiálva `STREAM_TIMEOUT_MS`-ként) időtúllépési mechanizmust. Ha a C64 ezt az időtúllépési értéket meghaladó ideig nem küld új kérést, az Arduino feltételezi, hogy a C64 befejezte az átvitelt. Ekkor az Arduino elegánsan kilép a streaming módból, újra engedélyezi a normál parancsváró módot (`cartInterface.StartListening()`), és visszatér a fő API ciklusba. Ezáltal az Arduino soha nem ragad be a streaming állapotba. Ez a módosítás tette feleslegessé a `SEL` vonal C64-ről történő vezérlését.

### 3.2. C64 Oldali Változások (`IRQHack64/Loader/CartLibStream.s`)

*   **Új `StreamLargeFile` rutin:** Létrehoztunk egy új assembly rutint `StreamLargeFile` néven. Ez a rutin helyettesíti a `LoadFileBySize`-t a 64KB-nál nagyobb fájlok esetében.
*   **Streaming logika:**
    *   A rutin beállítja a Zeropage memóriacímeket a cél RAM-cím és a 32-bites fájlméret számára.
    *   Meghívja az `IRQ_Stream` rutint az Arduino-n a streaming indításához.
    *   Egy fő ciklusban a C64 folyamatosan impulzust generál az `/IO2` vonalon (egy `LDA $DF00` utasítással) minden egyes bájtkéréshez.
    *   Beolvassa a bájt(oka)t a cartridge portról (`$DE00`), és elmenti a cél RAM-címre.
    *   A 32-bites bájtszámlálót folyamatosan csökkenti.
    *   Amikor a számláló eléri a nullát, a C64 egyszerűen abbahagyja az impulzusok küldését.
*   **Lezárás:** A rutin visszatér a C64-es programba. Az Arduino a fent leírt időtúllépési mechanizmus révén érzékeli a C64 "csendjét", és önállóan lezárja a streaming folyamatot. Emiatt a C64 oldalon nem szükséges speciális "stop" jelet küldeni.

### 3.3. WavPlayer Plugin Stabilizálás (2025-12-21)

A `WavPlayer.s` plugin átnézése és javítása során a következő streaming-specifikus stabilizációs lépések történtek:
*   **API ébresztés:** Hozzáadva az `IRQ_StartTalking` hívás, amely biztosítja, hogy az Arduino válaszoljon a streaming parancsokra.
*   **Regiszter mentés az IRQ-ban:** A bájtokat kártyáról olvasó IRQ rutinok most már elmentik és visszaállítják az `A`, `X`, `Y` regisztereket, megakadályozva a főprogram összeomlását.
*   **Pufferelt lejátszás:** A plugin most már alapértelmezettként a RAM-pufferelt módot használja, amely jobban tolerálja a streaming közbeni SD kártya késleltetéseket.
*   **Optimalizált I/O:** A redundáns port-olvasások eltávolításával több ciklus marad a C64-nek az egyéb feladatokra az IRQ-ban.

### 3.4. SD Kártya Olvasási Optimalizálás (2025-12-21)

*   **Puffer méret optimalizálás:** Az Arduino oldali streaming puffer mérete (`DOUBLE_BUFFER_SIZE`) 64 bájtról 256 bájtúra növelve a `Arduino/IRQHack64/CartApi.h` fájlban. Ez a módosítás jelentősen javítja az SD kártya olvasási hatékonyságát azáltal, hogy jobban illeszkedik az SD kártya 512 bájtos natív blokkméretéhez, ezáltal csökkentve az I/O műveletek számát és növelve a rendszer robusztusságát.

## 4. Hogyan Használjuk az Új Funkciót?

Az új `StreamLargeFile` rutin használatához a C64 assembly programozónak a következő lépéseket kell megtennie:

1.  **Forrásfájl beágyazása:**
    ```assembly
    .include "CartLibStream.s"
    ```

2.  **Előkészület a Zeropage-en (Zero Page):**
    A `StreamLargeFile` meghívása előtt a Zeropage következő címeit kell beállítani:
    *   `STREAM_TARGET_ADDR_LO ($90)` és `STREAM_TARGET_ADDR_HI ($91)`: A C64 RAM-jában lévő 16-bites kezdőcím, ahová a fájl tartalmát be kell tölteni.
    *   `STREAM_BYTES_REMAIN_0` ($92) ... `STREAM_BYTES_REMAIN_3` ($95): A betöltendő fájl 32-bites teljes mérete (LSB-től MSB-ig). Ezt az értéket az `IRQ_GetInfoForFile` rutin hívása után lehet kinyerni.

3.  **Hívási szekvencia:**
    ```assembly
    ; --- Példa: Fájlnév beállítása (ha szükséges, pl. IRQ_SetName-nel) ---
    ; LDA #<filename_string_address
    ; LDY #>filename_string_address
    ; JSR IRQ_SetName          ; filename_string_address egy NUL-terminált stringre mutat
    
    ; --- Fájl megnyitása olvasásra ---
    LDX #O_READ             ; Vagy a megfelelő flag
    JSR IRQ_OpenFile
    BCS handle_error        ; Hiba történt a fájl megnyitása közben

    ; --- Fájl információk lekérdezése (a 32-bites méretért) ---
    JSR IRQ_GetInfoForFile
    BCS handle_error        ; Hiba történt

    ; Itt feltételezzük, hogy az IRQ_GetInfoForFile valamilyen módon visszaadta
    ; a 32-bites fájlméretet, amit most be kell tölteni a Zeropage-re.
    ; Az alábbi példa feltételezi, hogy a méret valamilyen 'file_size_xxx' címeken van.
    LDA file_size_lsb       ; Az IRQ_GetInfoForFile által visszaadott LSB
    STA STREAM_BYTES_REMAIN_0
    LDA file_size_msb       ; A második bájt
    STA STREAM_BYTES_REMAIN_1
    LDA file_size_upper_lsb ; A harmadik bájt
    STA STREAM_BYTES_REMAIN_2
    LDA file_size_upper_msb ; Az MSB
    STA STREAM_BYTES_REMAIN_3

    ; --- Cél-memóriacím beállítása (ahová a fájl betöltődik) ---
    LDA #<target_ram_address  ; Pl. #$00 a $C000 esetén (alsó bájt)
    STA STREAM_TARGET_ADDR_LO
    LDA #>target_ram_address  ; Pl. #$C0 a $C000 esetén (felső bájt)
    STA STREAM_TARGET_ADDR_HI

    ; --- A nagyméretű fájl streamelése ---
    JSR StreamLargeFile
    BCS handle_error        ; Hiba történt, ha a streaming sikertelen volt

    ; --- Fájl bezárása ---
    JSR IRQ_CloseFile
    BCS handle_error        ; Hiba történt

    ; --- A betöltés sikeres, a fájl a 'target_ram_address'-en található ---
    RTS

handle_error:
    ; Itt kezelheted a hibákat, pl. hibaüzenet megjelenítése, vagy újrapróbálkozás
    RTS
    ```

## 5. Érintett Fájlok

*   `Arduino/IRQHack64/CartApi.cpp`
*   `IRQHack64/Loader/CartLibStream.s` (új fájl, majd módosítva)
*   `Arduino/IRQHack64/CartApi.h` (implicit, a COMMAND_STREAM definíciót használja, bár közvetlenül nem módosult a kérés során)

A `LoadFileBySize` rutin és a hozzá tartozó fájlok érintetlenek maradtak, biztosítva a visszafelé kompatibilitást.