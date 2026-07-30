# 이 스크립트는 승인된 Anime V2 낮 원본에서 좌표 고정 밤 배경과 국소 동작 패치를 만든다.

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter


PROJECT_DIR = Path(__file__).resolve().parents[1]
ARTIFACTS_DIR = PROJECT_DIR / "artifacts"
RESOURCES_DIR = PROJECT_DIR / "Sources" / "OfficeCore" / "Resources"
SOURCE_DIR = ARTIFACTS_DIR / "motion-sources-2d"
THEME_DIR = RESOURCES_DIR / "office-2d-themes-v1"
MOTION_DIR = RESOURCES_DIR / "office-2d-motion-v1"
CANVAS_SIZE = (1_536, 1_024)

DAY_PATH = (
    ARTIFACTS_DIR
    / "office-2d-anime-geometry-locked-v2-character-identity.png"
)
LIGHTING_REFERENCE_PATH = (
    ARTIFACTS_DIR
    / "office-2d-anime-v2-night-lighting-imagegen-reference-v1.png"
)
GENERATED_SOURCE_PATHS = {
    "blink": SOURCE_DIR / "anime-v2-all-blink-source.png",
    "mouth": SOURCE_DIR / "anime-v2-all-mouth-source-v2-visible.png",
    "typing": SOURCE_DIR / "anime-v2-all-typing-source.png",
}
LEFT_MAN_MOUTH_SOURCE_PATH = (
    SOURCE_DIR / "anime-v2-all-mouth-source.png"
)

SPECS = [
    {
        "character": "boss",
        "kind": "blink",
        "crop": (749, 190, 826, 232),
        "ellipses": [
            (765, 198, 793, 216),
            (795, 197, 822, 215),
        ],
        "feather": 0.7,
    },
    {
        "character": "boss",
        "kind": "mouth",
        "crop": (779, 218, 805, 238),
        "ellipses": [(782, 220, 802, 235)],
        "feather": 0.8,
    },
    {
        "character": "boss",
        "kind": "typing",
        "crop": (758, 267, 801, 301),
        "ellipses": [(762, 270, 797, 298)],
        "feather": 0.9,
        "strength": 0.36,
    },
    {
        "character": "left-man",
        "kind": "blink",
        "crop": (320, 524, 411, 579),
        "ellipses": [
            (333, 533, 372, 566),
            (368, 530, 405, 565),
        ],
        "feather": 0.7,
    },
    {
        "character": "left-man",
        "kind": "mouth",
        "crop": (344, 558, 369, 580),
        "ellipses": [(346, 560, 367, 578)],
        "feather": 0.8,
    },
    {
        "character": "left-man",
        "kind": "typing",
        "crop": (329, 628, 382, 674),
        "ellipses": [(334, 635, 378, 670)],
        "feather": 0.9,
        "strength": 0.30,
    },
    {
        "character": "left-woman",
        "kind": "blink",
        "crop": (484, 467, 568, 518),
        "ellipses": [
            (496, 471, 529, 497),
            (526, 463, 562, 496),
        ],
        "feather": 0.7,
    },
    {
        "character": "left-woman",
        "kind": "mouth",
        "crop": (504, 486, 535, 514),
        "ellipses": [(508, 490, 531, 510)],
        "feather": 0.8,
    },
    {
        "character": "left-woman",
        "kind": "typing",
        "crop": (493, 550, 558, 592),
        "ellipses": [(498, 554, 553, 588)],
        "feather": 0.9,
        "strength": 0.32,
    },
    {
        "character": "right-woman",
        "kind": "blink",
        "crop": (1_087, 460, 1_173, 511),
        "ellipses": [
            (1_093, 470, 1_127, 500),
            (1_125, 462, 1_164, 499),
        ],
        "feather": 0.7,
    },
    {
        "character": "right-woman",
        "kind": "mouth",
        "crop": (1_106, 486, 1_135, 514),
        "ellipses": [(1_110, 490, 1_131, 510)],
        "feather": 0.8,
    },
    {
        "character": "right-woman",
        "kind": "typing",
        "crop": (1_099, 548, 1_165, 589),
        "ellipses": [(1_104, 552, 1_160, 585)],
        "feather": 0.9,
        "strength": 0.30,
    },
    {
        "character": "right-man",
        "kind": "blink",
        "crop": (1_215, 540, 1_303, 594),
        "ellipses": [
            (1_215, 558, 1_251, 589),
            (1_245, 558, 1_291, 600),
        ],
        "feather": 0.7,
    },
    {
        "character": "right-man",
        "kind": "mouth",
        "crop": (1_227, 581, 1_257, 610),
        "ellipses": [(1_231, 585, 1_253, 606)],
        "feather": 0.8,
    },
    {
        "character": "right-man",
        "kind": "typing",
        "crop": (1_232, 660, 1_291, 701),
        "ellipses": [(1_237, 664, 1_286, 697)],
        "feather": 0.9,
        "strength": 0.30,
    },
]


WINDOW_PANES = (
    ((379, 291), (414, 278), (414, 423), (379, 443)),
    ((426, 273), (480, 254), (480, 395), (426, 418)),
    ((489, 249), (542, 230), (542, 365), (489, 389)),
)

WHITEBOARD_USAGE_CORNERS = (
    (194, 414),
    (322, 339),
    (322, 419),
    (194, 502),
)

WINDOW_LIGHTS = (
    (0, 0.24, 0.52, 0.10, 0.030),
    (0, 0.58, 0.58, 0.10, 0.032),
    (0, 0.32, 0.68, 0.09, 0.030),
    (0, 0.68, 0.73, 0.10, 0.032),
    (1, 0.22, 0.43, 0.08, 0.028),
    (1, 0.48, 0.50, 0.09, 0.030),
    (1, 0.73, 0.59, 0.08, 0.028),
    (1, 0.30, 0.68, 0.09, 0.030),
    (1, 0.62, 0.76, 0.08, 0.028),
    (2, 0.22, 0.38, 0.07, 0.026),
    (2, 0.47, 0.45, 0.08, 0.028),
    (2, 0.72, 0.52, 0.07, 0.026),
    (2, 0.29, 0.61, 0.08, 0.028),
    (2, 0.58, 0.69, 0.07, 0.026),
)


def interpolate_point(
    start: tuple[float, float],
    end: tuple[float, float],
    amount: float,
) -> tuple[float, float]:
    return (
        start[0] + (end[0] - start[0]) * amount,
        start[1] + (end[1] - start[1]) * amount,
    )


def perspective_point(
    corners: tuple[
        tuple[float, float],
        tuple[float, float],
        tuple[float, float],
        tuple[float, float],
    ],
    horizontal: float,
    vertical: float,
) -> tuple[float, float]:
    top = interpolate_point(corners[0], corners[1], horizontal)
    bottom = interpolate_point(corners[3], corners[2], horizontal)
    return interpolate_point(top, bottom, vertical)


def make_night(
    frame: Image.Image,
    canonical_day: Image.Image,
    reference: Image.Image,
) -> Image.Image:
    frame_pixels = np.asarray(
        frame.convert("RGB"),
        dtype=np.float32,
    )
    day_pixels = np.asarray(
        canonical_day.convert("RGB"),
        dtype=np.float32,
    )
    reference_pixels = np.asarray(
        reference.convert("RGB"),
        dtype=np.float32,
    )
    if np.array_equal(frame_pixels, day_pixels):
        return reference.copy()

    day_low_frequency = np.asarray(
        canonical_day.filter(
            ImageFilter.GaussianBlur(12)
        ).convert("RGB"),
        dtype=np.float32,
    )
    reference_low_frequency = np.asarray(
        reference.filter(
            ImageFilter.GaussianBlur(12)
        ).convert("RGB"),
        dtype=np.float32,
    )
    graded_motion = reference_low_frequency + (
        frame_pixels - day_low_frequency
    ) * 0.86
    graded_motion_image = Image.fromarray(
        np.uint8(np.clip(graded_motion, 0, 255))
    )

    motion_magnitude = np.max(
        np.abs(frame_pixels - day_pixels),
        axis=2,
    )
    motion_mask = Image.fromarray(
        np.uint8(motion_magnitude > 1) * 255
    )
    motion_mask = motion_mask.filter(ImageFilter.MaxFilter(5))
    motion_mask = motion_mask.filter(ImageFilter.GaussianBlur(0.75))
    return Image.composite(
        graded_motion_image,
        reference,
        motion_mask,
    )


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

    if spec["kind"] == "typing":
        pixels = np.asarray(base.convert("RGB"), dtype=np.int16)
        red = pixels[..., 0]
        green = pixels[..., 1]
        blue = pixels[..., 2]
        skin = (
            (red > 125)
            & (red - green > 10)
            & (green - blue > 8)
            & (red - blue > 28)
        )
        skin_mask = Image.fromarray(np.uint8(skin) * 255)
        skin_mask = skin_mask.filter(ImageFilter.GaussianBlur(0.35))
        mask = ImageChops.multiply(mask, skin_mask)

    strength = spec.get("strength", 1.0)
    if strength < 1:
        mask = mask.point(lambda value: round(value * strength))

    return Image.composite(generated, base, mask)


def patch_with_stable_edges(
    base: Image.Image,
    variant: Image.Image,
    crop: tuple[int, int, int, int],
) -> Image.Image:
    patch = variant.crop(crop).convert("RGB")
    base_patch = base.crop(crop)
    difference = np.asarray(
        ImageChops.difference(base_patch, patch),
        dtype=np.uint8,
    )
    alpha = Image.fromarray(
        np.uint8(np.max(difference, axis=2) > 0) * 255,
    )
    width, height = patch.size
    edge_mask = Image.new("L", patch.size, 0)
    ImageDraw.Draw(edge_mask).rectangle(
        (2, 2, width - 3, height - 3),
        fill=255,
    )
    alpha = ImageChops.multiply(alpha, edge_mask)
    patch = patch.convert("RGBA")
    patch.putalpha(alpha)
    return patch


def paste_motion_patch(
    frame: Image.Image,
    patch: Image.Image,
    position: tuple[int, int],
) -> None:
    if "A" in patch.getbands():
        frame.paste(
            patch.convert("RGB"),
            position,
            patch.getchannel("A"),
        )
        return
    frame.paste(patch, position)


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
            )
            x0, y0, _, _ = spec["crop"]
            paste_motion_patch(frame, patch, (x0, y0))
        frames[kind] = frame

    sheet = Image.new("RGB", (1_536, 1_024), (240, 240, 240))
    positions = {
        "base": (0, 0),
        "blink": (768, 0),
        "mouth": (0, 512),
        "typing": (768, 512),
    }
    for key, position in positions.items():
        preview = frames[key].resize((768, 512), Image.Resampling.LANCZOS)
        sheet.paste(preview, position)
    sheet.save(ARTIFACTS_DIR / output_name)


def build_runtime_alignment_review(day: Image.Image) -> None:
    review = day.convert("RGBA")
    overlay = Image.new("RGBA", CANVAS_SIZE, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    draw.line(
        [*WHITEBOARD_USAGE_CORNERS, WHITEBOARD_USAGE_CORNERS[0]],
        fill=(0, 210, 255, 235),
        width=2,
    )
    for pane in WINDOW_PANES:
        draw.line(
            [*pane, pane[0]],
            fill=(255, 50, 185, 220),
            width=2,
        )
    draw.line(
        [(574, 414), (689, 476), (936, 476), (1_032, 420)],
        fill=(255, 171, 55, 230),
        width=3,
        joint="curve",
    )
    for pane_index, horizontal, vertical, _, _ in WINDOW_LIGHTS:
        x, y = perspective_point(
            WINDOW_PANES[pane_index],
            horizontal,
            vertical,
        )
        draw.ellipse(
            (x - 2, y - 2, x + 2, y + 2),
            fill=(255, 220, 90, 255),
        )

    Image.alpha_composite(review, overlay).convert("RGB").save(
        ARTIFACTS_DIR / "office-2d-anime-v2-runtime-alignment-review.png",
        optimize=True,
    )


def verify_patch(
    base: Image.Image,
    patch: Image.Image,
    crop: tuple[int, int, int, int],
    label: str,
) -> None:
    base_patch = base.crop(crop)
    if "A" in patch.getbands():
        alpha = patch.getchannel("A")
        if alpha.getbbox() is None:
            raise ValueError(f"{label} 패치에 불투명한 동작 픽셀이 없습니다.")
        composited = base_patch.copy()
        composited.paste(
            patch.convert("RGB"),
            (0, 0),
            alpha,
        )
        difference = ImageChops.difference(base_patch, composited)
    else:
        alpha = None
        difference = ImageChops.difference(base_patch, patch)
    if difference.getbbox() is None:
        raise ValueError(f"{label} 패치에 동작 변화가 없습니다.")

    width, height = patch.size
    edge_boxes = (
        (0, 0, width, 2),
        (0, height - 2, width, height),
        (0, 0, 2, height),
        (width - 2, 0, width, height),
    )
    edge_source = alpha if alpha is not None else difference
    if any(edge_source.crop(box).getbbox() for box in edge_boxes):
        raise ValueError(f"{label} 패치 가장자리가 배경과 다릅니다.")


def main() -> None:
    day = Image.open(DAY_PATH).convert("RGB")
    if not LIGHTING_REFERENCE_PATH.exists():
        raise FileNotFoundError(
            "ImageGen 야간 조명 참고본이 없습니다. "
            f"{LIGHTING_REFERENCE_PATH}"
        )
    night_reference = Image.open(
        LIGHTING_REFERENCE_PATH
    ).convert("RGB")
    generated_sources = {
        kind: Image.open(path).convert("RGB")
        for kind, path in GENERATED_SOURCE_PATHS.items()
    }
    left_man_mouth_source = Image.open(
        LEFT_MAN_MOUTH_SOURCE_PATH
    ).convert("RGB")
    for name, image in {
        "day": day,
        "night-reference": night_reference,
        "left-man-mouth": left_man_mouth_source,
        **generated_sources,
    }.items():
        if image.size != CANVAS_SIZE:
            raise ValueError(f"{name} 크기가 올바르지 않습니다. {image.size}")

    night = make_night(day, day, night_reference)
    THEME_DIR.mkdir(parents=True, exist_ok=True)
    day.save(THEME_DIR / "modernDay.png", optimize=True)
    night.save(THEME_DIR / "modernNight.png", optimize=True)
    night.save(
        ARTIFACTS_DIR / "office-2d-anime-v2-modern-night.png",
        optimize=True,
    )

    day_variants = {
        kind: day.copy()
        for kind in ("blink", "mouth", "typing")
    }
    for spec in SPECS:
        kind = spec["kind"]
        generated_source = (
            left_man_mouth_source
            if spec["character"] == "left-man" and kind == "mouth"
            else generated_sources[kind]
        )
        day_variants[kind] = localized_variant(
            day_variants[kind],
            generated_source,
            spec,
        )

    night_variants = {
        kind: make_night(variant, day, night_reference)
        for kind, variant in day_variants.items()
    }
    for kind, variant in day_variants.items():
        variant.save(
            SOURCE_DIR / f"anime-v2-localized-{kind}-source.png",
            optimize=True,
        )
        night_variants[kind].save(
            SOURCE_DIR / f"anime-v2-night-{kind}-source.png",
            optimize=True,
        )

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
        for theme, base, variant in (
            ("modernDay", day, day_variants[spec["kind"]]),
            ("modernNight", night, night_variants[spec["kind"]]),
        ):
            output_dir = MOTION_DIR / theme
            output_dir.mkdir(parents=True, exist_ok=True)
            patch = patch_with_stable_edges(
                base,
                variant,
                spec["crop"],
            )
            label = f"{theme}/{spec['character']}-{spec['kind']}"
            verify_patch(base, patch, spec["crop"], label)
            patch.save(
                output_dir
                / f"{spec['character']}-{spec['kind']}.png",
                optimize=True,
            )

    (ARTIFACTS_DIR / "office-2d-motion-v1-boxes.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    build_contact_sheet(
        day,
        "modernDay",
        "office-2d-anime-v2-day-motion-contact-sheet.png",
    )
    build_contact_sheet(
        night,
        "modernNight",
        "office-2d-anime-v2-night-motion-contact-sheet.png",
    )
    build_runtime_alignment_review(day)
    print(
        f"Anime V2 배경 2장과 동작 패치 {len(SPECS) * 2}장을 "
        f"생성하고 검증했습니다. {THEME_DIR}"
    )


if __name__ == "__main__":
    main()
