# Assets/ThemePacks

Theme packs live here, one folder per pack: `Assets/ThemePacks/<id>/` with a JSON manifest plus vector
assets and audio, loaded at runtime and switchable without a restart (design.md §7; R-DS-4). Placeholder
packs are flagged "needs production art" (R-DS-4.2, R-DS-6).

Populated by the theme-pack work in Phase 5 (tasks 5.2–5.4, 5.7).

## Themes (task 5.2)

Four procedural table themes ship, each a folder with a `theme.json` manifest whose `table.material`
maps to a Metal shader function in `Packages/DesignSystem/Sources/DesignSystem/Shaders/TableMaterials.metal`
(felt fiber/vignette, wood grain/sheen, matte). Materials are procedural — no large bitmaps (R-DS-2.1) —
and independent of the system light/dark appearance (R-DS-2.2). The canonical parameters live in
`TableTheme.all` in DesignSystem; these manifests mirror them for the runtime theme-pack loader (task 5.4).

- `classic-felt/` — Classic Felt (felt)
- `midnight/` — Midnight (felt)
- `walnut-parlor/` — Walnut Parlor (wood)
- `minimal/` — Minimal (matte)

## Placeholder status (audited in task 8.5)

All four packs are 🎨 **needs production art** (`"placeholder": true`; R-DS-4.2, R-DS-6):

- **Table materials** are procedural shaders, so no bitmap art is missing. They are flagged only because
  the look has not had a production art pass.
- **Deck faces and backs** are the procedural `CardFaceCanvas` drawings and the placeholder court-card
  medallions (`CourtCardArt`, `needsProductionArt == true`). No vector files ship in these folders.
- **Audio**: no clips ship and no manifest has an `audio` block, so the sound engine is silent.

These folders are not yet copied into the app bundle (`project.yml` has no resource entry for them). The
app renders the built-in `TableTheme.all` catalog that the manifests mirror. `ThemePackRegistry.loadingDirectory`
can load them, and its tests use them.
