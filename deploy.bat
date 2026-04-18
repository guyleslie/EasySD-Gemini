@echo off
REM Full release deploy: build + ISP upload + SD card update
REM Usage: deploy.bat

echo ==============================
echo  EasySD Release Deploy
echo ==============================
echo.

echo [1/3] Release build...
python Tools/build.py release
if errorlevel 1 (
    echo FAILED: Release build
    pause
    exit /b 1
)

echo.
echo [2/3] ISP upload...
python Tools/build.py arduino-upload-isp
if errorlevel 1 (
    echo FAILED: ISP upload
    pause
    exit /b 1
)

echo.
echo [3/3] SD card deploy (D:)...
python Tools/build.py sd-deploy D:
if errorlevel 1 (
    echo FAILED: SD deploy
    pause
    exit /b 1
)

echo.
echo ==============================
echo  Deploy complete!
echo ==============================
pause
