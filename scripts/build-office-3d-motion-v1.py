# 이 스크립트는 3D V4 원본을 고정한 채 인물의 눈·입·손 패치와 두 모던 테마를 생성한다.

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


PROJECT_DIR = Path(__file__).resolve().parents[1]
ARTIFACTS_DIR = PROJECT_DIR / "artifacts"
RESOURCES_DIR = PROJECT_DIR / "Sources" / "OfficeCore" / "Resources"
SOURCE_DIR = ARTIFACTS_DIR / "motion-sources"
MOTION_DIR = RESOURCES_DIR / "office-3d-motion-v1"
MODERN_BASE_PATH = (
    ARTIFACTS_DIR / "office-3d-modern-v3-purple-right-woman.png"
)
MODERN_NIGHT_BASE_PATH = (
    ARTIFACTS_DIR / "office-3d-modern-night-v3-purple-right-woman.png"
)
THEME_PATHS = {
    "modernDay": RESOURCES_DIR / "office-theme-modern-day-v4.png",
    "modernNight": RESOURCES_DIR / "office-theme-modern-night-v4.png",
}
SOURCE_PATHS = {
    "boss-blink": SOURCE_DIR / "boss-blink-source.png",
    "workers-blink": SOURCE_DIR / "workers-blink-source.png",
    "mouth": SOURCE_DIR / "all-mouth-source.png",
    "typing": SOURCE_DIR / "all-typing-source.png",
    "modern-blink": SOURCE_DIR / "modern-blink-source.png",
    "modern-right-woman-blink": (
        SOURCE_DIR / "modern-right-woman-blink-purple-source.png"
    ),
    "modern-mouth": SOURCE_DIR / "modern-mouth-purple-source.png",
    "modern-typing": SOURCE_DIR / "modern-typing-purple-source.png",
    "modern-night-blink": SOURCE_DIR / "modern-night-blink-source.png",
    "modern-night-right-woman-blink": (
        SOURCE_DIR / "modern-night-right-woman-blink-purple-source.png"
    ),
    "modern-night-mouth": SOURCE_DIR / "modern-night-mouth-purple-source.png",
    "modern-night-typing": SOURCE_DIR / "modern-night-typing-purple-source.png",
}


SPECS = [
    {
        "character": "boss",
        "kind": "blink",
        "source": "boss-blink",
        "crop": (744, 202, 806, 239),
        "ellipses": [(750, 209, 775, 234), (776, 208, 801, 233)],
        "feather": 1.25,
    },
    {
        "character": "boss",
        "kind": "mouth",
        "source": "mouth",
        "crop": (754, 229, 793, 256),
        "ellipses": [(758, 231, 789, 254)],
        "feather": 1.0,
    },
    {
        "character": "boss",
        "kind": "typing",
        "source": "typing",
        "crop": (738, 269, 786, 311),
        "ellipses": [(744, 274, 780, 307)],
        "feather": 1.5,
    },
    {
        "character": "left-man",
        "kind": "blink",
        "source": "workers-blink",
        "crop": (323, 524, 381, 566),
        "ellipses": [(330, 532, 352, 559), (352, 528, 377, 556)],
        "feather": 1.0,
    },
    {
        "character": "left-man",
        "kind": "mouth",
        "source": "mouth",
        "crop": (338, 558, 370, 582),
        "ellipses": [(341, 560, 367, 580)],
        "feather": 1.0,
    },
    {
        "character": "left-man",
        "kind": "typing",
        "source": "typing",
        "crop": (316, 579, 410, 655),
        "ellipses": [(327, 610, 370, 641)],
        "feather": 1.0,
        "strength": 0.42,
    },
    {
        "character": "left-woman",
        "kind": "blink",
        "source": "workers-blink",
        "crop": (480, 478, 531, 514),
        "ellipses": [(484, 483, 504, 509), (507, 481, 528, 508)],
        "feather": 1.0,
    },
    {
        "character": "left-woman",
        "kind": "mouth",
        "source": "mouth",
        "crop": (487, 507, 525, 533),
        "ellipses": [(490, 509, 522, 531)],
        "feather": 1.0,
    },
    {
        "character": "left-woman",
        "kind": "typing",
        "source": "typing",
        "crop": (468, 538, 527, 585),
        "ellipses": [(475, 545, 521, 582)],
        "feather": 1.5,
    },
    {
        "character": "right-woman",
        "kind": "blink",
        "source": "workers-blink",
        "crop": (1085, 481, 1143, 520),
        "ellipses": [(1090, 488, 1112, 515), (1116, 486, 1138, 514)],
        "feather": 1.0,
    },
    {
        "character": "right-woman",
        "kind": "mouth",
        "source": "mouth",
        "crop": (1097, 510, 1134, 538),
        "ellipses": [(1100, 513, 1131, 536)],
        "feather": 1.0,
    },
    {
        "character": "right-woman",
        "kind": "typing",
        "source": "typing",
        "crop": (1084, 558, 1146, 608),
        "ellipses": [(1093, 566, 1136, 596)],
        "feather": 1.0,
        "strength": 0.48,
    },
    {
        "character": "right-man",
        "kind": "blink",
        "source": "workers-blink",
        "crop": (1205, 557, 1269, 600),
        "ellipses": [(1211, 565, 1235, 595), (1239, 563, 1264, 593)],
        "feather": 1.0,
    },
    {
        "character": "right-man",
        "kind": "mouth",
        "source": "mouth",
        "crop": (1218, 588, 1259, 618),
        "ellipses": [(1222, 592, 1256, 616)],
        "feather": 1.0,
    },
    {
        "character": "right-man",
        "kind": "typing",
        "source": "typing",
        "crop": (1205, 626, 1280, 681),
        "ellipses": [(1213, 634, 1275, 678)],
        "feather": 1.5,
    },
]


def add_radial_glow(
    image: Image.Image,
    center: tuple[int, int],
    radius: tuple[int, int],
    color: tuple[int, int, int],
    opacity: int,
) -> Image.Image:
    glow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(glow)
    x, y = center
    rx, ry = radius
    draw.ellipse(
        (x - rx, y - ry, x + rx, y + ry),
        fill=(*color, opacity),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(max(rx, ry) / 2.8))
    return Image.alpha_composite(image.convert("RGBA"), glow).convert("RGB")


def localized_variant(
    base: Image.Image,
    generated: Image.Image,
    spec: dict,
) -> Image.Image:
    mask = Image.new("L", base.size, 0)
    draw = ImageDraw.Draw(mask)
    for ellipse in spec["ellipses"]:
        draw.ellipse(ellipse, fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(spec["feather"]))
    strength = spec.get("strength", 1.0)
    if strength < 1:
        mask = mask.point(lambda value: round(value * strength))
    return Image.composite(generated, base, mask)


def build_contact_sheet(themes: dict[str, Image.Image]) -> None:
    preview_size = (768, 512)
    sheet = Image.new("RGB", (1_536, 1_024), (245, 242, 238))
    positions = {
        "modernDay": (0, 0),
        "modernNight": (768, 0),
    }
    for theme, position in positions.items():
        preview = themes[theme].resize(preview_size, Image.Resampling.LANCZOS)
        sheet.paste(preview, position)
    sheet.save(ARTIFACTS_DIR / "office-3d-themes-v1-contact-sheet.png")


def build_motion_contact_sheet(
    base: Image.Image,
    theme: str,
    output_name: str,
) -> None:
    frames = {"base": base.copy()}
    for kind in ("blink", "mouth", "typing"):
        frame = base.copy()
        for spec in SPECS:
            if spec["kind"] != kind:
                continue
            patch = Image.open(
                MOTION_DIR
                / theme
                / f"{spec['character']}-{kind}.png"
            ).convert("RGB")
            x0, y0, _, _ = spec["crop"]
            frame.paste(patch, (x0, y0))
        frames[kind] = frame

    preview_size = (768, 512)
    sheet = Image.new("RGB", (1_536, 1_024), (245, 242, 238))
    for key, position in {
        "base": (0, 0),
        "blink": (768, 0),
        "mouth": (0, 512),
        "typing": (768, 512),
    }.items():
        preview = frames[key].resize(preview_size, Image.Resampling.LANCZOS)
        sheet.paste(preview, position)
    sheet.save(ARTIFACTS_DIR / output_name)


def main() -> None:
    modern_base = Image.open(MODERN_BASE_PATH).convert("RGB")
    modern_night_base = Image.open(MODERN_NIGHT_BASE_PATH).convert("RGB")
    for name, image in {
        "모던": modern_base,
        "모던 야간": modern_night_base,
    }.items():
        if image.size != (1_536, 1_024):
            raise ValueError(
                f"{name} V4 원본 크기가 올바르지 않습니다. {image.size}"
            )

    generated_sources = {
        key: Image.open(path).convert("RGB")
        for key, path in SOURCE_PATHS.items()
    }
    for key, image in generated_sources.items():
        if image.size != modern_base.size:
            raise ValueError(f"{key} 원형 크기가 올바르지 않습니다. {image.size}")

    theme_bases = {
        "modernDay": modern_base,
        "modernNight": modern_night_base,
    }
    themes = {theme: theme_bases[theme] for theme in THEME_PATHS}
    for theme, path in THEME_PATHS.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        themes[theme].save(path)

    if MOTION_DIR.exists():
        for path in MOTION_DIR.rglob("*.png"):
            path.unlink()

    manifest = []
    for spec in SPECS:
        x0, y0, x1, y1 = spec["crop"]
        manifest.append(
            {
                "character": spec["character"],
                "kind": spec["kind"],
                "x": x0,
                "y": y0,
                "width": x1 - x0,
                "height": y1 - y0,
            }
        )

        for theme in THEME_PATHS:
            if (
                theme == "modernNight"
                and spec["character"] == "right-woman"
                and spec["kind"] == "blink"
            ):
                source_key = "modern-night-right-woman-blink"
            elif (
                theme == "modernDay"
                and spec["character"] == "right-woman"
                and spec["kind"] == "blink"
            ):
                source_key = "modern-right-woman-blink"
            elif theme == "modernNight":
                source_key = f"modern-night-{spec['kind']}"
            elif theme == "modernDay":
                source_key = f"modern-{spec['kind']}"
            localized = localized_variant(
                theme_bases[theme],
                generated_sources[source_key],
                spec,
            )
            patch = localized.crop(spec["crop"])
            output_dir = MOTION_DIR / theme
            output_dir.mkdir(parents=True, exist_ok=True)
            patch.save(
                output_dir
                / f"{spec['character']}-{spec['kind']}.png"
            )

    (ARTIFACTS_DIR / "office-3d-motion-v1-boxes.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    build_contact_sheet(themes)
    build_motion_contact_sheet(
        themes["modernDay"],
        "modernDay",
        "office-3d-modern-motion-v1-contact-sheet.png",
    )
    build_motion_contact_sheet(
        themes["modernNight"],
        "modernNight",
        "office-3d-modern-night-motion-v1-contact-sheet.png",
    )

    print(f"테마 2장 생성. {RESOURCES_DIR}")
    print(f"동작 패치 {len(SPECS) * len(THEME_PATHS)}장 생성. {MOTION_DIR}")


if __name__ == "__main__":
    main()
