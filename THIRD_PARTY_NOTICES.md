# Third-Party Notices

Parlor is built to be fully offline and self-contained. It ships **no third-party code
dependencies** — the entire app is first-party Swift across the local packages
(`EngineCore`, `AIKit`, `Games`, `TableKit`, `DesignSystem`, `Persistence`,
`SimulationCLI`) plus Apple's system frameworks (Swift standard library, Foundation,
SwiftUI, AppKit, SpriteKit, AVFoundation, Metal, Swift Charts, os).

This file records the provenance of bundled **assets** — audio in particular — as required
by the sound-engine requirements (R-DS-5.2) and `tech.md`.

## Audio

All audio played by the sound engine (DesignSystem, task 5.7) is **original, CC0, or
procedurally synthesized**. No audio is licensed from, derived from, or copied out of any
third party (R-DS-5.2).

The sound engine drives six event cues — **shuffle, deal, flip, place, chips, win** — each
backed by several interchangeable variations so the same sound never plays twice in a row
(R-DS-5.1). The variation clips for a given theme are supplied by that theme pack's manifest
(`Assets/ThemePacks/<id>/theme.json`, `audio` block).

### Provenance

| Asset set | Source | License |
| --- | --- | --- |
| Table sound cues (shuffle / deal / flip / place / chips / win) and any ambience bed | Original / procedurally synthesized by the Parlor project | CC0 1.0 (public domain dedication) |

### Placeholder status

🎨 **Needs production art.** No audio clips are bundled yet. The four theme-pack manifests
carry no `audio` block and are flagged `"placeholder": true`, so the sound engine has nothing
to play (see the placeholder-art register in
`.kiro/specs/01-platform-foundation/tasks.md`, tasks 5.4 and 5.7). Because theme packs map
audio by file name, clips can be added later with **no code change** — only the pack's
`audio` block is filled in and its `placeholder` flag flips to `false` (R-DS-4.2, R-DS-6).
This provenance record stays valid: any audio added must be original, CC0, or synthesized.

## System frameworks

Apple system frameworks are used under the terms of the Apple SDK and macOS licenses and are
not redistributed by this project.
