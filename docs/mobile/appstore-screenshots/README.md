# App Store screenshots

The 6.9" set (**1320 × 2868**, the required iPhone 17 Pro Max resolution), shot
from the built-in **demo fleet** so what the store shows is exactly what a
reviewer sees on launch with no Mac to pair.

| file | screen |
|---|---|
| `01-pairing.png` | the pairing screen, with the `explore the demo fleet` entry visible without scrolling |
| `02-board.png`   | the board — attention-sorted, NEEDS ANSWER / BLOCKED / ENDED, the demo banner |
| `03-worktree.png`| a worktree's detail |
| `04-limits.png`  | per-account headroom, MOST HEADROOM, an EXHAUSTED account with its reserve note |
| `05-map.png`     | the branch map |

Regenerate (a fresh simulator so no stale keychain shows a paired board):

```sh
xcrun simctl erase "iPhone 17 Pro Max"
xcrun simctl boot "iPhone 17 Pro Max"
xcodebuild -project ios/Orchestra.xcodeproj -scheme Orchestra -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/orc-dd build
xcrun simctl install booted /tmp/orc-dd/Build/Products/Debug-iphonesimulator/Orchestra.app
# pairing (no seam), then each demo screen:
xcrun simctl launch booted sh.orchestra.app                                  # 01
for s in demo demo:wt:payments-webhook demo:limits demo:map; do
  xcrun simctl terminate booted sh.orchestra.app
  SIMCTL_CHILD_ORC_SCREEN=$s xcrun simctl launch booted sh.orchestra.app
  sleep 3; xcrun simctl io booted screenshot shot-$s.png
done
```

App Store Connect accepts the 6.9" set as the only iPhone set required; the
6.5"/6.1" classes are optional and Apple down-scales these.
