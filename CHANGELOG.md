# Changelog

The package uses semantic versioning. Before 1.0.0, a minor version may change the public API. Each entry also names the
`MediaMetadataExtractor.parserVersion` it ships, which goes up whenever extraction output changes.

## 0.1.0

First release (parser version 1).

- `MediaMetadataExtractor.extract(from:provenanceMarkers:)` reads PNG, JPEG and WebP images: PNG tEXt, zTXt and iTXt chunks with per-chunk and
  per-image size limits, and EXIF UserComment, including the IFD0 placement Fooocus's Pillow writer uses.
- `VideoMetadataExtractor.extract(from:)` reads duration, frame rate, displayed size and codec, and generation metadata from the container's
  text metadata items.
- Formats: Automatic1111/Forge, InvokeAI (current and legacy), Fooocus, SwarmUI, Midjourney, Runway and ComfyUI (graph traced from the
  sampler behind the saved image to its prompts, guidance and model; VideoHelperSuite video comments; workflow-only PNGs identified).
- `PNGProvenanceMarker` lets an app label PNGs from its own tool that also carry A1111-style `parameters`.
- `ExtractedMediaMetadata` is the result type for both.
