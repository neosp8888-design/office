# 이 스크립트는 2D 오피스 원본을 고정한 채 눈·입·손의 국소 동작 패치를 생성한다.

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


PROJECT_DIR = Path(__file__).resolve().parents[1]
ARTIFACTS_DIR = PROJECT_DIR / "artifacts"
RESOURCES_DIR = PROJECT_DIR / "Sources" / "OfficeCore" / "Resources"
SOURCE_DIR = ARTIFACTS_DIR / "motion-sources-2d"
THEME_DIR = RESOURCES_DIR / "office-2d-themes-v1"
MOTION_DIR = RESOURCES_DIR / "office-2d-motion-v1"

BASE_PATHS = {
    "modernDay": THEME_DIR / "modernDay.png",
    "modernNight": THEME_DIR / "modernNight.png",
}
DAY_SOURCE_PATHS = {
    "blink": SOURCE_DIR / "all-blink-source.png",
    "mouth": SOURCE_DIR / "all-mouth-source.png",
    "typing": SOURCE_DIR / "all-typing-source.png",
}
NIGHT_SOURCE_PATHS = {
    "blink": SOURCE_DIR / "night-blink-source.png",
    "mouth": SOURCE_DIR / "night-mouth-source.png",
    "typing": SOURCE_DIR / "night-typing-source.png",
}

SPECS = [
    {
        "character": "boss",
        "kind": "blink",
        "crop": (756, 174, 810, 210),
        "ellipses": [(762, 180, 782, 205), (784, 179, 804, 204)],
        "feather": 1.0,
    },
    {
        "character": "boss",
        "kind": "mouth",
        "crop": (769, 199, 798, 223),
        "ellipses": [(772, 202, 796, 221)],
        "feather": 1.0,
    },
    {
        "character": "boss",
        "kind": "typing",
        "crop": (744, 271, 792, 319),
        "ellipses": [(748, 276, 784, 311)],
        "feather": 1.25,
        "strength": 0.48,
    },
    {
        "character": "left-man",
        "kind": "blink",
        "crop": (291, 549, 344, 589),
        "ellipses": [(297, 557, 319, 584), (321, 554, 340, 582)],
        "feather": 1.0,
    },
    {
        "character": "left-man",
        "kind": "mouth",
        "crop": (306, 579, 336, 604),
        "ellipses": [(309, 582, 334, 602)],
        "feather": 1.0,
    },
    {
        "character": "left-man",
        "kind": "typing",
        "crop": (283, 626, 383, 725),
        "ellipses": [(289, 679, 331, 717), (351, 636, 380, 672)],
        "feather": 1.25,
        "strength": 0.42,
    },
    {
        "character": "left-woman",
        "kind": "blink",
        "crop": (451, 484, 510, 524),
        "ellipses": [(457, 491, 479, 519), (482, 489, 506, 518)],
        "feather": 1.0,
    },
    {
        "character": "left-woman",
        "kind": "mouth",
        "crop": (467, 518, 499, 544),
        "ellipses": [(470, 521, 497, 542)],
        "feather": 1.0,
    },
    {
        "character": "left-woman",
        "kind": "typing",
        "crop": (446, 579, 503, 632),
        "ellipses": [(451, 585, 500, 628)],
        "feather": 1.25,
        "strength": 0.48,
    },
    {
        "character": "right-woman",
        "kind": "blink",
        "crop": (1117, 489, 1178, 530),
        "ellipses": [(1123, 496, 1146, 524), (1149, 494, 1173, 523)],
        "feather": 1.0,
    },
    {
        "character": "right-woman",
        "kind": "mouth",
        "crop": (1134, 522, 1166, 547),
        "ellipses": [(1137, 525, 1164, 545)],
        "feather": 1.0,
    },
    {
        "character": "right-woman",
        "kind": "typing",
        "crop": (1112, 606, 1173, 652),
        "ellipses": [(1118, 612, 1169, 648)],
        "feather": 1.25,
        "strength": 0.44,
    },
    {
        "character": "right-man",
        "kind": "blink",
        "crop": (1270, 569, 1330, 611),
        "ellipses": [(1276, 577, 1299, 605), (1302, 574, 1326, 603)],
        "feather": 1.0,
    },
    {
        "character": "right-man",
        "kind": "mouth",
        "crop": (1287, 606, 1320, 633),
        "ellipses": [(1290, 609, 1318, 631)],
        "feather": 1.0,
    },
    {
        "character": "right-man",
        "kind": "typing",
        "crop": (1255, 695, 1321, 752),
        "ellipses": [(1260, 701, 1317, 748)],
        "feather": 1.25,
        "strength": 0.48,
    },
]


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


def patch_with_stable_edges(
    base: Image.Image,
    variant: Image.Image,
    crop: tuple[int, int, int, int],
) -> Image.Image:
    patch = variant.crop(crop)
    base_patch = base.crop(crop)
    width, height = patch.size
    edge_mask = Image.new("L", patch.size, 0)
    ImageDraw.Draw(edge_mask).rectangle(
        (2, 2, width - 3, height - 3),
        fill=255,
    )
    return Image.composite(patch, base_patch, edge_mask)


def build_contact_sheet(
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
    sheet = Image.new("RGB", (1_536, 1_024), (240, 240, 240))
    positions = {
        "base": (0, 0),
        "blink": (768, 0),
        "mouth": (0, 512),
        "typing": (768, 512),
    }
    for key, position in positions.items():
        preview = frames[key].resize(preview_size, Image.Resampling.LANCZOS)
        sheet.paste(preview, position)
    sheet.save(ARTIFACTS_DIR / output_name)


def main() -> None:
    day_base = Image.open(BASE_PATHS["modernDay"]).convert("RGB")
    night_base = Image.open(BASE_PATHS["modernNight"]).convert("RGB")
    day_sources = {
        kind: Image.open(path).convert("RGB")
        for kind, path in DAY_SOURCE_PATHS.items()
    }
    night_sources = {
        kind: Image.open(path).convert("RGB")
        for kind, path in NIGHT_SOURCE_PATHS.items()
    }

    expected_size = (1_536, 1_024)
    for name, image in {
        "modernDay": day_base,
        "modernNight": night_base,
        **{f"day-{kind}": image for kind, image in day_sources.items()},
        **{f"night-{kind}": image for kind, image in night_sources.items()},
    }.items():
        if image.size != expected_size:
            raise ValueError(f"{name} 크기가 올바르지 않습니다. {image.size}")

    if MOTION_DIR.exists():
        for path in MOTION_DIR.rglob("*.png"):
            path.unlink()

    manifest = []
    for spec in SPECS:
        x0, y0, x1, y1 = spec["crop"]
        day_variant = localized_variant(
            day_base,
            day_sources[spec["kind"]],
            spec,
        )
        night_variant = localized_variant(
            night_base,
            night_sources[spec["kind"]],
            spec,
        )

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

        for theme, base, variant in (
            ("modernDay", day_base, day_variant),
            ("modernNight", night_base, night_variant),
        ):
            output_dir = MOTION_DIR / theme
            output_dir.mkdir(parents=True, exist_ok=True)
            patch_with_stable_edges(
                base,
                variant,
                spec["crop"],
            ).save(
                output_dir
                / f"{spec['character']}-{spec['kind']}.png"
            )

    (ARTIFACTS_DIR / "office-2d-motion-v1-boxes.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    build_contact_sheet(
        day_base,
        "modernDay",
        "office-2d-modern-day-motion-v1-contact-sheet.png",
    )
    build_contact_sheet(
        night_base,
        "modernNight",
        "office-2d-modern-night-motion-v1-contact-sheet.png",
    )

    print(f"2D 동작 패치 {len(SPECS) * 2}장 생성. {MOTION_DIR}")


if __name__ == "__main__":
    main()
