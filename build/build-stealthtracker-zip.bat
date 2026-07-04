:: Assumes running from StealthTracker-CyberpunkRED\build
mkdir out\CyberpunkRED-StealthTracker
copy ..\extension.xml out\CyberpunkRED-StealthTracker\
copy ..\README.md out\CyberpunkRED-StealthTracker\
mkdir out\CyberpunkRED-StealthTracker\scripts
copy ..\scripts\stealthtracker.lua out\CyberpunkRED-StealthTracker\scripts\
mkdir out\CyberpunkRED-StealthTracker\graphics\icons
copy ..\graphics\icons\stealth_icon.png out\CyberpunkRED-StealthTracker\graphics\icons\
cd out
CALL ..\zip-items CyberpunkRED-StealthTracker
rmdir /S /Q CyberpunkRED-StealthTracker\
copy CyberpunkRED-StealthTracker.zip CyberpunkRED-StealthTracker.ext
del CyberpunkRED-StealthTracker.zip
cd ..
explorer .\out
