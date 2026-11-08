@echo off
rem SPDX-License-Identifier: GPL-3.0-or-later
rem Copyright (C) 2026 Davidian
rem Builds build\twinline.lv2 (plugin + GUI) and the test programs with Visual Studio's x64 compiler.
rem Test programs go in build-test, so build\ holds only the bundle.
setlocal
set "ROOT=%~dp0"
set "VCVARS=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VCVARS%" (
    echo Could not find vcvars64.bat. Edit VCVARS in build.bat to match your Visual Studio install.
    exit /b 1
)
call "%VCVARS%" >nul || exit /b 1

set "BUNDLE=%ROOT%build\twinline.lv2"
set "TESTS=%ROOT%build-test"
if not exist "%BUNDLE%" mkdir "%BUNDLE%"
if not exist "%TESTS%" mkdir "%TESTS%"
pushd "%TESTS%" || exit /b 1

rem /MT links the C runtime statically, so hosts don't need a redistributable installed.
cl /nologo /O2 /MT /W3 /LD "%ROOT%src\twinline.c" /Fo"%TESTS%\\" /Fe"%BUNDLE%\twinline.dll" /link /NOLOGO /NOIMPLIB /NOEXP
if errorlevel 1 (popd & exit /b 1)

rem The GUI: a Win32 window drawn by its own software renderer, in the shared house style.
cl /nologo /std:c11 /O2 /MT /W4 /LD "%ROOT%src\ui\ui_lv2.c" /Fo"%TESTS%\\" /Fe"%BUNDLE%\twinline_ui.dll" /link /NOLOGO /NOIMPLIB /NOEXP user32.lib gdi32.lib
if errorlevel 1 (popd & exit /b 1)
del /q "%BUNDLE%\*.lib" "%BUNDLE%\*.exp" 2>nul

copy /y "%ROOT%bundle\*.ttl" "%BUNDLE%\" >nul || (popd & exit /b 1)

cl /nologo /O2 /W3 /D_CRT_SECURE_NO_WARNINGS "%ROOT%tests\test_host.c" /Fo"%TESTS%\\" /Fe"%TESTS%\test_host.exe" /link /NOLOGO
if errorlevel 1 (popd & exit /b 1)
cl /nologo /std:c11 /O2 /MT /W3 "%ROOT%tests\ui_render.c" /Fo"%TESTS%\\" /Fe"%TESTS%\ui_render.exe" /link /NOLOGO
if errorlevel 1 (popd & exit /b 1)
cl /nologo /std:c11 /O2 /MT /W3 "%ROOT%tests\ui_check.c" /Fo"%TESTS%\\" /Fe"%TESTS%\ui_check.exe" /link /NOLOGO user32.lib gdi32.lib
if errorlevel 1 (popd & exit /b 1)
cl /nologo /std:c11 /Od /MT "%ROOT%tests\lilv_check.c" /Fo"%TESTS%\\" /Fe"%TESTS%\lilv_check.exe" /link /NOLOGO
if errorlevel 1 (popd & exit /b 1)

popd
echo Built %BUNDLE%
