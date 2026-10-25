import CoreGraphics
import Foundation
import Vision

enum TextRecognitionError: LocalizedError {
    case empty

    var errorDescription: String? {
        "没有识别到文字。"
    }
}

enum TextRecognition {
    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let lines = (request.results)?
            .compactMap { $0.topCandidates(1).first?.string } ?? []
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TextRecognitionError.empty }
        return text
    }
}
