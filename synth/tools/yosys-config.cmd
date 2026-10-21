@echo off
if "%~1"=="--linkflags" goto translated
if "%~1"=="--ldlibs" goto translated
"C:\msys64\usr\bin\bash.exe" -lc "export PATH=/ucrt64/bin:$PATH; /ucrt64/bin/yosys-config %*"
goto end
:translated
"C:\msys64\usr\bin\bash.exe" -lc "export PATH=/ucrt64/bin:$PATH; /ucrt64/bin/yosys-config %* | sed 's|-LD:/M/msys64/ucrt64/lib/../lib|-LC:/msys64/ucrt64/lib|g; s|-L/ucrt64|-LC:/msys64/ucrt64|g; s| /ucrt64| C:/msys64/ucrt64|g; s|/16.1.0/adalib|/16.2.0/adalib|g'"
:end
