# MultiLoad javítási állapot

Dátum: 2026-05-03

## Kiinduló hiba

A normál PRG betöltés `/MULTILOAD/`-on kívül stabilan működik. Ezért a normál PRG útvonalat nem módosítjuk érdemben.

A MultiLoad PRG-k többféleképpen hibáztak:

- `LASTNINJA1`: korábban `GotoPath` után nem jutott el `OpenFile`-ig, piros keret után BASIC reset volt.
- `IOWA JACK`: eljutott `OpenFile OK` és `FileSize` állapotig, de nem jutott `ReadFile`-ig.
- `LASTNINJA2`: `GotoPath` után `Unknown cmd` jelent meg.
- Sikertelen MultiLoad után a következő MultiLoad indítások instabilabbak voltak, amíg egy normál PRG nem futott le.

## Mostani friss tesztállapot

Friss `LASTNINJA1 / THE LAST NINJA+.PRG` teszt:

```text
[INFO][ML] MLBoot launched
[INFO][DIR] GotoPath:
/MULTILOAD/LASTNINJA1
[INFO][ML] OpenFile: THE LAST NINJA+.PRG
[INFO][FILE] File opened successfully
[INFO][ML] OpenFile OK
[INFO][ML] FileSize: 44239
[INFO][ML] Read
```

Ez előrelépés: a MultiLoad első LOAD session most már feláll, a path visszaállítás működik, az első part file megnyílik, a file size átmegy, és a C64 READ parancsig eljut.

A képernyőtünet most:

- indulás után fekete külső, kék belső keret,
- később fekete/fekete,
- hang hallható,
- a C64 állva marad,
- a SEL gomb működik.

Ez már nem ugyanaz a hiba, mint a korábbi piros keretes reset. A mostani állapot alapján a hiba vagy a READ adatátvétel végén, vagy közvetlenül a betöltött first-part indításánál van.

Fontos: a serial logban látható `[INFO][ML] Read` nem feltétlenül azt jelenti, hogy a log tényleg ott állt meg. A `HandleReadFile()` a `ReadFile pages:` sor kiírása után nagyon gyorsan `noInterrupts()` alá megy és bináris adatot streamel a C64 felé, ezért debug serialban a sor vége könnyen nem ürül ki.

## Eddigi módosítások

### 1. MLBoot teljes game path patch

Fájlok:

- `Arduino/EasySD/CartApi.cpp`
- `Arduino/EasySD/CartApi.h`
- `EasySD/Loader/Bridges/MultiLoad/MLBoot.s`

Korábban az Arduino csak a first-part PRG nevét patchelte az MLBoot blobba. Most a teljes abszolút game path is bekerül:

```text
/MULTILOAD/<game>
```

Az MLBoot ezt `RL_INSTALL` után bemásolja `RL_DIR_PATH`-ra. Így a resident loader minden LOAD előtt `COMMAND_GOTO_PATH`-tal vissza tud állni a játék könyvtárába.

Miért kellett:

- A MultiLoad későbbi LOAD-jai nem bízhatnak abban, hogy az Arduino aktuális CWD-je még mindig a játék mappája.
- A friss log igazolja, hogy a path rész most működik: `GotoPath`, majd `OpenFile` sikeresen lefut.

### 2. Redundáns Arduino oldali könyvtárváltás kivétele

Fájl:

- `Arduino/EasySD/CartApi.cpp`

Korábban MLBoot küldés után volt `Init()` és újranavigálás a game pathra. Ez redundáns volt, és session/race problémát is okozhatott.

Most MLBoot után az Arduino csak visszaáll page 0-ra, újraindítja a listeninget, és aktív MultiLoad módba lép.

Miért kellett:

- A C64 oldali resident loader már maga küldi a `GotoPath` parancsot.
- A felesleges root/path churn kikerült a kritikus MLBoot start időablakból.

### 3. Resident loader VIC display/IRQ védelem

Fájl:

- `EasySD/Loader/ResidentLoader.s`

Az `RL_HANDLER` elején mentjük és ideiglenesen letiltjuk:

- `$D011` display enable bit,
- `$D01A` VIC IRQ enable mask.

Kilépéskor minden sikeres és hibás útvonal visszaállítja ezeket még `$01=$35` alatt.

Miért kellett:

- A normál `PROT_*` loader hívások csendesebb busz/display környezetben futnak.
- A MultiLoad resident útvonal eddig nem kapta meg ugyanezt a védelmet.
- CIA1 maskhoz nem nyúltunk, mert nem olvasható vissza biztonságosan.

### 4. Resident stub IRQ/status megőrzés

Fájl:

- `EasySD/Loader/ResidentLoader.s`

A stub most `SEI` alatt vált `$01=$35` módba, hogy ne fusson IRQ rossz banking alatt. Közben megőrzi a hívó eredeti processzor státuszát, majd a végén külön állítja vissza a LOAD eredmény carry flagjét.

Miért kellett:

- Az IRQ-k ne fussanak úgy, hogy a Kernal ROM helyén RAM látszik.
- Ugyanakkor ne rontsuk el a játék eredeti IRQ enable/disable állapotát.

### 5. NMI receive wait low-RAM stub

Fájlok:

- `EasySD/Loader/ResidentLoader.s`
- `EasySD/Loader/Common/System.inc`
- `EasySD/Loader/CartZpMap.inc`

A resident handler `$E800` alatt fut, ami `$01=$35` mellett látható. A tényleges NMI adatátvételi várakozás viszont most egy low-RAM stubba került.

Ez a stub:

- `$01=$37`-re vált,
- a standard Kernal NMI trampoline útvonalon engedi futni a cartridge NMI handlerét,
- a végén visszavált `$01=$35`-re.

Miért kellett:

- A normál CartLib receive útvonal is `$01=$37` alatt várja az NMI adatátvitelt.
- Az Iowa Jack korábbi `FileSize` utáni megállása alapján ez volt az egyik fő gyanús pont.

### 6. Arduino MultiLoad session cleanup és jobb Unknown cmd log

Fájl:

- `Arduino/EasySD/CartApi.cpp`

Változások:

- `Unknown cmd` most kiírja a konkrét command byte értéket is.
- MultiLoad módban, ha egy session parancs után elakad, az Arduino idle timeout után lezárja a félbehagyott sessiont és a nyitott file-t.

Miért kellett:

- A korábbi post-failure instabilitás arra utalt, hogy félbemaradt resident session állapot maradhat az Arduino oldalon.
- Ha újra lesz `Unknown cmd`, a konkrét byte alapján lehet tovább szűkíteni.

### 7. `deploy-debug.bat` frissítése

Fájl:

- `deploy-debug.bat`

A debug deploy első lépése most teljes release artifact frissítés:

```bat
python Tools/build.py release
```

Miért kellett:

- Az MLBoot blob az Arduino `FlashLib.h`-ba generálódik.
- A korábbi `release --skip-arduino` nem garantálta, hogy a debug firmware a friss MLBoot blobot kapja.
- A serial debug továbbra is helyes út: release C64 oldal + debug serial Arduino firmware.

### 8. MLBoot launch döntés visszaigazítása a normál loaderhez

Fájl:

- `EasySD/Loader/Bridges/MultiLoad/MLBoot.s`

A friss teszt alapján a betöltés már legalább a READ útvonalig eljut. A következő erős gyanús pont az volt, hogy az MLBoot nem pontosan ugyanúgy döntött BASIC RUN vs gépi kód `JMP` között, mint a működő normál `LoaderStub.65s`.

Most az MLBoot ismét a normál loader szabályát követi:

- ha a load address `$0801`, BASIC `RUN`,
- ha hybrid BASIC SYS stubnak tűnik, BASIC `RUN`,
- egyébként gépi kód `JMP`.

Miért kellett:

- A normál PRG loader ezzel a logikával működik.
- A MultiLoad first-part betöltés utáni fekete/fekete + hang állapot lehet hibás belépési mód következménye is.
- Ez csak az MLBoot first-part indítását érinti, a normál PRG útvonalat nem.

## Fordítási állapot

Utolsó ellenőrzések:

- `python Tools/build.py release`: sikeres.
- Arduino release: `25192 / 30720` flash, `1501 / 2048` RAM.
- Arduino debug: `30660 / 30720` flash, `1584 / 2048` RAM.

A debug firmware nagyon szűk, körülbelül 60 byte flash tartalék maradt.

## Jelenlegi legvalószínűbb hibapontok

1. **Betöltés utáni rossz launch mód**
   - Erős gyanú a friss `THE LAST NINJA+.PRG` teszt alapján.
   - Ezt most javítottuk az MLBoot launch döntés normál loaderhez igazításával.

2. **READ adatátvételi végpont**
   - Ha a következő tesztben továbbra sem indul, látni kell, hogy a C64 elküldi-e a `CloseFile` / `EndTalking` szakaszt.
   - Ha nincs `File closed`, akkor a C64 valószínűleg nem jut túl a READ adatfogadáson.

3. **Betöltött program későbbi saját loader logikája**
   - Ha az első part már tényleg elindul, de később nincs új `GotoPath` + `OpenFile`, akkor a játék vagy nem a Kernal `$FFD5` LOAD-on keresztül tölt, vagy felülírja a resident stub területét.

4. **Resident stub felülírás későbbi in-game LOAD előtt**
   - Ezt csak akkor érdemes canary teszttel vizsgálni, ha az első part már bizonyíthatóan elindult.

## Következő tesztelési sorrend

1. `deploy-debug.bat`
2. `/MULTILOAD/LASTNINJA1/THE LAST NINJA+.PRG`
3. Figyelni:
   - van-e `ReadFile pages:` teljes sor,
   - megjelenik-e `File closed`,
   - eltűnik-e a fekete/fekete + hang megállás,
   - elindul-e a first part.
4. Ha még áll:
   - ugyanazt kipróbálni `THE LAST NINJA.PRG`-vel is,
   - utána `IOWA JACK.PRG`,
   - majd `LAST NINJA 2.PRG`.

## Rövid következtetés

Az első nagy hiba, hogy az MLBoot utáni resident LOAD session nem állt fel stabilan, már javulni látszik. A friss log szerint a rendszer eljut `GotoPath`, `OpenFile`, `FileSize` és `Read` állapotig.

A jelenlegi fókusz ezért áthelyeződött: már nem path vagy file open hibát keresünk, hanem a READ adatátvétel végét és a betöltött first-part indítási módját.
