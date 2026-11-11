@echo off
rem SPDX-License-Identifier: GPL-3.0-or-later
rem Copyright (C) 2026 Davidian
rem Builds build\lv2\twinline.lv2 (plugin + GUI) and build\vst3\twinline.vst3 with Visual Studio's
rem x64 C compiler.
rem   build.bat         build both bundles
rem   build.bat test    also build and run the tests in build-test\
rem   build.bat dist    also zip the bundles with the docs into build\dist\ (set VERSION first)
rem Sets up the Visual Studio environment if cl.exe is not on PATH.
rem Linux, macOS and MinGW: use the Makefile instead.
setlocal
cd /d "%~dp0"

where cl >nul 2>nul
if not errorlevel 1 goto :have_cl
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
    echo Could not find Visual Studio. Install it with the C++ tools, or run from a Developer Command Prompt.
    exit /b 1
)
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDIR=%%i"
if not defined VSDIR (
    echo Could not find Visual Studio's C++ tools.
    exit /b 1
)
call "%VSDIR%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
:have_cl

rem One folder per format, so LV2 tools scanning build\lv2 see only the LV2 bundle.
set "BUNDLE=%~dp0build\lv2\twinline.lv2"
set "VST3=%~dp0build\vst3\twinline.vst3"
set "TESTS=%~dp0build-test"
if not exist "%BUNDLE%" mkdir "%BUNDLE%"
if not exist "%TESTS%" mkdir "%TESTS%"
if not exist "%VST3%\Contents\x86_64-win" mkdir "%VST3%\Contents\x86_64-win"
if not exist "%VST3%\Contents\Resources" mkdir "%VST3%\Contents\Resources"

rem /MT links the C runtime statically, so hosts don't need a redistributable installed.
cl /nologo /O2 /MT /W3 /LD src\twinline.c /Fo"%TESTS%\\" /Fe"%BUNDLE%\twinline.dll" /link /NOLOGO /NOIMPLIB /NOEXP || exit /b 1

rem The GUI: a Win32 window drawn by its own software renderer, in the shared house style.
cl /nologo /std:c11 /O2 /MT /W4 /LD src\ui\ui_lv2.c /Fo"%TESTS%\\" /Fe"%BUNDLE%\twinline_ui.dll" /link /NOLOGO /NOIMPLIB /NOEXP user32.lib gdi32.lib || exit /b 1
del /q "%BUNDLE%\*.lib" "%BUNDLE%\*.exp" 2>nul

copy /y bundle\twinline.ttl "%BUNDLE%\" >nul || exit /b 1
powershell -NoProfile -Command "(Get-Content bundle\manifest.ttl.in) -replace '@LIB_EXT@','.dll' -replace '@UI_CLASS@','ui:WindowsUI' | Set-Content -Encoding ascii '%BUNDLE%\manifest.ttl'" || exit /b 1

rem The VST3: one DLL with the engine, the parameters and the same GUI, in a VST3 bundle folder.
cl /nologo /std:c11 /O2 /MT /W4 /LD src\vst3\vst3.c /Fo"%TESTS%\\" /Fe"%VST3%\Contents\x86_64-win\twinline.vst3" /link /NOLOGO /NOIMPLIB /NOEXP user32.lib gdi32.lib || exit /b 1
del /q "%VST3%\Contents\x86_64-win\*.lib" "%VST3%\Contents\x86_64-win\*.exp" 2>nul
copy /y LICENSE "%VST3%\Contents\Resources\" >nul || exit /b 1
copy /y src\vst3\LICENSE.txt "%VST3%\Contents\Resources\LICENSE-VST3.txt" >nul || exit /b 1

if "%1"=="test" goto :test
if "%1"=="dist" goto :dist
goto :done

:test
cl /nologo /O2 /W3 /MT /D_CRT_SECURE_NO_WARNINGS tests\test_host.c /Fo"%TESTS%\\" /Fe"%TESTS%\test_host.exe" /link /NOLOGO || exit /b 1
cl /nologo /std:c11 /O2 /MT /W3 tests\ui_render.c /Fo"%TESTS%\\" /Fe"%TESTS%\ui_render.exe" /link /NOLOGO || exit /b 1
cl /nologo /std:c11 /O2 /MT /W3 tests\ui_check.c /Fo"%TESTS%\\" /Fe"%TESTS%\ui_check.exe" /link /NOLOGO user32.lib gdi32.lib || exit /b 1
cl /nologo /std:c11 /O2 /MT /W3 tests\vst3_check.c /Fo"%TESTS%\\" /Fe"%TESTS%\vst3_check.exe" /link /NOLOGO user32.lib gdi32.lib || exit /b 1
cl /nologo /std:c11 /Od /MT tests\lilv_check.c /Fo"%TESTS%\\" /Fe"%TESTS%\lilv_check.exe" /link /NOLOGO || exit /b 1
"%TESTS%\test_host.exe" "%BUNDLE%\twinline.dll" || exit /b 1
"%TESTS%\ui_render.exe" "%TESTS%\panel.bmp" || exit /b 1
"%TESTS%\ui_check.exe" "%BUNDLE%" "%TESTS%\ui_window.bmp" || exit /b 1
"%TESTS%\vst3_check.exe" "%VST3%" "%TESTS%\vst3_window.bmp" || exit /b 1
rem The lilv check borrows lilv from Ardour 9, so it only runs where Ardour is installed.
if exist "C:\Program Files\Ardour9\bin\lilv-0.dll" (
    "%TESTS%\lilv_check.exe" "%~dp0build\lv2" || exit /b 1
) else (
    echo Skipping lilv_check: Ardour 9 not found in C:\Program Files\Ardour9
)
goto :done

:dist
if "%VERSION%"=="" set "VERSION=dev"
set "DISTNAME=davidian-twinline-%VERSION%-windows-x64"
set "DISTDIR=%~dp0build\dist"
if exist "%DISTDIR%\%DISTNAME%" rmdir /s /q "%DISTDIR%\%DISTNAME%"
if exist "%DISTDIR%\%DISTNAME%.zip" del /q "%DISTDIR%\%DISTNAME%.zip"
mkdir "%DISTDIR%\%DISTNAME%" || exit /b 1
xcopy /e /i /q "%BUNDLE%" "%DISTDIR%\%DISTNAME%\twinline.lv2" >nul || exit /b 1
xcopy /e /i /q "%VST3%" "%DISTDIR%\%DISTNAME%\twinline.vst3" >nul || exit /b 1
copy /y README.md "%DISTDIR%\%DISTNAME%\" >nul
copy /y LICENSE "%DISTDIR%\%DISTNAME%\" >nul
copy /y LICENSE-LV2 "%DISTDIR%\%DISTNAME%\" >nul
copy /y src\vst3\LICENSE.txt "%DISTDIR%\%DISTNAME%\LICENSE-VST3.txt" >nul
powershell -NoProfile -Command "Compress-Archive -Force -Path '%DISTDIR%\%DISTNAME%' -DestinationPath '%DISTDIR%\%DISTNAME%.zip'" || exit /b 1
echo Packaged %DISTDIR%\%DISTNAME%.zip

:done
echo Built %BUNDLE% and %VST3%
