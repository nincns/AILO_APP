// Services/JourneyAttachmentService.swift
import Foundation
import CryptoKit
import UniformTypeIdentifiers
import UIKit

public struct JourneyAttachmentService {

    // MARK: - SHA256 Hash

    /// Berechnet SHA256-Hash für Deduplizierung
    public static func sha256Hash(of data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - MIME Type Detection

    /// Ermittelt MIME-Type aus Dateiendung
    public static func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()

        if let utType = UTType(filenameExtension: ext) {
            return utType.preferredMIMEType ?? "application/octet-stream"
        }

        // Fallback für häufige Typen
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt": return "application/vnd.ms-powerpoint"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "txt": return "text/plain"
        case "md": return "text/markdown"
        case "mp3": return "audio/mpeg"
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }

    /// Ermittelt MIME-Type aus UTType
    public static func mimeType(for utType: UTType) -> String {
        utType.preferredMIMEType ?? "application/octet-stream"
    }

    // MARK: - Create Attachment

    /// Erstellt JourneyAttachment aus Daten
    public static func createAttachment(
        nodeId: UUID,
        filename: String,
        data: Data
    ) -> JourneyAttachment {
        JourneyAttachment(
            nodeId: nodeId,
            filename: filename,
            mimeType: mimeType(for: filename),
            fileSize: Int64(data.count),
            dataHash: sha256Hash(of: data)
        )
    }

    // MARK: - Type Checks

    /// Prüft ob MIME-Type ein Bild ist
    public static func isImage(mimeType: String) -> Bool {
        mimeType.hasPrefix("image/")
    }

    /// Prüft ob MIME-Type ein Video ist
    public static func isVideo(mimeType: String) -> Bool {
        mimeType.hasPrefix("video/")
    }

    /// Prüft ob MIME-Type Audio ist
    public static func isAudio(mimeType: String) -> Bool {
        mimeType.hasPrefix("audio/")
    }

    /// Prüft ob MIME-Type ein PDF ist
    public static func isPDF(mimeType: String) -> Bool {
        mimeType == "application/pdf"
    }

    /// Prüft ob MIME-Type ein Dokument ist
    public static func isDocument(mimeType: String) -> Bool {
        mimeType.contains("word") ||
        mimeType.contains("document") ||
        mimeType.contains("text/") ||
        isPDF(mimeType: mimeType)
    }

    /// Prüft ob MIME-Type eine Tabelle ist
    public static func isSpreadsheet(mimeType: String) -> Bool {
        mimeType.contains("sheet") || mimeType.contains("excel")
    }

    /// Prüft ob MIME-Type ein Archiv ist
    public static func isArchive(mimeType: String) -> Bool {
        mimeType.contains("zip") || mimeType.contains("archive") || mimeType.contains("compressed")
    }

    // MARK: - Icons

    /// Gibt passendes SF Symbol für MIME-Type zurück
    public static func icon(for mimeType: String) -> String {
        if isImage(mimeType: mimeType) {
            return "photo"
        } else if isVideo(mimeType: mimeType) {
            return "video"
        } else if isAudio(mimeType: mimeType) {
            return "waveform"
        } else if isPDF(mimeType: mimeType) {
            return "doc.richtext"
        } else if isSpreadsheet(mimeType: mimeType) {
            return "tablecells"
        } else if mimeType.contains("presentation") || mimeType.contains("powerpoint") {
            return "rectangle.split.3x1"
        } else if isDocument(mimeType: mimeType) {
            return "doc.text"
        } else if isArchive(mimeType: mimeType) {
            return "doc.zipper"
        } else {
            return "doc"
        }
    }

    // MARK: - File Size Formatting

    /// Formatiert Dateigröße als lesbaren String
    public static func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Thumbnail Generation

    /// Erstellt Thumbnail aus Bilddaten
    public static func generateThumbnail(from data: Data, maxSize: CGFloat = 200) -> Data? {
        guard let image = UIImage(data: data) else { return nil }

        let scale = min(maxSize / image.size.width, maxSize / image.size.height, 1.0)
        let newSize = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )

        let renderer = UIGraphicsImageRenderer(size: newSize)
        let thumbnail = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }

        return thumbnail.jpegData(compressionQuality: 0.7)
    }
}
