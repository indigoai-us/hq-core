# HQ Migration Guide

Newest release first. `## Release: TBD` collects promotions staged for the next
release; the release workflow stamps it with the version at tag time.

## Release: v15.0.88

- promote 2026-08-10 (**/deploy comments opt-in**): `/deploy` gains `--comments on|off`
  documenting turning the per-app comment widget on/off (`commentsEnabled`). The flag is
  orthogonal to the access mode and off by default — without it the deploy is byte-identical
  to a pre-feature deploy. A new Phase C step (`C.2.6`) PATCHes the per-app `commentsEnabled`
  flag after upload so the deploy pipeline injects the comment widget on the next deploy; a
  gated deploy's comment thread enforces the same access gate as the deploy itself.
