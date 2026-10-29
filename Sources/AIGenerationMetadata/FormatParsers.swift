import Foundation

enum FormatParsers {
    static func parseA1111(_ text: String, into result: ExtractedMediaMetadata) -> ExtractedMediaMetadata {
        var r = result
        let negSep = "\nNegative prompt: "
        let promptPart: String
        let remainder: String
        if let negRange = text.range(of: negSep) {
            promptPart = String(text[text.startIndex..<negRange.lowerBound])
            remainder = String(text[negRange.upperBound...])
        } else {
            promptPart = text
            remainder = ""
        }
        let lines = !remainder.isEmpty
            ? remainder.components(separatedBy: "\n")
            : promptPart.components(separatedBy: "\n")
        guard let (paramsLine, paramsIdx) = findParametersLine(in: lines) else {
            r.prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return r
        }
        let kv = parseKeyValueLine(paramsLine)
        r.steps = Int32(kv["Steps"] ?? "") ?? 0
        r.sampler = kv["Sampler"] ?? ""
        r.scheduler = kv["Schedule type"] ?? ""
        r.guidanceScale = Double(kv["CFG scale"] ?? "") ?? 0
        r.seed = kv["Seed"] ?? ""
        r.model = kv["Model"] ?? ""
        let leadingLines = Array(lines[0..<paramsIdx]).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if remainder.isEmpty {
            // A1111/Forge omits the `Negative prompt:` line when the negative prompt is
            // empty, so the parameters line sits at the end of the prompt block itself.
            r.prompt = leadingLines
        } else {
            r.prompt = promptPart.trimmingCharacters(in: .whitespacesAndNewlines)
            r.negativePrompt = leadingLines
        }
        return r
    }

    private static func findParametersLine(in lines: [String]) -> (String, Int)? {
        for (i, line) in lines.enumerated().reversed() where line.contains("Steps:") {
            return (line, i)
        }
        return nil
    }

    private static let kvRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"(\w[\w\s]*?):\s*("(?:[^"\\]|\\.)*"|[^,]+)"#)
    }()

    private static func parseKeyValueLine(_ line: String) -> [String: String] {
        var result: [String: String] = [:]
        guard let regex = kvRegex else { return result }
        let nsLine = line as NSString
        for match in regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
        where match.numberOfRanges >= 3 {
            let key = nsLine.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            var val = nsLine.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\""), val.hasSuffix("\"") { val = String(val.dropFirst().dropLast()) }
            result[key] = val
        }
        return result
    }

    static func parseInvokeAI(_ json: String, into result: ExtractedMediaMetadata) -> ExtractedMediaMetadata {
        var r = result
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return r }
        r.prompt = root["positive_prompt"] as? String ?? ""
        r.negativePrompt = root["negative_prompt"] as? String ?? ""
        // InvokeAI 4+ identifies the model by `name` (alongside `key` and `hash`); 3.x used
        // `model_name`.
        let model = root["model"] as? [String: Any]
        r.model = model?["name"] as? String ?? model?["model_name"] as? String ?? ""
        r.steps = Int32(clamping: root["steps"] as? Int ?? 0)
        r.guidanceScale = root["cfg_scale"] as? Double ?? 0
        r.sampler = root["scheduler"] as? String ?? ""
        r.seed = seedString(root["seed"])
        return r
    }

    /// Whether `json` is an InvokeAI metadata object: one with a prompt, model or sampling field.
    static func isInvokeAI(_ json: String) -> Bool {
        guard let root = jsonObject(json) else { return false }
        return ["positive_prompt", "negative_prompt", "model", "cfg_scale", "seed"].contains { root[$0] != nil }
    }

    static func isInvokeAILegacy(_ json: String) -> Bool {
        jsonObject(json)?["image"] is [String: Any]
    }

    static func isJSONObject(_ text: String) -> Bool { jsonObject(text) != nil }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func parseInvokeAILegacy(_ json: String, into result: ExtractedMediaMetadata) -> ExtractedMediaMetadata {
        var r = result
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let image = root["image"] as? [String: Any]
        else { return r }
        r.prompt = image["prompt"] as? String ?? ""
        r.steps = Int32(clamping: image["steps"] as? Int ?? 0)
        r.guidanceScale = image["cfg_scale"] as? Double ?? 0
        r.sampler = image["sampler"] as? String ?? ""
        r.seed = seedString(image["seed"])
        return r
    }

    /// Fooocus's own metadata scheme: the JSON object Fooocus writes into the PNG `parameters`
    /// chunk and, for JPEG and WebP, EXIF UserComment. Keys as upstream writes them
    /// (modules/meta_parser.py `FooocusMetadataParser.to_string` with the list built in
    /// modules/async_worker.py `save_and_log`; checked 2026-09-29): `prompt` and
    /// `negative_prompt` are what the user typed (`full_prompt` adds expansions and styles),
    /// `steps` an int, `guidance_scale` a float, `seed` a string, `base_model` a file name.
    static func parseFooocus(_ object: [String: Any], into result: ExtractedMediaMetadata) -> ExtractedMediaMetadata {
        var r = result
        r.prompt = object["prompt"] as? String ?? ""
        r.negativePrompt = object["negative_prompt"] as? String ?? ""
        r.model = object["base_model"] as? String ?? ""
        r.steps = int32(object["steps"])
        r.guidanceScale = double(object["guidance_scale"])
        r.sampler = object["sampler"] as? String ?? ""
        r.scheduler = object["scheduler"] as? String ?? ""
        r.seed = seedString(object["seed"])
        return r
    }

    /// SwarmUI's `sui_image_params` object. Keys are SwarmUI's parameter IDs, the
    /// display names lowercased with everything but letters removed (src/Text2Image/
    /// T2IParamTypes.cs `CleanTypeName`; values from T2IParamInput.cs, checked 2026-09-29):
    /// `negativeprompt`, `cfgscale`, the model as its cleaned name, `seed` a long.
    static func parseSwarmUI(_ params: [String: Any], into result: ExtractedMediaMetadata) -> ExtractedMediaMetadata {
        var r = result
        r.prompt = params["prompt"] as? String ?? ""
        r.negativePrompt = params["negativeprompt"] as? String ?? ""
        r.model = params["model"] as? String ?? ""
        r.steps = int32(params["steps"])
        r.guidanceScale = double(params["cfgscale"])
        r.sampler = params["sampler"] as? String ?? ""
        r.scheduler = params["scheduler"] as? String ?? ""
        r.seed = seedString(params["seed"])
        return r
    }

    /// A JSON number or a numeric string; 0 otherwise.
    private static func int32(_ value: Any?) -> Int32 {
        if let number = value as? NSNumber { return Int32(clamping: number.int64Value) }
        if let text = value as? String, let parsed = Int64(text.trimmingCharacters(in: .whitespaces)) { return Int32(clamping: parsed) }
        return 0
    }

    /// A JSON number or a numeric string; 0 otherwise (and for non-finite values).
    private static func double(_ value: Any?) -> Double {
        let parsed = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard let parsed, parsed.isFinite else { return 0 }
        return parsed
    }

    static func parseMidjourney(_ text: String, into result: ExtractedMediaMetadata) -> ExtractedMediaMetadata {
        var r = result
        // The Description ends with "Job ID: <uuid>"; with no flags before it, splitting on
        // " --" alone would leave it in the prompt.
        let body = text.range(of: "Job ID:").map { String(text[..<$0.lowerBound]) } ?? text
        let parts = body.components(separatedBy: " --")
        r.prompt = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for part in parts.dropFirst() {
            let tokens = part.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces)
            guard let flag = tokens.first else { continue }
            switch flag {
            case "v" where tokens.count > 1, "version" where tokens.count > 1:
                r.model = "Midjourney v\(tokens[1])"
            case "niji":
                r.model = tokens.count > 1 ? "Niji v\(tokens[1])" : "Niji"
            default: break
            }
        }
        return r
    }

    static func seedString(_ value: Any?) -> String {
        guard let value else { return "" }
        if let i = value as? Int { return String(i) }
        // ComfyUI seeds span the full UInt64 range. JSONSerialization bridges anything
        // at or above 2^63 as an unsigned NSNumber, which fails `as? Int` and used to
        // would otherwise fall through to a trapping Int64(Double) conversion.
        if let u = value as? UInt64 { return String(u) }
        if let s = value as? String { return s }
        if let d = value as? Double {
            // Both bounds are exactly representable: Double(Int64.min) is the lowest
            // value Int64(d) accepts, and 2^64 is the first that UInt64(d) rejects.
            guard d.isFinite, d >= Double(Int64.min), d < 18_446_744_073_709_551_616 else { return "" }
            return d < 0 ? String(Int64(d)) : String(UInt64(d))
        }
        return ""
    }
}
