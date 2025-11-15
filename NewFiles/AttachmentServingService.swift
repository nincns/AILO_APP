// AttachmentServingService.swift
// HTTP-basiertes Serving von Email Attachments mit Sicherheit
// Phase 7: Attachment serving with signed URLs and caching

import Foundation
import CryptoKit

// Verwende das BlobStoreProtocol aus dem Hauptprojekt
typealias BlobStoreProtocol = BlobStore  // Falls BlobStore die Klasse ist

// MARK: - Attachment Serving Service

class AttachmentServingService {
    
    private let blobStore: BlobStoreProtocol
    private let readDAO: MailReadDAO
    private let securityService: AttachmentSecurityService
    
    // Token configuration
    private let tokenValiditySeconds: TimeInterval = 3600 // 1 hour
    private let secretKey: Data
    
    // Cache control settings
    private let maxAge = 86400 // 1 day
    private let privateCache = true
    
    init(blobStore: BlobStoreProtocol,
         readDAO: MailReadDAO,
         securityService: AttachmentSecurityService,
         secretKey: Data? = nil) {
        self.blobStore = blobStore
        self.readDAO = readDAO
        self.securityService = securityService
        
        // Generate or use provided secret key
        if let key = secretKey {
            self.secretKey = key
        } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            self.secretKey = Data(bytes)
        }
    }
    
    // MARK: - Serve Attachment by Content-ID
    
    func serveAttachmentByCid(messageId: UUID, contentId: String) throws -> AttachmentResponse {
        print("🖼 [AttachmentServing] Serving CID: \(contentId) for message: \(messageId)")
        
        // Get MIME part by content-id
        guard let mimePart = try readDAO.getMimePartByContentId(
            messageId: messageId,
            contentId: contentId
        ) else {
            throw ServingError.notFound
        }
        
        // Retrieve blob data
        guard let blobId = mimePart.blobId,
              let data = try blobStore.retrieve(blobId: blobId) else {
            throw ServingError.dataNotAvailable
        }
        
        // Determine MIME type
        let mimeType = mimePart.mediaType.isEmpty ? "application/octet-stream" : mimePart.mediaType
        
        // Create response
        return AttachmentResponse(
            data: data,
            mimeType: mimeType,
            filename: mimePart.filenameNormalized,
            contentDisposition: .inline,
            cacheControl: generateCacheControl(),
            etag: generateETag(blobId: blobId)
        )
    }
    
    // MARK: - Serve Attachment by Part ID
    
    func serveAttachmentByPartId(messageId: UUID, partId: String, download: Bool = false) throws -> AttachmentResponse {
        print("📎 [AttachmentServing] Serving part: \(partId) for message: \(messageId)")
        
        // Get MIME part
        let mimeParts = try readDAO.getMimeParts(messageId: messageId)
        guard let mimePart = mimeParts.first(where: { $0.partId == partId }) else {
            throw ServingError.notFound
        }
        
        // Security check for dangerous types
        if let filename = mimePart.filenameNormalized {
            let sanitized = securityService.sanitizeFilename(filename)
            if sanitized != filename {
                print("⚠️ [AttachmentServing] Filename sanitized: \(filename) → \(sanitized)")
            }
        }
        
        // Retrieve blob data
        guard let blobId = mimePart.blobId,
              let data = try blobStore.retrieve(blobId: blobId) else {
            throw ServingError.dataNotAvailable
        }
        
        // Get proper MIME type with content sniffing protection
        let mimeType = securityService.getMimeType(
            for: mimePart.filenameNormalized ?? "file",
            data: data
        )
        
        // Determine disposition
        let disposition: ContentDisposition = download ? .attachment :
            (mimePart.disposition == "inline" ? .inline : .attachment)
        
        return AttachmentResponse(
            data: data,
            mimeType: mimeType,
            filename: mimePart.filenameNormalized,
            contentDisposition: disposition,
            cacheControl: generateCacheControl(),
            etag: generateETag(blobId: blobId),
            contentSecurityPolicy: generateCSP(mimeType: mimeType)
        )
    }
    
    // MARK: - Generate Signed URL
    
    func generateSignedUrl(for attachment: AttachmentRequest, baseUrl: URL) -> URL {
        let timestamp = Int(Date().timeIntervalSince1970)
        let expiry = timestamp + Int(tokenValiditySeconds)
        
        // Create token payload
        let payload = "\(attachment.messageId):\(attachment.partId):\(expiry)"
        let signature = generateSignature(payload: payload)
        
        // Build URL with query parameters
        var components = URLComponents(url: baseUrl, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "messageId", value: attachment.messageId.uuidString),
            URLQueryItem(name: "partId", value: attachment.partId),
            URLQueryItem(name: "expires", value: String(expiry)),
            URLQueryItem(name: "signature", value: signature)
        ]
        
        if attachment.download {
            components.queryItems?.append(URLQueryItem(name: "download", value: "true"))
        }
        
        return components.url!
    }
    
    // MARK: - Validate Signed URL
    
    func validateSignedUrl(messageId: UUID, partId: String, expires: Int, signature: String) throws {
        // Check expiry
        let now = Int(Date().timeIntervalSince1970)
        if now > expires {
            throw ServingError.tokenExpired
        }
        
        // Verify signature
        let payload = "\(messageId):\(partId):\(expires)"
        let expectedSignature = generateSignature(payload: payload)
        
        if signature != expectedSignature {
            throw ServingError.invalidSignature
        }
    }
    
    // MARK: - Private Helpers
    
    private func generateSignature(payload: String) -> String {
        let key = SymmetricKey(data: secretKey)
        let signature = HMAC<SHA256>.authenticationCode(
            for: payload.data(using: .utf8)!,
            using: key
        )
        return Data(signature).base64EncodedString()
    }
    
    private func generateETag(blobId: String) -> String {
        // Use first 8 chars of blob ID as ETag
        let etag = String(blobId.prefix(8))
        return "\"\(etag)\""
    }
    
    private func generateCacheControl() -> String {
        if privateCache {
            return "private, max-age=\(maxAge)"
        } else {
            return "public, max-age=\(maxAge), immutable"
        }
    }
    
    private func generateCSP(mimeType: String) -> String? {
        // Content Security Policy for different content types
        if mimeType.hasPrefix("text/html") {
            return "default-src 'none'; style-src 'unsafe-inline'; img-src data:;"
        } else if mimeType.hasPrefix("application/pdf") {
            return "default-src 'self'; object-src 'self';"
        }
        return nil
    }
}

// MARK: - HTTP Response Builder

extension AttachmentServingService {
    
    func buildHttpResponse(for response: AttachmentResponse) -> HTTPResponse {
        var headers: [String: String] = [
            "Content-Type": response.mimeType,
            "Content-Length": String(response.data.count),
            "Cache-Control": response.cacheControl
        ]
        
        // Add ETag if available
        if let etag = response.etag {
            headers["ETag"] = etag
        }
        
        // Add Content-Disposition
        let disposition = response.contentDisposition.rawValue
        if let filename = response.filename {
            // RFC 2231 encoding for non-ASCII filenames
            let encodedFilename = encodeFilename(filename)
            headers["Content-Disposition"] = "\(disposition); filename*=UTF-8''\(encodedFilename)"
        } else {
            headers["Content-Disposition"] = disposition
        }
        
        // Add security headers
        if let csp = response.contentSecurityPolicy {
            headers["Content-Security-Policy"] = csp
        }
        headers["X-Content-Type-Options"] = "nosniff"
        headers["X-Frame-Options"] = "DENY"
        
        return HTTPResponse(
            statusCode: 200,
            headers: headers,
            body: response.data
        )
    }
    
    private func encodeFilename(_ filename: String) -> String {
        // RFC 2231 encoding for HTTP Content-Disposition
        return filename.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? "attachment"
    }
}

// MARK: - Batch Operations

extension AttachmentServingService {
    
    /// Generate download links for all attachments in a message
    func generateDownloadLinks(for messageId: UUID, baseUrl: URL) throws -> [AttachmentLink] {
        let mimeParts = try readDAO.getMimeParts(messageId: messageId)
        
        var links: [AttachmentLink] = []
        
        for part in mimeParts {
            // Skip body parts
            if part.isBodyCandidate { continue }
            
            // Skip parts without content
            if part.blobId == nil { continue }
            
            let request = AttachmentRequest(
                messageId: messageId,
                partId: part.partId,
                download: true
            )
            
            let url = generateSignedUrl(for: request, baseUrl: baseUrl)
            
            links.append(AttachmentLink(
                partId: part.partId,
                filename: part.filenameNormalized ?? "attachment",
                mimeType: part.mediaType,
                size: Int(part.sizeOctets),
                url: url
            ))
        }
        
        return links
    }
    
    /// Create ZIP archive of all attachments
    func createAttachmentArchive(for messageId: UUID) throws -> Data {
        // This would use a ZIP library to create an archive
        // Placeholder implementation
        return Data()
    }
}

// MARK: - Supporting Types

struct AttachmentRequest {
    let messageId: UUID
    let partId: String
    let download: Bool
}

struct AttachmentResponse {
    let data: Data
    let mimeType: String
    let filename: String?
    let contentDisposition: ContentDisposition
    let cacheControl: String
    let etag: String?
    let contentSecurityPolicy: String?
    
    init(data: Data,
         mimeType: String,
         filename: String? = nil,
         contentDisposition: ContentDisposition = .inline,
         cacheControl: String = "private, max-age=86400",
         etag: String? = nil,
         contentSecurityPolicy: String? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.filename = filename
        self.contentDisposition = contentDisposition
        self.cacheControl = cacheControl
        self.etag = etag
        self.contentSecurityPolicy = contentSecurityPolicy
    }
}

struct AttachmentLink {
    let partId: String
    let filename: String
    let mimeType: String
    let size: Int
    let url: URL
}

struct HTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

enum ContentDisposition: String {
    case inline = "inline"
    case attachment = "attachment"
}

enum ServingError: Error {
    case notFound
    case dataNotAvailable
    case tokenExpired
    case invalidSignature
    case forbidden
    case internalError
}
