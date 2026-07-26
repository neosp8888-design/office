# 이 스크립트는 3D V4 원본을 고정한 채 인물의 눈·입·손 패치와 네 테마를 생성한다.

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFilter


PROJECT_DIR = Path(__file__).resolve().parents[1]
ARTIFACTS_DIR = PROJECT_DIR / "artifacts"
RESOURCES_DIR = PROJECT_DIR / "Sources" / "OfficeCore" / "Resources"
SOURCE_DIR = ARTIFACTS_DIR / "motion-sources"
MOTION_DIR = RESOURCES_DIR / "office-3d-motion-v1"
BASE_PATH = ARTIFACTS_DIR / "office-3d-v4-layout-concept-v3.png"
MODERN_BASE_PATH = (
    ARTIFACTS_DIR / "office-3d-modern-v3-purple-right-woman.png"
)
MODERN_NIGHT_BASE_PATH = (
    ARTIFACTS_DIR / "office-3d-modern-night-v3-purple-right-woman.png"
)
THEME_PATHS = {
    "modernDay": RESOURCES_DIR / "office-theme-modern-day-v4.png",
    "modernNight": RESOURCES_DIR / "office-theme-modern-night-v4.png",
    "woodDay": RESOURCES_DIR / "office-theme-wood-day-v4.png",
    "woodNight": RESOURCES_DIR / "office-theme-wood-night-v4.png",
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


def night_grade(image: Image.Image, modern: bool) -> Image.Image:
    image = ImageEnhance.Color(image).enhance(0.68 if modern else 0.78)
    image = ImageEnhance.Brightness(image).enhance(0.64 if modern else 0.68)
    image = ImageEnhance.Contrast(image).enhance(1.08)
    tint = Image.new("RGB", image.size, (180, 205, 255))
    image = ImageChops.multiply(image, tint)
    image = add_radial_glow(
        image,
        center=(455, 325),
        radius=(180, 160),
        color=(255, 190, 95),
        opacity=30,
    )
    image = add_radial_glow(
        image,
        center=(770, 445),
        radius=(260, 90),
        color=(255, 177, 92),
        opacity=24,
    )
    return image


def apply_theme(image: Image.Image, theme: str) -> Image.Image:
    image = image.convert("RGB")
    if theme in ("woodDay", "modernDay"):
        return image
    if theme == "woodNight":
        return night_grade(image, modern=False)
    if theme == "modernNight":
        return image
    raise ValueError(f"지원하지 않는 테마입니다. {theme}")


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
        "woodDay": (0, 512),
        "woodNight": (768, 512),
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
    wood_base = Image.open(BASE_PATH).convert("RGB")
    modern_base = Image.open(MODERN_BASE_PATH).convert("RGB")
    modern_night_base = Image.open(MODERN_NIGHT_BASE_PATH).convert("RGB")
    for name, image in {
        "우드": wood_base,
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
        if image.size != wood_base.size:
            raise ValueError(f"{key} 원형 크기가 올바르지 않습니다. {image.size}")

    theme_bases = {
        "modernDay": modern_base,
        "modernNight": modern_night_base,
        "woodDay": wood_base,
        "woodNight": wood_base,
    }
    themes = {
        theme: apply_theme(theme_bases[theme], theme)
        for theme in THEME_PATHS
    }
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
            else:
                source_key = spec["source"]
            localized = localized_variant(
                theme_bases[theme],
                generated_sources[source_key],
                spec,
            )
            themed_variant = apply_theme(localized, theme)
            patch = themed_variant.crop(spec["crop"])
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
        themes["woodDay"],
        "woodDay",
        "office-3d-motion-v1-contact-sheet.png",
    )
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

    print(f"테마 4장 생성. {RESOURCES_DIR}")
    print(f"동작 패치 {len(SPECS) * len(THEME_PATHS)}장 생성. {MOTION_DIR}")


if __name__ == "__main__":
    main()
