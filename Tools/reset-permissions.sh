#!/bin/zsh
for svc in Accessibility ScreenCapture ListenEvent; do tccutil reset $svc cz.voidmac.app; done
echo "Oprávnění vymazána, po dalším spuštění se macOS zeptá znovu."
