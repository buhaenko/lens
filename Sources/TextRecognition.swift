// On-device text recognition (Vision) and source-language detection.

import Foundation
import NaturalLanguage
@preconcurrency import Vision

/// Recognition-language hints for Vision: the user's languages first (translation targets + system), then auto-detect.
/// Only languages Vision actually supports are passed — an unsupported code would make the request fail.
func recognitionHints() -> [String] {
    let supported = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
    var wanted: [String] = []
    for id in langs.map(\.id) + systemLanguages {
        let base = Locale.Language(identifier: id).languageCode?.identifier ?? id
        if let match = supported.first(where: { $0 == id || $0.hasPrefix(base + "-") || $0 == base }), !wanted.contains(match) {
            wanted.append(match)
        }
    }
    return wanted
}

func recognize(_ image: CGImage) async -> String {
    let hints = recognitionHints()
    return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
        DispatchQueue.global(qos: .userInitiated).async {
            // performed synchronously, results read afterwards → the continuation resumes exactly once
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            if !hints.isEmpty { request.recognitionLanguages = hints }
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
                continuation.resume(returning: assemble(request.results ?? []))
            } catch {
                NSLog("Lensy: text recognition failed: %@", error.localizedDescription)
                continuation.resume(returning: "")
            }
        }
    }
}

/// Lines → paragraphs: lines close together are joined (hyphenation fixed), big gaps start a new paragraph.
func assemble(_ obs: [VNRecognizedTextObservation]) -> String {
    assembleLines(obs.compactMap { o -> (String, CGRect)? in
        guard let t = o.topCandidates(1).first?.string else { return nil }
        return (t, o.boundingBox)
    })
}

/// Pure part of `assemble` (tested): text + normalised bounding box (origin bottom-left, 0…1).
/// Lines are read top to bottom; close lines are joined, a big gap or a jump sideways starts a new paragraph.
func assembleLines(_ input: [(String, CGRect)]) -> String {
    let lines = input
        .map { ($0.0.trimmingCharacters(in: .whitespaces), $0.1) }
        .filter { !$0.0.isEmpty }
        .sorted { $0.1.midY > $1.1.midY }
    guard let first = lines.first else { return "" }

    var text = first.0
    for (previous, line) in zip(lines, lines.dropFirst()) {
        let gap = previous.1.minY - line.1.maxY
        let newParagraph = gap > previous.1.height * 0.9 || abs(line.1.minX - previous.1.minX) > 0.25
        if newParagraph {
            text += "\n\n" + line.0
        } else if text.hasSuffix("-"), let next = line.0.first {
            if next.isLowercase { text.removeLast() }       // "infor-" + "mation" → "information"
            text += line.0                                  // "Jean-" + "Paul"   → "Jean-Paul"
        } else {
            text += " " + line.0
        }
    }
    return text
}

/// Source language of the scanned text. No hard-coded list — any language NaturalLanguage knows;
/// the user's own languages are only a gentle hint for very short / ambiguous snippets.
func detectLanguage(_ text: String) -> String? {
    let r = NLLanguageRecognizer()
    r.processString(text)
    // confident? take it as is
    if let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p >= 0.6 { return lang.rawValue }
    // ambiguous (very short text, shared words…) → let the user's languages break the tie
    var hints: [NLLanguage: Double] = [:]
    for id in langs.map(\.id) + systemLanguages.prefix(3) {
        let base = Locale.Language(identifier: id).languageCode?.identifier ?? id
        hints[NLLanguage(base)] = 0.6
    }
    r.reset()
    r.languageHints = hints
    r.processString(text)
    return r.dominantLanguage?.rawValue
}
