# 4K PNG export performance

**Goal:** Avoid repeated Photoshop extraction and expensive intermediate compression without changing final pixels, alpha or ICC.

**Architecture:** Keep existing saved-PSD checks. Cache validated role images on disk by snapshot and task identity, with file hashes. Use low-compression lossless PNG for fresh intermediate exports only; retain final 4K rendering and publishing.

**Scope:** `PhotoshopWorkflowBridge.swift` and bridge regression tests. Existing uncommitted changes belong to earlier requests and remain intact.

## Checks and implementation

- [x] Reproduce duplicate extraction with the real bridge and a fake external Photoshop runner.
- [x] Cover reuse across bridge recreation, corrupted/missing cache files, changed PSDs, and unsaved document rejection.
- [x] Add validated persistent role cache; keep source ownership and saved-content checks on reuse.
- [x] Reuse existing verified immutable PSD snapshots instead of copying them again.
- [x] Compare native low-compression PNG saving against Save for Web on disposable PSD copies; compare RGBA and ICC, including final 4K output.
- [x] Run the full application suite and an opt-in real-PSD verification; measure cold and repeated extraction separately.
- [x] Build and launch Release after verifying the user's current batch is idle.

## Constraints

No new dependency, no image resizing or alpha cleanup, no changes to user PSDs or published exports. Cache failure falls back to extraction. Old batches remain readable; legacy cached images without integrity records require one fresh extraction. Do not report a whole-export speedup based only on an isolated calculation.
