---
id: hq-macos-tar-exclude-appledouble
title: Always exclude AppleDouble metadata files when tarring on macOS for S3 or cross-platform use
scope: global
trigger: when creating a tar archive on macOS that will be uploaded to S3 or consumed by a non-macOS system
enforcement: soft
public: true
version: 1
created: 2026-04-28
updated: 2026-04-28
source: session-learning
---

## Rule

ALWAYS: When tarring a directory on macOS for upload to S3 or any non-macOS consumer, exclude AppleDouble metadata files. Use one of:

```bash
# Preferred — env var disables generation at the source
COPYFILE_DISABLE=1 tar -czf out.tgz ./dir

# Alternative — exclude by glob pattern
tar -czf out.tgz --exclude='._*' ./dir

# Post-tar cleanup (if archive already created)
find ./dir -name '._*' -delete
```

Without this, macOS `tar` includes shadow files like `._index.html`, `._.gitignore`, `.__MACOSX/` that:
- S3 lists as real objects and charges for storage
- Downstream tooling (web servers, CloudFront, build pipelines) sees as garbage files
- Must be manually deleted after upload, risking partial cleanup

## Rationale

macOS `tar` uses Apple's `copyfile` extension to preserve extended attributes (Finder labels, quarantine flags, resource forks) by creating hidden `._filename` companion files. On non-macOS filesystems these have no meaning and pollute the target. Four `._*` files appeared at `s3://hq-deploy-{company}-assets/unicom/` from a tar push in the unicom deck deploy session and required manual S3 cleanup.

`COPYFILE_DISABLE=1` is the cleanest fix — it prevents creation rather than post-processing removal.
