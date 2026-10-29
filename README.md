# swift-ai-generation-metadata

Read the prompt, model and settings that AI tools embed in images and videos, in Swift, on macOS and iOS.

`AIGenerationMetadata` reads what Stable Diffusion front ends and other generators write into their output files and returns it as one
struct: prompt, negative prompt, model, sampler, scheduler, steps, guidance, denoise, seed and the tool it came from, plus the file's
displayed size and, for videos, duration, frame rate and codec. It uses only Apple's system frameworks (Foundation, ImageIO, AVFoundation,
CoreMedia, Compression) and has no dependencies.

> **Unofficial.** This project is not affiliated with, endorsed by or maintained by any of the tools whose formats it reads.

## What it reads

| Tool | Where | Fields |
|---|---|---|
| Automatic1111, Forge | PNG `parameters`; JPEG/WebP EXIF UserComment; video comment | prompt, negative prompt, steps, sampler, schedule type, CFG scale, seed, model |
| ComfyUI | PNG `prompt` (API graph); PNG `workflow` (identified only); VideoHelperSuite video comment | the graph is traced back from the node that saves the image to its sampler (KSampler, KSamplerAdvanced, SamplerCustom, SamplerCustomAdvanced), then to its prompts (through ControlNet, combine and SDXL encoders, linked text nodes), guidance (CFG or FluxGuidance), seed, steps, scheduler, denoise and model |
| InvokeAI | PNG `invokeai_metadata` (3.x and later); PNG `sd-metadata` (legacy) | prompt, negative prompt, model, steps, CFG scale, scheduler, seed |
| Fooocus | PNG `parameters` (JSON); JPEG/WebP EXIF UserComment, including the IFD0 placement Fooocus's Pillow writer uses | prompt, negative prompt, base model, steps, guidance, sampler, scheduler, seed |
| SwarmUI | PNG `parameters` (`sui_image_params`); JPEG/WebP EXIF UserComment | prompt, negative prompt, model, steps, CFG scale, sampler, scheduler, seed |
| Midjourney | PNG `Description` | prompt, version (`--v`, `--niji`) |
| Runway | video metadata (JSON with `prompt`) | prompt, model |

Text is read from PNG tEXt, zTXt and iTXt chunks and from EXIF UserComment (ASCII, Unicode and undefined encodings). The file's leading bytes
pick the reader, so a JPEG named `.png` still reads as a JPEG. Data a reader does not recognise leaves the platform empty rather than being
guessed at: an ordinary camera comment is not an A1111 prompt, and an unknown JSON object in `parameters` is not stored as one.

Every read is bounded, because the files come from anywhere: PNG text is limited per chunk and per image (decompression stops at the limit),
EXIF is read only from the head of a JPEG or one WebP chunk, ComfyUI graph tracing has depth limits, and out-of-range numbers are clamped
instead of trapping.

## Requirements

- macOS 15 or iOS 18 or later
- Swift 6.0 or later (Xcode 16 or later); the package builds in Swift 6 language mode

## Installation

Add the package with Swift Package Manager and depend on the `AIGenerationMetadata` product:

```swift
.package(url: "https://github.com/nordlate/swift-ai-generation-metadata", from: "0.1.0")
```

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "AIGenerationMetadata", package: "swift-ai-generation-metadata"),
])
```

## Usage

```swift
import AIGenerationMetadata

let image = MediaMetadataExtractor.extract(from: URL(fileURLWithPath: "/path/to/image.png"))
if !image.sourcePlatform.isEmpty {
    print(image.sourcePlatform, image.prompt, image.model, image.steps, image.seed)
}
print(image.width, image.height, image.aspectRatio)

let video = await VideoMetadataExtractor.extract(from: URL(fileURLWithPath: "/path/to/clip.mp4"))
print(video.duration, video.frameRate, video.codec ?? "", video.prompt)
```

Both calls do file I/O and never throw: a missing, unreadable or unrecognised file gives empty fields (empty strings and zeros). The image
extractor is synchronous, so run it off the main thread when reading many files.

If your own app writes A1111-style `parameters` plus a chunk of its own, register that chunk to label those images with your app's name
instead of `Automatic1111`:

```swift
let marker = PNGProvenanceMarker(keyword: "myapp", platform: "MyApp")
let result = MediaMetadataExtractor.extract(from: url, provenanceMarkers: [marker])
```

## Parser versioning

`MediaMetadataExtractor.parserVersion` is an integer that goes up whenever a change to the package can extract something different from
the same file (a new format, a parser fix, a new field). Store it next to the results you keep, and re-read files extracted by an older
version after updating the package. The changelog names the parser version of each release.

Package releases follow semantic versioning, with a release tag per version; changes are listed in `CHANGELOG.md`. Before 1.0.0 a minor
version may change the public API.

## Tests

```bash
swift test
```

The tests build their fixture files in code (PNG chunks, EXIF blocks, small MP4s), plus two small Fooocus files embedded as base64.

## Contributing

Maintained for the needs of the app that uses it; contributions are welcome. See `CONTRIBUTING.md`.

## Licence

MIT, see `LICENSE`.
