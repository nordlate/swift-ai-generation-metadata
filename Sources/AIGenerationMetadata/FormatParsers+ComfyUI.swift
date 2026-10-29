import Foundation

/// ComfyUI workflow (API format) parsing: which sampler produced the saved image, and the
/// prompts, settings and model behind it.
extension FormatParsers {
    static func parseComfyUI(_ json: String, into result: ExtractedMediaMetadata) -> ExtractedMediaMetadata {
        var r = result
        guard let data = json.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return r }
        // VideoHelperSuite wraps the graph: {"prompt": {nodes} or "<nodes as JSON text>", "workflow": {…}}.
        if nodes(in: root).isEmpty, let graph = promptGraph(in: root) {
            root = graph
        }
        let sampler = finalSampler(in: root)
        if let sampler, ["KSampler", "KSamplerAdvanced"].contains(sampler.classType) {
            let inputs = sampler.inputs
            r.steps = Int32(clamping: resolveLinkedScalar(inputs["steps"], in: root) as? Int ?? 0)
            r.guidanceScale = resolveLinkedScalar(inputs["cfg"], in: root) as? Double ?? 0
            r.sampler = inputs["sampler_name"] as? String ?? ""
            r.scheduler = inputs["scheduler"] as? String ?? ""
            r.denoise = resolveLinkedScalar(inputs["denoise"], in: root) as? Double ?? 0
            r.seed = seedString(resolveLinkedScalar(inputs["seed"] ?? inputs["noise_seed"], in: root))
            r.prompt = traceToText(inputs, key: "positive", root: root).text
            r.negativePrompt = traceToText(inputs, key: "negative", root: root).text
            r.model = traceModelName(inputs, root: root)
        } else if let sampler, sampler.classType == "SamplerCustom" {
            parseSamplerCustom(sampler.inputs, root: root, into: &r)
        } else if let sampler {
            parseSamplerCustomAdvanced(sampler.inputs, root: root, into: &r)
        }
        if r.model.isEmpty { r.model = findFirstInput(in: root, classType: "CheckpointLoaderSimple", key: "ckpt_name") }
        if r.model.isEmpty { r.model = findFirstInput(in: root, classType: "UNETLoader", key: "unet_name") }
        if r.prompt.isEmpty {
            // Never an encoder that feeds a sampler's negative input.
            r.prompt = fallbackPrompt(in: root)
        }
        return r
    }

    /// Whether `json` holds a ComfyUI API-format graph, bare or in a VideoHelperSuite wrapper.
    static func isComfyUIGraph(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return !nodes(in: root).isEmpty || promptGraph(in: root) != nil
    }

    /// The node graph a wrapper's `prompt` holds, as an object or as JSON text; nil for any other
    /// value, such as a plain text prompt.
    static func promptGraph(in root: [String: Any]) -> [String: Any]? {
        let graph: [String: Any]?
        if let object = root["prompt"] as? [String: Any] {
            graph = object
        } else if let text = (root["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  text.hasPrefix("{"), let data = text.data(using: .utf8) {
            graph = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } else {
            graph = nil
        }
        return graph.flatMap { nodes(in: $0).isEmpty ? nil : $0 }
    }

    private static func parseSamplerCustomAdvanced(
        _ inputs: [String: Any], root: [String: Any], into r: inout ExtractedMediaMetadata
    ) {
        r.seed = traceToValue(inputs, key: "noise", field: "noise_seed", root: root)
        r.sampler = traceToValue(inputs, key: "sampler", field: "sampler_name", root: root)
        let schedulerInputs = traceToInputs(inputs, key: "sigmas", root: root)
        r.steps = Int32(clamping: schedulerInputs?["steps"] as? Int ?? 0)
        let guiderInputs = traceToInputs(inputs, key: "guider", root: root)
        if let gi = guiderInputs {
            // CFGGuider has `positive` and `negative`; BasicGuider has `conditioning`.
            r.prompt = traceToText(gi, key: gi["positive"] != nil ? "positive" : "conditioning", root: root).text
            if gi["negative"] != nil { r.negativePrompt = traceToText(gi, key: "negative", root: root).text }
            r.model = traceModelName(gi, root: root)
        }
        // FluxGuidance on the conditioning chain is the guidance scale; the guider's cfg (1.0 on
        // Flux) only counts without one.
        if let guidance = guiderInputs.flatMap({ traceGuidance($0, root: root) }) {
            r.guidanceScale = guidance
        } else if let cfg = guiderInputs.flatMap({ resolveLinkedScalar($0["cfg"], in: root) as? Double }) {
            r.guidanceScale = cfg
        } else if let guidance = findFirstGuidance(in: root) {
            r.guidanceScale = guidance
        }
    }

    /// The first positive-looking encoder's text, never an encoder wired to a sampler's or guider's negative input.
    private static func fallbackPrompt(in root: [String: Any]) -> String {
        var negativeEncoders = Set<String>()
        for node in samplerNodes(in: root) {
            if let id = traceToText(node.inputs, key: "negative", root: root).nodeID { negativeEncoders.insert(id) }
            if let guider = traceToInputs(node.inputs, key: "guider", root: root),
               let id = traceToText(guider, key: "negative", root: root).nodeID {
                negativeEncoders.insert(id)
            }
        }
        return nodes(in: root).lazy
            .filter { ["CLIPTextEncode", "CLIPTextEncodeSDXL"].contains($0.classType) && !negativeEncoders.contains($0.id) }
            .compactMap { encoderText($0.inputs, root: root) }
            .first ?? ""
    }

    /// SamplerCustom keeps its seed, CFG and conditioning on itself; only the sampler and sigmas are links.
    private static func parseSamplerCustom(
        _ inputs: [String: Any], root: [String: Any], into r: inout ExtractedMediaMetadata
    ) {
        r.seed = seedString(resolveLinkedScalar(inputs["noise_seed"], in: root))
        r.guidanceScale = resolveLinkedScalar(inputs["cfg"], in: root) as? Double ?? 0
        r.sampler = traceToValue(inputs, key: "sampler", field: "sampler_name", root: root)
        r.steps = Int32(clamping: traceToInputs(inputs, key: "sigmas", root: root)?["steps"] as? Int ?? 0)
        r.prompt = traceToText(inputs, key: "positive", root: root).text
        r.negativePrompt = traceToText(inputs, key: "negative", root: root).text
        r.model = traceModelName(inputs, root: root)
    }

    // MARK: - Graph helpers

    private static let samplerClassTypes: Set<String> = ["KSampler", "KSamplerAdvanced", "SamplerCustomAdvanced", "SamplerCustom"]

    private struct Node {
        let id: String
        let classType: String
        let inputs: [String: Any]
    }

    /// Nodes in node-id order (numeric where possible), so every choice below is deterministic
    /// instead of following dictionary order.
    private static func nodes(in root: [String: Any]) -> [Node] {
        root.compactMap { id, value -> Node? in
            guard let node = value as? [String: Any], let classType = node["class_type"] as? String else { return nil }
            return Node(id: id, classType: classType, inputs: node["inputs"] as? [String: Any] ?? [:])
        }
        .sorted { a, b in
            switch (Int(a.id), Int(b.id)) {
            case let (x?, y?): x < y
            case (_?, nil): true
            case (nil, _?): false
            default: a.id < b.id
            }
        }
    }

    private static func samplerNodes(in root: [String: Any]) -> [Node] {
        nodes(in: root).filter { samplerClassTypes.contains($0.classType) }
    }

    /// The sampler whose result is saved: walk back from a SaveImage node (else any other node
    /// with an `images` input, such as PreviewImage) through decode and latent steps to the
    /// first sampler. That is the final pass of a hires-fix or refiner workflow. Without an
    /// output node, the sampler with the highest node id.
    private static func finalSampler(in root: [String: Any]) -> Node? {
        let all = nodes(in: root)
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let outputs = all.filter { $0.inputs["images"] is [Any] }
            .sorted { ($0.classType == "SaveImage" ? 0 : 1) < ($1.classType == "SaveImage" ? 0 : 1) }
        for output in outputs {
            var current = output
            for _ in 0..<30 {
                guard let next = ["images", "samples", "latent_image", "latent", "image", "pixels"].lazy
                        .compactMap({ (current.inputs[$0] as? [Any])?.first as? String })
                        .first.flatMap({ byID[$0] }) else { break }
                if samplerClassTypes.contains(next.classType) { return next }
                current = next
            }
        }
        return all.last { samplerClassTypes.contains($0.classType) }
    }

    private static func traceToInputs(
        _ inputs: [String: Any], key: String, root: [String: Any]
    ) -> [String: Any]? {
        guard let link = inputs[key] as? [Any],
              let nid = link.first as? String,
              let node = root[nid] as? [String: Any],
              let ni = node["inputs"] as? [String: Any]
        else { return nil }
        return ni
    }

    /// Follows the conditioning link `key` back to a text encoder and returns its text and node.
    /// On a node with both `positive` and `negative` inputs (ControlNet, IP-Adapter, timestep
    /// ranges) the link's output slot decides: slot 1 is the negative output, so tracing
    /// continues through `negative`. Otherwise it follows the same key, then `conditioning`,
    /// then the first of combined conditionings.
    private static func traceToText(
        _ inputs: [String: Any], key: String, root: [String: Any], depth: Int = 0
    ) -> (text: String, nodeID: String?) {
        guard depth < 10,
              let link = inputs[key] as? [Any],
              let nid = link.first as? String,
              let node = root[nid] as? [String: Any],
              let ni = node["inputs"] as? [String: Any]
        else { return ("", nil) }
        if let text = encoderText(ni, root: root) { return (text, nid) }
        let slot = link.count > 1 ? (link[1] as? Int ?? 0) : 0
        let first = (ni["positive"] != nil && ni["negative"] != nil) ? (slot == 1 ? "negative" : "positive") : key
        var followKeys = [first]
        for fallback in ["conditioning", "conditioning_1", "conditioning_to"] where !followKeys.contains(fallback) {
            followKeys.append(fallback)
        }
        for followKey in followKeys {
            let result = traceToText(ni, key: followKey, root: root, depth: depth + 1)
            if !result.text.isEmpty { return result }
        }
        return ("", nil)
    }

    /// An encoder's text: `text` (else `text_g` of CLIPTextEncodeSDXL), literal or linked from a
    /// string node (String Literal, WAS Text, wildcards). Nil when the node has no usable text.
    private static func encoderText(_ ni: [String: Any], root: [String: Any]) -> String? {
        for key in ["text", "text_g"] {
            if let text = ni[key] as? String { return text }
            guard let link = ni[key] as? [Any], let nid = link.first as? String,
                  let source = (root[nid] as? [String: Any])?["inputs"] as? [String: Any] else { continue }
            for field in ["text", "string", "value"] {
                if let text = source[field] as? String { return text }
            }
        }
        return nil
    }

    /// The first guidance value on the conditioning chain behind `inputs`.
    private static func traceGuidance(_ inputs: [String: Any], root: [String: Any], depth: Int = 0) -> Double? {
        guard depth < 10 else { return nil }
        for key in ["conditioning", "positive", "conditioning_1"] {
            guard let ni = traceToInputs(inputs, key: key, root: root) else { continue }
            if let guidance = ni["guidance"] as? Double { return guidance }
            if let guidance = traceGuidance(ni, root: root, depth: depth + 1) { return guidance }
        }
        return nil
    }

    private static func traceToValue(
        _ inputs: [String: Any], key: String, field: String, root: [String: Any]
    ) -> String {
        guard let ni = traceToInputs(inputs, key: key, root: root) else { return "" }
        return seedString(ni[field])
    }

    /// Resolves a widget value that has been "converted to input" (rgthree Seed,
    /// Primitive, Seed Everywhere): the API JSON then holds a link array (`["12", 0]`)
    /// instead of the literal value. Follows the link once and reads the source node's
    /// own scalar widget input under one of the common field names; returns the value
    /// unchanged when it was never a link (an ordinary literal widget value).
    private static func resolveLinkedScalar(_ value: Any?, in root: [String: Any]) -> Any? {
        guard let link = value as? [Any],
              let nid = link.first as? String,
              let node = root[nid] as? [String: Any],
              let ni = node["inputs"] as? [String: Any]
        else { return value }
        for key in ["seed", "value", "Value", "int", "number", "INT", "FLOAT"] {
            if let v = ni[key], !(v is [Any]) { return v }
        }
        return nil
    }

    private static func traceModelName(
        _ inputs: [String: Any], root: [String: Any], depth: Int = 0
    ) -> String {
        // Mutually referencing `model` inputs would otherwise recurse until the stack
        // overflows, matching the bound already used by traceToText.
        guard depth < 10,
              let link = inputs["model"] as? [Any],
              let nid = link.first as? String,
              let node = root[nid] as? [String: Any],
              let ni = node["inputs"] as? [String: Any]
        else { return "" }
        if let name = ni["ckpt_name"] as? String { return name }
        if let name = ni["unet_name"] as? String { return name }
        return traceModelName(ni, root: root, depth: depth + 1)
    }

    /// The first match in node-id order.
    private static func findFirstInput(
        in root: [String: Any], classType: String, key: String, excluding excluded: Set<String> = []
    ) -> String {
        for node in nodes(in: root) where node.classType == classType && !excluded.contains(node.id) {
            if let value = node.inputs[key] as? String { return value }
        }
        return ""
    }

    private static func findFirstGuidance(in root: [String: Any]) -> Double? {
        for node in nodes(in: root) where node.classType == "FluxGuidance" {
            if let guidance = node.inputs["guidance"] as? Double { return guidance }
        }
        return nil
    }
}
