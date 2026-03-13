# Arduino CLI Setup - EasySD

## Mi ez?

Az **arduino-cli** az Arduino hivatalos parancssoros eszköze, amely lehetővé teszi az Arduino projektek **fordítását és feltöltését IDE nélkül**.

## Miért hasznos?

✅ **Automatizált build+upload** - Egy paranccsal lefordít és feltölt
✅ **Garantált fájlok** - A projekt mappájából dolgozik, nem az Arduino IDE cache-ből
✅ **Gyorsabb** - Nincs GUI overhead
✅ **Scriptelhető** - Integrálható build pipeline-ba

## Telepítés

### Windows - Winget (ajánlott):

```powershell
winget install Arduino.ArduinoCLI
```

### Windows - Manuális:

1. **Töltsd le** az arduino-cli-t:
   https://arduino.github.io/arduino-cli/latest/installation/

2. **Csomagold ki** az `arduino-cli.exe` fájlt:
   `C:\EasySD Gemini\Tools\arduino-cli.exe`

3. **VAGY** rakd a PATH-ba (opcionális)

### Ellenőrzés:

```bash
arduino-cli version
```

Várható kimenet:
```
arduino-cli  Version: 0.35.x ...
```

## Első használat - Setup

**Egyszeri inicializálás** (board support + library telepítés):

```bash
cd "C:\EasySD Gemini"
python Tools\arduino_build_upload.py setup
```

Ez telepíti:
- Arduino AVR board support (arduino:avr)
- SdFat library
- Egyéb függőségek

## Használat

### 1. Build + Upload egy lépésben:

```bash
python Tools\arduino_build_upload.py upload COM3
```

*(Cseréld le COM3-at a saját portodra)*

### 2. Csak fordítás (upload nélkül):

```bash
python Tools\arduino_build_upload.py build
```

### 3. Elérhető portok listázása:

```bash
python Tools\arduino_build_upload.py list-ports
```

## Board Konfiguráció

Az `arduino_build_upload.py` automatikusan a helyes board-ot használja:

```
FQBN: arduino:avr:nano:cpu=atmega328old
```

Ez a következőt jelenti:
- **Board**: Arduino Nano
- **Processor**: ATmega328P (Old Bootloader)
- **Upload speed**: 57600 baud

## Hibaelhárítás

### "arduino-cli not found"

➡ Telepítsd az arduino-cli-t (lásd fent)
➡ VAGY másold az `arduino-cli.exe`-t a `Tools/` mappába

### "Error during install"

➡ Futtasd újra: `arduino-cli core update-index`
➡ Majd: `python Tools\arduino_build_upload.py setup`

### "Port not found"

➡ Ellenőrizd: `python Tools\arduino_build_upload.py list-ports`
➡ Windows: Device Manager → Ports (COM & LPT)
➡ Használd a megfelelő COM port-ot (pl. COM3, COM4)

### "Upload failed: programmer not responding"

➡ Rossz Processor beállítás?
➡ Próbáld: `cpu=atmega328` (New Bootloader, 115200 baud)
➡ Módosítsd az FQBN-t az `arduino_build_upload.py`-ban

## Előnyök vs Arduino IDE

| Szempont | Arduino IDE | arduino-cli |
|----------|-------------|-------------|
| Telepítés | ~500 MB | ~50 MB |
| Sebesség | Lassabb | Gyorsabb |
| Automatizálás | Nehéz | Könnyű |
| Fájl kontroll | Cache-ből dolgozik | Projekt mappából |
| Library kezelés | GUI | CLI |
| Debugolás | Serial Monitor | Külső tool kell |

## Integráció a Build Pipeline-ba

A `build.py` is használható lesz arduino-cli-vel (jövőbeli fejlesztés):

```bash
python Tools\build.py debug-arduino --upload COM3
```

Ez majd:
1. Lefordítja a C64 kódot
2. Generálja az Arduino header fájlokat
3. Lefordítja és feltölti az Arduino sketch-et
4. Egy parancs = teljes build+deploy

## Linkek

- Arduino CLI dokumentáció: https://arduino.github.io/arduino-cli/
- GitHub repo: https://github.com/arduino/arduino-cli
- FQBN referencia: https://arduino.github.io/arduino-cli/latest/platform-specification/

---

**Státusz**: ✅ MŰKÖDIK
**Utolsó teszt**: 2025-12-25
**Platform**: Windows 10/11
**Arduino Board**: Arduino Nano (ATmega328P Old Bootloader)
