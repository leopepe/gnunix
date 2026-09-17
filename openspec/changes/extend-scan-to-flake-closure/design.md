# Design: extend-scan-to-flake-closure

Scope: non-architectural. Keep manifest path intact; add flake-derived names from direct profile paths (not recursive build-time inputs) to avoid ballooning. Unmapped flake packages skip with warning; manifest unmapped names still fail. Durable issue #151 remains the single report.
