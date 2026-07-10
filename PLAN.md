# Plan

- [x] Prove the current devShell-only flake violates the Mechatron Prime CI contract. (2026-07-10 12:14 EDT)
  Curiosity poke: evaluation success must not be mistaken for a real build or test.
- [x] Expose Capy as a reproducible Zig 0.16 package and complete test check. (2026-07-10 13:03 EDT)
  Curiosity poke: GTK tests may require a headless display or an intentionally pure test backend.
- [x] Make `./build` and `./test` the canonical local and CI entry points. (2026-07-10 13:03 EDT)
  Curiosity poke: recursive script-to-flake calls must be impossible.
- [x] Validate every entry point and commit one green, reviewable migration. (2026-07-10 13:14 EDT)
  Curiosity poke: project-local dependency staging must not dirty the worktree.
- [x] Preserve `AssetHandle.readAllAlloc`'s exact limit and overflow contract. (2026-07-10 13:32 EDT)
  Curiosity poke: overflow detection must not read past the stream unless the buffer is exactly full.
