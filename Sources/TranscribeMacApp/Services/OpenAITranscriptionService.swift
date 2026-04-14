import Foundation
import UniformTypeIdentifiers

struct OpenAITranscriptionService: Sendable {
    func transcribe(
        fileURL: URL,
        apiKey: String,
        model: String,
        languageCode: String?,
        apiBaseURLOverride: String?
    ) async throws -> String {
        let endpoint = try resolveEndpoint(apiBaseURLOverride: apiBaseURLOverride)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try makeMultipartBody(
            boundary: boundary,
            fileURL: fileURL,
            model: model,
            languageCode: languageCode
        )

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.apiFailure(statusCode: -1, message: "No HTTP response received.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw TranscriptionError.apiFailure(
                statusCode: httpResponse.statusCode,
                message: parseErrorMessage(from: data)
            )
        }

        guard let transcript = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !transcript.isEmpty
        else {
            throw TranscriptionError.outputNotFound("OpenAI API returned an empty transcript.")
        }

        return transcript
    }

    private func resolveEndpoint(apiBaseURLOverride: String?) throws -> URL {
        guard let override = apiBaseURLOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
              !override.isEmpty
        else {
            guard let defaultEndpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions") else {
                throw TranscriptionError.validation("Invalid OpenAI endpoint URL.")
            }
            return defaultEndpoint
        }

        guard var components = URLComponents(string: override),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil
        else {
            throw TranscriptionError.validation("Invalid API base URL override.")
        }

        let normalizedPath = components.path.removingTrailingSlashes
        if normalizedPath.hasSuffix("/audio/transcriptions") {
            components.path = normalizedPath
        } else if normalizedPath.isEmpty {
            components.path = "/v1/audio/transcriptions"
        } else if normalizedPath.hasSuffix("/v1") {
            components.path = "\(normalizedPath)/audio/transcriptions"
        } else {
            components.path = "\(normalizedPath)/v1/audio/transcriptions"
        }

        guard let endpoint = components.url else {
            throw TranscriptionError.validation("Invalid API base URL override.")
        }

        return endpoint
    }

    private func makeMultipartBody(
        boundary: String,
        fileURL: URL,
        model: String,
        languageCode: String?
    ) throws -> Data {
        var body = Data()

        func addField(name: String, value: String) {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }

        addField(name: "model", value: model)
        addField(name: "response_format", value: "text")

        if let languageCode {
            addField(name: "language", value: languageCode)
        }

        let fileData = try Data(contentsOf: fileURL)
        let mimeType = mimeType(for: fileURL)

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.appendString("\r\n")

        body.appendString("--\(boundary)--\r\n")
        return body
    }

    private func mimeType(for fileURL: URL) -> String {
        guard let utType = UTType(filenameExtension: fileURL.pathExtension) else {
            return "application/octet-stream"
        }
        return utType.preferredMIMEType ?? "application/octet-stream"
    }

    private func parseErrorMessage(from data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }

        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }

        return "Unknown API error."
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}

private extension String {
    var removingTrailingSlashes: String {
        replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }
}
