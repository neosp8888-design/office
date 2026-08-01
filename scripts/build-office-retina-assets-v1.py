# 이 스크립트는 2D·3D 오피스와 동작 패치를 좌표 고정 2배 Retina 자산으로 만든다.

from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter


PROJECT_DIR = Path(__file__).resolve().parents[1]
ARTIFACTS_DIR = PROJECT_DIR / "artifacts"
RESOURCES_DIR = PROJECT_DIR / "Sources" / "OfficeCore" / "Resources"
OUTPUT_DIR = RESOURCES_DIR / "office-retina-v1"
SCALE = 2
CANVAS_SIZE = (1_536, 1_024)
RETINA_SIZE = (3_072, 2_048)
STABLE_EDGE_WIDTH = 4

STYLE_SETTINGS = {
    "2d": {
        "radius": 1.2,
        "percent": 120,
        "threshold": 2,
    },
    "3d": {
        "radius": 1.3,
        "percent": 115,
        "threshold": 2,
    },
}

BACKGROUND_SOURCES = {
    "2d": {
        "modernDay": RESOURCES_DIR / "office-2d-themes-v1" / "modernDay.png",
        "modernNight": (
            RESOURCES_DIR / "office-2d-themes-v1" / "modernNight.png"
        ),
    },
    "3d": {
        "modernDay": RESOURCES_DIR / "office-theme-modern-day-v4.png",
        "modernNight": RESOURCES_DIR / "office-theme-modern-night-v4.png",
    },
}

MOTION_SOURCE_DIRS = {
    "2d": RESOURCES_DIR / "office-2d-motion-v1",
    "3d": RESOURCES_DIR / "office-3d-motion-v1",
}

MOTION_MANIFESTS = {
    "2d": ARTIFACTS_DIR / "office-2d-motion-v1-boxes.json",
    "3d": ARTIFACTS_DIR / "office-3d-motion-v1-boxes.json",
}


def upscale(
    image: Image.Image,
    style: str,
) -> Image.Image:
    settings = STYLE_SETTINGS[style]
    resized = image.resize(
        (
            image.width * SCALE,
            image.height * SCALE,
        ),
        Image.Resampling.LANCZOS,
    )
    return resized.filter(
        ImageFilter.UnsharpMask(
            radius=settings["radius"],
            percent=settings["percent"],
            threshold=settings["threshold"],
        )
    )


def stable_patch_edges(
    base_patch: Image.Image,
    motion_patch: Image.Image,
) -> Image.Image:
    width, height = motion_patch.size
    mask = Image.new("L", motion_patch.size, 0)
    ImageDraw.Draw(mask).rectangle(
        (
            STABLE_EDGE_WIDTH,
            STABLE_EDGE_WIDTH,
            width - STABLE_EDGE_WIDTH - 1,
            height - STABLE_EDGE_WIDTH - 1,
        ),
        fill=255,
    )
    return Image.composite(motion_patch, base_patch, mask)


def transparent_patch_edges(
    motion_patch: Image.Image,
    alpha: Image.Image,
) -> Image.Image:
    width, height = motion_patch.size
    interior = Image.new("L", motion_patch.size, 0)
    ImageDraw.Draw(interior).rectangle(
        (
            STABLE_EDGE_WIDTH,
            STABLE_EDGE_WIDTH,
            width - STABLE_EDGE_WIDTH - 1,
            height - STABLE_EDGE_WIDTH - 1,
        ),
        fill=255,
    )
    patch = motion_patch.convert("RGBA")
    patch.putalpha(ImageChops.multiply(alpha, interior))
    return patch


def build_backgrounds() -> dict[tuple[str, str], Image.Image]:
    backgrounds = {}
    for style, themes in BACKGROUND_SOURCES.items():
        for theme, source_path in themes.items():
            source = Image.open(source_path).convert("RGB")
            if source.size != CANVAS_SIZE:
                raise ValueError(
                    f"{source_path} 크기가 올바르지 않습니다. {source.size}"
                )

            retina = upscale(source, style)
            output_path = (
                OUTPUT_DIR
                / "backgrounds"
                / style
                / f"{theme}.png"
            )
            output_path.parent.mkdir(parents=True, exist_ok=True)
            retina.save(
                output_path,
                optimize=True,
                compress_level=7,
            )
            backgrounds[(style, theme)] = retina
    return backgrounds


def build_motion_patches(
    backgrounds: dict[tuple[str, str], Image.Image],
) -> int:
    output_count = 0
    padding = 8

    for style, source_root in MOTION_SOURCE_DIRS.items():
        specs = json.loads(
            MOTION_MANIFESTS[style].read_text(encoding="utf-8")
        )
        for theme, background_path in BACKGROUND_SOURCES[style].items():
            base = Image.open(background_path).convert("RGB")
            retina_base = backgrounds[(style, theme)]

            for spec in specs:
                x = spec["x"]
                y = spec["y"]
                width = spec["width"]
                height = spec["height"]
                source_patch_path = (
                    source_root
                    / theme
                    / f"{spec['character']}-{spec['kind']}.png"
                )
                source_image = Image.open(source_patch_path)
                source_patch = (
                    source_image.convert("RGBA")
                    if style == "2d"
                    else source_image.convert("RGB")
                )
                if source_patch.size != (width, height):
                    raise ValueError(
                        f"{source_patch_path} 크기가 올바르지 않습니다. "
                        f"{source_patch.size}"
                    )

                padded_box = (
                    max(0, x - padding),
                    max(0, y - padding),
                    min(CANVAS_SIZE[0], x + width + padding),
                    min(CANVAS_SIZE[1], y + height + padding),
                )
                local_variant = base.crop(padded_box)
                local_position = (
                    x - padded_box[0],
                    y - padded_box[1],
                )
                if "A" in source_patch.getbands():
                    local_variant.paste(
                        source_patch.convert("RGB"),
                        local_position,
                        source_patch.getchannel("A"),
                    )
                else:
                    local_variant.paste(source_patch, local_position)
                retina_variant = upscale(local_variant, style)

                local_x = (x - padded_box[0]) * SCALE
                local_y = (y - padded_box[1]) * SCALE
                retina_box = (
                    local_x,
                    local_y,
                    local_x + width * SCALE,
                    local_y + height * SCALE,
                )
                retina_patch = retina_variant.crop(retina_box)
                if "A" in source_patch.getbands():
                    retina_alpha = source_patch.getchannel("A").resize(
                        (
                            width * SCALE,
                            height * SCALE,
                        ),
                        Image.Resampling.NEAREST,
                    )
                    retina_patch = transparent_patch_edges(
                        retina_patch,
                        retina_alpha,
                    )
                else:
                    base_patch = retina_base.crop(
                        (
                            x * SCALE,
                            y * SCALE,
                            (x + width) * SCALE,
                            (y + height) * SCALE,
                        )
                    )
                    retina_patch = stable_patch_edges(
                        base_patch,
                        retina_patch,
                    )

                output_path = (
                    OUTPUT_DIR
                    / "motion"
                    / style
                    / theme
                    / f"{spec['character']}-{spec['kind']}.png"
                )
                output_path.parent.mkdir(parents=True, exist_ok=True)
                retina_patch.save(
                    output_path,
                    optimize=True,
                    compress_level=7,
                )
                output_count += 1

    return output_count


def verify_assets(
    backgrounds: dict[tuple[str, str], Image.Image],
) -> int:
    verified_count = 0

    for style, themes in BACKGROUND_SOURCES.items():
        specs = json.loads(
            MOTION_MANIFESTS[style].read_text(encoding="utf-8")
        )
        for theme in themes:
            background = backgrounds[(style, theme)]
            if background.size != RETINA_SIZE:
                raise ValueError(
                    f"{style}/{theme} 배경 크기가 올바르지 않습니다."
                )

            for spec in specs:
                patch_path = (
                    OUTPUT_DIR
                    / "motion"
                    / style
                    / theme
                    / f"{spec['character']}-{spec['kind']}.png"
                )
                patch_image = Image.open(patch_path)
                patch = (
                    patch_image.convert("RGBA")
                    if style == "2d"
                    else patch_image.convert("RGB")
                )
                expected_size = (
                    spec["width"] * SCALE,
                    spec["height"] * SCALE,
                )
                if patch.size != expected_size:
                    raise ValueError(
                        f"{patch_path} 크기가 올바르지 않습니다. "
                        f"{patch.size}"
                    )

                x = spec["x"] * SCALE
                y = spec["y"] * SCALE
                base_patch = background.crop(
                    (
                        x,
                        y,
                        x + expected_size[0],
                        y + expected_size[1],
                    )
                )
                width, height = expected_size
                edge_boxes = (
                    (0, 0, width, STABLE_EDGE_WIDTH),
                    (0, height - STABLE_EDGE_WIDTH, width, height),
                    (0, 0, STABLE_EDGE_WIDTH, height),
                    (width - STABLE_EDGE_WIDTH, 0, width, height),
                )
                if "A" in patch.getbands():
                    alpha = patch.getchannel("A")
                    if any(alpha.crop(box).getbbox() for box in edge_boxes):
                        raise ValueError(
                            f"{patch_path} 가장자리가 투명하지 않습니다."
                        )
                    composited = base_patch.copy()
                    composited.paste(
                        patch.convert("RGB"),
                        (0, 0),
                        alpha,
                    )
                    difference = ImageChops.difference(
                        composited,
                        base_patch,
                    )
                else:
                    difference = ImageChops.difference(patch, base_patch)
                    if any(
                        difference.crop(box).getbbox()
                        for box in edge_boxes
                    ):
                        raise ValueError(
                            f"{patch_path} 가장자리가 배경과 일치하지 않습니다."
                        )

                interior = difference.crop(
                    (
                        STABLE_EDGE_WIDTH,
                        STABLE_EDGE_WIDTH,
                        width - STABLE_EDGE_WIDTH,
                        height - STABLE_EDGE_WIDTH,
                    )
                )
                if interior.getbbox() is None:
                    raise ValueError(
                        f"{patch_path} 내부에 동작 변화가 없습니다."
                    )
                verified_count += 1

    return verified_count


def main() -> None:
    if OUTPUT_DIR.exists():
        for path in OUTPUT_DIR.rglob("*.png"):
            path.unlink()

    backgrounds = build_backgrounds()
    motion_count = build_motion_patches(backgrounds)
    verified_count = verify_assets(backgrounds)

    manifest = {
        "scale": SCALE,
        "canvas": {
            "width": CANVAS_SIZE[0],
            "height": CANVAS_SIZE[1],
        },
        "retina": {
            "width": RETINA_SIZE[0],
            "height": RETINA_SIZE[1],
        },
        "backgroundCount": len(backgrounds),
        "motionPatchCount": motion_count,
        "verifiedMotionPatchCount": verified_count,
    }
    (ARTIFACTS_DIR / "office-retina-v1-manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    print(
        f"Retina 배경 {len(backgrounds)}장과 "
        f"동작 패치 {motion_count}장을 생성하고 검증했습니다. {OUTPUT_DIR}"
    )


if __name__ == "__main__":
    main()
