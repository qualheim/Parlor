PLACEHOLDER APP ICON — NEEDS PRODUCTION ART (R-DS-6.1)

These PNGs are a generated placeholder created by Assets/gen_placeholder_appicon.py
(task 1.5). They are intentionally plain (felt-green panel, a "placeholder" hazard
stripe, and a chip/token disc) and MUST be replaced with production artwork before any
release build.

Tracked in .kiro/specs/01-platform-foundation/tasks.md under the "Placeholder-art
register" and re-audited in task 8.5. Generated placeholders are acceptable for the app
icon at this stage per R-DS-6.1, provided they are flagged for replacement — which this
file does.

To regenerate:
    python3 Assets/gen_placeholder_appicon.py \
        App/Sources/Assets.xcassets/AppIcon.appiconset/icon_1024.png
    # then downscale with sips into the 16/32/128/256/512 @1x and @2x sizes.
