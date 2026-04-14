import AppKit
import Foundation
import UniformTypeIdentifiers

enum ExportError: LocalizedError {
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Export was cancelled."
        }
    }
}

struct ExportService: Sendable {
    static func makeDOCXData(transcript: String) throws -> Data {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscribeMacApp-DOCX-\(UUID().uuidString)", isDirectory: true)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let files: [(path: String, content: String)] = [
            ("[Content_Types].xml", contentTypesXML()),
            ("_rels/.rels", packageRelsXML()),
            ("docProps/app.xml", appPropsXML()),
            ("docProps/core.xml", corePropsXML()),
            ("word/document.xml", documentXML(transcript: transcript)),
            ("word/_rels/document.xml.rels", documentRelsXML())
        ]

        for file in files {
            let url = tempDir.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.content.data(using: .utf8)?.write(to: url)
        }

        let outputName = "transcript.docx"
        let zipResult = try ProcessRunner().run(
            executablePath: "/usr/bin/env",
            arguments: ["zip", "-q", "-r", outputName, "[Content_Types].xml", "_rels", "docProps", "word"],
            workingDirectory: tempDir
        )

        guard zipResult.exitCode == 0 else {
            throw TranscriptionError.commandFailed(
                command: "zip",
                exitCode: zipResult.exitCode,
                message: zipResult.standardError.isEmpty ? zipResult.standardOutput : zipResult.standardError
            )
        }

        let archiveURL = tempDir.appendingPathComponent(outputName)
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw TranscriptionError.outputNotFound("DOCX archive was not created.")
        }

        return try Data(contentsOf: archiveURL)
    }

    @MainActor
    static func makePDFData(transcript: String) throws -> Data {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13)
        ]

        let attributedText = NSAttributedString(string: transcript, attributes: attributes)
        let pageWidth: CGFloat = 595
        let padding: CGFloat = 36

        let textStorage = NSTextStorage(attributedString: attributedText)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: NSSize(width: pageWidth - (padding * 2), height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.glyphRange(for: textContainer)

        let usedRect = layoutManager.usedRect(for: textContainer)
        let pageHeight = max(842, usedRect.height + (padding * 2))

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: pageWidth, height: pageHeight))
        textView.isEditable = false
        textView.textContainerInset = NSSize(width: padding, height: padding)
        textView.textContainer?.containerSize = NSSize(width: pageWidth - (padding * 2), height: .greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textStorage?.setAttributedString(attributedText)

        return textView.dataWithPDF(inside: textView.bounds)
    }

    @MainActor
    static func save(data: Data, suggestedFileName: String, allowedExtensions: [String]) throws {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedFileName
        panel.allowedContentTypes = allowedExtensions.compactMap { UTType(filenameExtension: $0) }

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            throw ExportError.cancelled
        }

        try data.write(to: destinationURL, options: .atomic)
    }

    private static func contentTypesXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
            <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
            <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
        </Types>
        """
    }

    private static func packageRelsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
            <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
        </Relationships>
        """
    }

    private static func appPropsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"
                    xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">
            <Application>TranscribeMacApp</Application>
        </Properties>
        """
    }

    private static func corePropsXML() -> String {
        let date = ISO8601DateFormatter().string(from: Date())
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
                           xmlns:dc="http://purl.org/dc/elements/1.1/"
                           xmlns:dcterms="http://purl.org/dc/terms/"
                           xmlns:dcmitype="http://purl.org/dc/dcmitype/"
                           xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
            <dc:title>Transcript</dc:title>
            <dc:creator>TranscribeMacApp</dc:creator>
            <cp:lastModifiedBy>TranscribeMacApp</cp:lastModifiedBy>
            <dcterms:created xsi:type="dcterms:W3CDTF">\(date)</dcterms:created>
            <dcterms:modified xsi:type="dcterms:W3CDTF">\(date)</dcterms:modified>
        </cp:coreProperties>
        """
    }

    private static func documentRelsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>
        """
    }

    private static func documentXML(transcript: String) -> String {
        let lines = transcript.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let paragraphs = lines.map { line in
            let escaped = escapeXML(String(line))
            if escaped.isEmpty {
                return "<w:p/>"
            }
            return "<w:p><w:r><w:t xml:space=\"preserve\">\(escaped)</w:t></w:r></w:p>"
        }.joined()

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:wpc="http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas"
                    xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
                    xmlns:o="urn:schemas-microsoft-com:office:office"
                    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                    xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math"
                    xmlns:v="urn:schemas-microsoft-com:vml"
                    xmlns:wp14="http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing"
                    xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
                    xmlns:w10="urn:schemas-microsoft-com:office:word"
                    xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
                    xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml"
                    xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"
                    xmlns:wpi="http://schemas.microsoft.com/office/word/2010/wordprocessingInk"
                    xmlns:wne="http://schemas.microsoft.com/office/word/2006/wordml"
                    xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
                    mc:Ignorable="w14 wp14">
            <w:body>
                \(paragraphs)
                <w:sectPr>
                    <w:pgSz w:w="12240" w:h="15840"/>
                    <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/>
                    <w:cols w:space="708"/>
                    <w:docGrid w:linePitch="360"/>
                </w:sectPr>
            </w:body>
        </w:document>
        """
    }

    private static func escapeXML(_ input: String) -> String {
        input
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
