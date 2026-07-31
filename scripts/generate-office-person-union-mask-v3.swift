// 이 스크립트는 두 오피스 이미지의 인물별 Vision 마스크를 합쳐 교체 허용 영역을 만든다.

import AppKit
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import Vision

struct PersonCrop {
    let name: String
    let rect: CGRect
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fputs(
        "사용법: swift generate-office-person-union-mask-v3.swift "
            + "<V4 PNG> <새 인물 PNG> <출력 마스크 PNG>\n",
        stderr
    )
    exit(2)
}

let baseURL = URL(fileURLWithPath: arguments[1])
let candidateURL = URL(fileURLWithPath: arguments[2])
let outputURL = URL(fileURLWithPath: arguments[3])

func loadImage(at url: URL) throws -> CGImage {
    guard
        let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw NSError(
            domain: "OfficePersonMask",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(url.path) 로드 실패"]
        )
    }
    return image
}

func visionMask(
    image: CGImage,
    crop: PersonCrop
) throws -> (pixels: [UInt8], width: Int, height: Int) {
    guard let croppedImage = image.cropping(to: crop.rect) else {
        throw NSError(
            domain: "OfficePersonMask",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(crop.name) crop 생성 실패"
            ]
        )
    }

    let request = VNGeneratePersonSegmentationRequest()
    request.qualityLevel = .accurate
    request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    try VNImageRequestHandler(
        cgImage: croppedImage,
        options: [:]
    ).perform([request])

    guard let buffer = request.results?.first?.pixelBuffer else {
        throw NSError(
            domain: "OfficePersonMask",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(crop.name) Vision 마스크 생성 실패"
            ]
        )
    }

    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer {
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
    }

    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
        throw NSError(
            domain: "OfficePersonMask",
            code: 4,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(crop.name) Vision 버퍼 접근 실패"
            ]
        )
    }

    let source = baseAddress.assumingMemoryBound(to: UInt8.self)
    var pixels = [UInt8](repeating: 0, count: width * height)
    for y in 0 ..< height {
        for x in 0 ..< width {
            pixels[y * width + x] = source[y * bytesPerRow + x]
        }
    }
    return (pixels, width, height)
}

func normalizedAlpha(_ value: UInt8) -> UInt8 {
    let low = 32
    let high = 112
    let sample = Int(value)
    if sample <= low {
        return 0
    }
    if sample >= high {
        return 255
    }
    return UInt8((sample - low) * 255 / (high - low))
}

func dilated(
    _ source: [UInt8],
    width: Int,
    height: Int,
    radius: Int
) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: source.count)
    for y in 0 ..< height {
        for x in 0 ..< width {
            var maximum: UInt8 = 0
            for sampleY in max(0, y - radius) ... min(height - 1, y + radius) {
                for sampleX in max(0, x - radius) ... min(width - 1, x + radius) {
                    maximum = max(
                        maximum,
                        source[sampleY * width + sampleX]
                    )
                }
            }
            output[y * width + x] = maximum
        }
    }
    return output
}

func softened(
    _ source: [UInt8],
    width: Int,
    height: Int
) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: source.count)
    for y in 0 ..< height {
        for x in 0 ..< width {
            var total = 0
            var count = 0
            for sampleY in max(0, y - 1) ... min(height - 1, y + 1) {
                for sampleX in max(0, x - 1) ... min(width - 1, x + 1) {
                    total += Int(source[sampleY * width + sampleX])
                    count += 1
                }
            }
            output[y * width + x] = UInt8(total / count)
        }
    }
    return output
}

func writeGrayscalePNG(
    pixels: [UInt8],
    width: Int,
    height: Int,
    to url: URL
) throws {
    let data = Data(pixels)
    guard
        let provider = CGDataProvider(data: data as CFData),
        let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ),
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        )
    else {
        throw NSError(
            domain: "OfficePersonMask",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "마스크 PNG 준비 실패"]
        )
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(
            domain: "OfficePersonMask",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "마스크 PNG 저장 실패"]
        )
    }
}

let baseImage = try loadImage(at: baseURL)
let candidateImage = try loadImage(at: candidateURL)
guard
    baseImage.width == 1_536,
    baseImage.height == 1_024,
    candidateImage.width == baseImage.width,
    candidateImage.height == baseImage.height
else {
    fputs("두 입력 이미지는 1536×1024로 같아야 합니다.\n", stderr)
    exit(3)
}

let crops = [
    PersonCrop(
        name: "boss",
        rect: CGRect(x: 690, y: 145, width: 155, height: 185)
    ),
    PersonCrop(
        name: "left-man",
        rect: CGRect(x: 245, y: 455, width: 180, height: 220)
    ),
    PersonCrop(
        name: "left-woman",
        rect: CGRect(x: 405, y: 400, width: 165, height: 215)
    ),
    PersonCrop(
        name: "right-woman",
        rect: CGRect(x: 1_035, y: 410, width: 155, height: 225)
    ),
    PersonCrop(
        name: "right-man",
        rect: CGRect(x: 1_170, y: 485, width: 185, height: 225)
    ),
]

let canvasWidth = baseImage.width
let canvasHeight = baseImage.height
var union = [UInt8](repeating: 0, count: canvasWidth * canvasHeight)

for crop in crops {
    let oldMask = try visionMask(image: baseImage, crop: crop)
    let newMask = try visionMask(image: candidateImage, crop: crop)
    let cropWidth = Int(crop.rect.width)
    let cropHeight = Int(crop.rect.height)
    var localUnion = [UInt8](repeating: 0, count: cropWidth * cropHeight)

    for y in 0 ..< cropHeight {
        let oldY = min(
            oldMask.height - 1,
            Int(Double(y) / Double(cropHeight) * Double(oldMask.height))
        )
        let newY = min(
            newMask.height - 1,
            Int(Double(y) / Double(cropHeight) * Double(newMask.height))
        )
        for x in 0 ..< cropWidth {
            let oldX = min(
                oldMask.width - 1,
                Int(Double(x) / Double(cropWidth) * Double(oldMask.width))
            )
            let newX = min(
                newMask.width - 1,
                Int(Double(x) / Double(cropWidth) * Double(newMask.width))
            )
            localUnion[y * cropWidth + x] = normalizedAlpha(
                max(
                    oldMask.pixels[oldY * oldMask.width + oldX],
                    newMask.pixels[newY * newMask.width + newX]
                )
            )
        }
    }

    localUnion = softened(
        dilated(
            localUnion,
            width: cropWidth,
            height: cropHeight,
            radius: 2
        ),
        width: cropWidth,
        height: cropHeight
    )

    let originX = Int(crop.rect.minX)
    let originY = Int(crop.rect.minY)
    var minimumX = cropWidth
    var minimumY = cropHeight
    var maximumX = -1
    var maximumY = -1

    for y in 0 ..< cropHeight {
        for x in 0 ..< cropWidth {
            let alpha = localUnion[y * cropWidth + x]
            guard alpha > 0 else {
                continue
            }
            let canvasIndex =
                (originY + y) * canvasWidth + originX + x
            union[canvasIndex] = max(union[canvasIndex], alpha)
            minimumX = min(minimumX, x)
            minimumY = min(minimumY, y)
            maximumX = max(maximumX, x)
            maximumY = max(maximumY, y)
        }
    }

    print(
        "\(crop.name) union "
            + "[\(originX + minimumX),\(originY + minimumY),"
            + "\(originX + maximumX + 1),\(originY + maximumY + 1))"
    )
}

try writeGrayscalePNG(
    pixels: union,
    width: canvasWidth,
    height: canvasHeight,
    to: outputURL
)
print(outputURL.path)
