// AILO_APP/Services/Serving/AttachmentServingService_Phase7.swift
// PHASE 7: Attachment Serving Service
// Handles serving attachments with HTTP caching, ETags, and proper Content-Disposition

import Foundation

// MARK: - Serving Configuration

public struct ServingConfiguration {
    /// Default cache max-age (1 hour)
    public let cacheMaxAge: Int
    
    /// Enable ETag-based caching
    public let enableETagCaching: Bool
    
    /// Enable inline display for images/PDFs
    public let enableInlineDisplay: Bool
    
    /// Max inline size (10 MB)
    public let maxInlineSize: Int
    
    public init(
        cacheMaxAge: Int = 3600,
        enableETagCaching: Bool = true,
        enableInlineDisplay: Bool = true,
        maxInlineSize: Int = 10 * 1024 * 1024
    ) {
        self.cacheMaxAge = cacheMaxAge
        self.enableETagCaching = enableETagCaching
        self.enableInlineDisplay = enableInlineDisplay
        self.maxInlineSize = maxInlineSize
    }
    
    public static let `default` = ServingConfiguration()
}

// MARK: - HTTP Headers

public struct HTTPHeaders {
    public var contentType: String
    public var contentDisposition: String
    public var contentLength: Int
    public var etag: String?
    public var cacheControl: String?
    public var lastModified: String?
    
    public init(
        contentType: String,
        contentDisposition: String,
        contentLength: Int,
        etag: String? = nil,
        cacheControl: String? = nil,
        lastModified: String? = nil
    ) {
        self.contentType = contentType
        self.contentDisposition = contentDisposition
        self.contentLength = contentLength
        self.etag = etag
        self.cacheControl = cacheControl
        self.lastModified = lastModified
    }
    
    /// Convert to dictionary for HTTP response
    public func toDictionary() -> [String: String] {
        var dict: [String: String] = [
            "Content-Type": contentType,
            "Content-Disposition": contentDisposition,
            "Content-Length": String(contentLength)
        ]
        
        if let etag = etag {
            dict["ETag"] = etag
        }
        
        if let cache = cacheControl {
            dict["Cache-Control"] = cache
        }
        
        if let modified = lastModified {
            dict["Last-Modified"] = modified
        }
        
        return dict
    }
}

// MARK: - Serving Response

public struct ServingResponse {
    public let data: Data
    public let headers: HTTPHeaders
    public let statusCode: Int
    
    public init(data: Data, headers: HTTPHeaders, statusCode: Int = 200) {
        self.data = data
        self.headers = headers
        self.statusCode = statusCode
    }
}

// MARK: - Attachment Serving Service

public actor AttachmentServingService {
    
    private let configuration: ServingConfiguration
    private let blobStore: BlobStore
    private let database: OpaquePointer
    private let securityService: AttachmentSecurityService
    
    public init(
        configuration: ServingConfiguration = .default,
        blobStore: BlobStore,
        database: OpaquePointer,
        securityService: AttachmentSecurityService
    ) {
        self.configuration = configuration
        self.blobStore = blobStore
        self.database = database
        self.securityService = securityService
    }
    
    // MARK: - Main Serving Method
    
    /// Serve attachment with proper HTTP headers
    public func serveAttachment(
        attachmentId: UUID,
        ifNoneMatch: String? = nil,
        forceDownload: Bool = false
    ) async throws -> ServingResponse {
        
        print("🌐 [SERVING] Serving attachment \(attachmentId)")
        
        // Step 1: Security check
        let isSafe = try await securityService.isAttachmentSafe(attachmentId: attachmentId)
        guard isSafe else {
            throw AttachmentSecurityError.quarantined
        }
        
        // Step 2: Get metadata
        guard let metadata = try await getAttachmentMetadata(id: attachmentId) else {
            throw NSError(domain: "ServingService", code: 7001,
                         userInfo: [NSLocalizedDescriptionKey: "Attachment not found"])
        }
        
        // Step 3: ETag check (304 Not Modified)
        let etag = metadata.blobId // SHA256 hash
        if configuration.enableETagCaching,
           let clientETag = ifNoneMatch,
           clientETag == etag {
            return notModifiedResponse(etag: etag)
        }
        
        // Step 4: Retrieve data
        guard let data = try blobStore.retrieveSafe(hash: metadata.blobId) else {
            throw NSError(domain: "ServingService", code: 7002,
                         userInfo: [NSLocalizedDescriptionKey: "Attachment data not found"])
        }
        
        // Step 5: Build headers
        let headers = buildHTTPHeaders(
            filename: metadata.filename,
            contentType: metadata.contentType,
            dataSize: data.count,
            etag: etag,
            forceDownload: forceDownload
        )
        
        print("✅ [SERVING] Served: \(metadata.filename) (\(data.count) bytes)")
        
        return ServingResponse(data: data, headers: headers)
    }
    
    // MARK: - CID-Based Serving (Inline Images)
    
    /// Serve attachment by Content-ID (for cid: references in HTML)
    public func serveByContentId(
        messageId: UUID,
        contentId: String,
        ifNoneMatch: String? = nil
    ) async throws -> ServingResponse {
        
        print("🌐 [SERVING] Serving inline by CID: \(contentId)")
        
        // Find attachment by Content-ID
        guard let attachmentId = try await findAttachmentByContentId(
            messageId: messageId,
            contentId: contentId
        ) else {
            throw NSError(domain: "ServingService", code: 7003,
                         userInfo: [NSLocalizedDescriptionKey: "Inline attachment not found"])
        }
        
        // Serve as inline (never force download for CID references)
        return try await serveAttachment(
            attachmentId: attachmentId,
            ifNoneMatch: ifNoneMatch,
            forceDownload: false
        )
    }
    
    // MARK: - HTTP Header Building
    
    private func buildHTTPHeaders(
        filename: String,
        contentType: String,
        dataSize: Int,
        etag: String,
        forceDownload: Bool
    ) -> HTTPHeaders {
        
        // Determine disposition
        let disposition: String
        if forceDownload {
            disposition = buildAttachmentDisposition(filename: filename)
        } else {
            // Check if content should be displayed inline
            if shouldDisplayInline(contentType: contentType, size: dataSize) {
                disposition = buildInlineDisposition(filename: filename)
            } else {
                disposition = buildAttachmentDisposition(filename: filename)
            }
        }
        
        // Cache control
        let cacheControl = "private, max-age=\(configuration.cacheMaxAge)"
        
        return HTTPHeaders(
            contentType: contentType,
            contentDisposition: disposition,
            contentLength: dataSize,
            etag: etag,
            cacheControl: cacheControl,
            lastModified: nil
        )
    }
    
    /// Build Content-Disposition for attachment (download)
    private func buildAttachmentDisposition(filename: String) -> String {
        // RFC 2231: filename*=UTF-8''encoded-name for proper UTF-8 support
        let encodedFilename = encodeRFC2231Filename(filename)
        return "attachment; filename=\"\(filename)\"; filename*=UTF-8''\(encodedFilename)"
    }
    
    /// Build Content-Disposition for inline display
    private func buildInlineDisposition(filename: String) -> String {
        let encodedFilename = encodeRFC2231Filename(filename)
        return "inline; filename=\"\(filename)\"; filename*=UTF-8''\(encodedFilename)"
    }
    
    /// Encode filename for RFC 2231 (percent-encoding)
    private func encodeRFC2231Filename(_ filename: String) -> String {
        return filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
    }
    
    /// Determine if content should be displayed inline
    private func shouldDisplayInline(contentType: String, size: Int) -> Bool {
        guard configuration.enableInlineDisplay else {
            return false
        }
        
        // Size check
        guard size <= configuration.maxInlineSize else {
            return false
        }
        
        // Content-Type check
        let inlineTypes = [
            "image/",
            "application/pdf",
            "text/plain",
            "text/html"
        ]
        
        return inlineTypes.contains { contentType.lowercased().hasPrefix($0) }
    }
    
    // MARK: - 304 Not Modified Response
    
    private func notModifiedResponse(etag: String) -> ServingResponse {
        print("⚡️ [SERVING] 304 Not Modified (ETag match)")
        
        let headers = HTTPHeaders(
            contentType: "application/octet-stream",
            contentDisposition: "",
            contentLength: 0,
            etag: etag,
            cacheControl: "private, max-age=\(configuration.cacheMaxAge)"
        )
        
        return ServingResponse(
            data: Data(),
            headers: headers,
            statusCode: 304
        )
    }
    
    // MARK: - Database Queries
    
    private func getAttachmentMetadata(id: UUID) async throws -> (
        filename: String,
        contentType: String,
        blobId: String
    )? {
        let sql = """
        SELECT filename, media_type, storage_key
        FROM attachments
        WHERE id = ?
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        
        sqlite3_bind_text(statement, 1, (id.uuidString as NSString).utf8String, -1, nil)
        
        var result: (String, String, String)?
        
        if sqlite3_step(statement) == SQLITE_ROW {
            if let filenameText = sqlite3_column_text(statement, 0),
               let contentTypeText = sqlite3_column_text(statement, 1),
               let blobIdText = sqlite3_column_text(statement, 2) {
                result = (
                    String(cString: filenameText),
                    String(cString: contentTypeText),
                    String(cString: blobIdText)
                )
            }
        }
        
        sqlite3_finalize(statement)
        return result
    }
    
    private func findAttachmentByContentId(
        messageId: UUID,
        contentId: String
    ) async throws -> UUID? {
        // Normalize Content-ID (remove < > if present)
        let normalizedCID = contentId
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        
        let sql = """
        SELECT id FROM attachments
        WHERE message_id = ? AND content_id = ?
        """
        
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        
        sqlite3_bind_text(statement, 1, (messageId.uuidString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (normalizedCID as NSString).utf8String, -1, nil)
        
        var attachmentId: UUID?
        
        if sqlite3_step(statement) == SQLITE_ROW {
            if let idText = sqlite3_column_text(statement, 0) {
                let idString = String(cString: idText)
                attachmentId = UUID(uuidString: idString)
            }
        }
        
        sqlite3_finalize(statement)
        return attachmentId
    }
    
    // MARK: - URL Generation
    
    /// Generate serving URL for attachment
    public func generateServingURL(
        attachmentId: UUID,
        forceDownload: Bool = false
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "ailo"
        components.host = "attachment"
        components.path = "/\(attachmentId.uuidString)"
        
        if forceDownload {
            components.queryItems = [
                URLQueryItem(name: "download", value: "1")
            ]
        }
        
        return components.url
    }
    
    /// Generate serving URL for inline content (CID)
    public func generateCIDServingURL(
        messageId: UUID,
        contentId: String
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "ailo"
        components.host = "attachment"
        components.path = "/cid/\(messageId.uuidString)"
        components.queryItems = [
            URLQueryItem(name: "cid", value: contentId)
        ]
        
        return components.url
    }
}

// MARK: - URL Handler Integration

/// URL handler for ailo://attachment/ scheme
public class AttachmentURLHandler {
    
    private let servingService: AttachmentServingService
    
    public init(servingService: AttachmentServingService) {
        self.servingService = servingService
    }
    
    /// Handle URL request
    public func handleURL(_ url: URL) async throws -> ServingResponse {
        guard url.scheme == "ailo", url.host == "attachment" else {
            throw NSError(domain: "URLHandler", code: 7100,
                         userInfo: [NSLocalizedDescriptionKey: "Invalid URL scheme"])
        }
        
        let path = url.path
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        
        // Check if CID request
        if path.hasPrefix("/cid/") {
            let messageIdString = path.replacingOccurrences(of: "/cid/", with: "")
            guard let messageId = UUID(uuidString: messageIdString),
                  let cidParam = components?.queryItems?.first(where: { $0.name == "cid" })?.value else {
                throw NSError(domain: "URLHandler", code: 7101,
                             userInfo: [NSLocalizedDescriptionKey: "Invalid CID URL"])
            }
            
            return try await servingService.serveByContentId(
                messageId: messageId,
                contentId: cidParam
            )
        }
        
        // Regular attachment request
        let attachmentIdString = path.replacingOccurrences(of: "/", with: "")
        guard let attachmentId = UUID(uuidString: attachmentIdString) else {
            throw NSError(domain: "URLHandler", code: 7102,
                         userInfo: [NSLocalizedDescriptionKey: "Invalid attachment ID"])
        }
        
        let forceDownload = components?.queryItems?.first(where: { $0.name == "download" })?.value == "1"
        
        return try await servingService.serveAttachment(
            attachmentId: attachmentId,
            forceDownload: forceDownload
        )
    }
}

// MARK: - Usage Documentation

/*
 ATTACHMENT SERVING SERVICE (Phase 7)
 =====================================
 
 INITIALIZATION:
 ```swift
 let servingService = AttachmentServingService(
     configuration: .default,
     blobStore: blobStore,
     database: db,
     securityService: securityService
 )
 ```
 
 SERVE ATTACHMENT:
 ```swift
 let response = try await servingService.serveAttachment(
     attachmentId: attachmentId,
     ifNoneMatch: clientETag,
     forceDownload: false
 )
 
 // HTTP headers
 print(response.headers.etag) // SHA256 hash
 print(response.headers.contentDisposition)
 print(response.statusCode) // 200 or 304
 ```
 
 SERVE INLINE (CID):
 ```swift
 let response = try await servingService.serveByContentId(
     messageId: messageId,
     contentId: "image001@example.com"
 )
 ```
 
 GENERATE URLS:
 ```swift
 // Direct attachment
 let url = servingService.generateServingURL(
     attachmentId: id,
     forceDownload: true
 )
 // ailo://attachment/<uuid>?download=1
 
 // Inline CID
 let cidURL = servingService.generateCIDServingURL(
     messageId: msgId,
     contentId: "img@example.com"
 )
 // ailo://attachment/cid/<uuid>?cid=img@example.com
 ```
 
 URL HANDLER:
 ```swift
 let handler = AttachmentURLHandler(servingService: servingService)
 let response = try await handler.handleURL(url)
 ```
 
 FEATURES:
 - ETag-based caching (SHA256)
 - 304 Not Modified responses
 - Content-Disposition (inline/attachment)
 - RFC 2231 filename encoding (UTF-8)
 - CID resolution for inline images
 - Security integration
 - Configurable inline size limits
 - Cache-Control headers
 
 HTTP HEADERS:
 - Content-Type: from attachment metadata
 - Content-Disposition: inline/attachment + filename
 - Content-Length: exact size
 - ETag: SHA256 hash
 - Cache-Control: private, max-age=3600
 - Last-Modified: optional
 
 INLINE DISPLAY:
 - Images: all formats
 - PDF: up to 10 MB
 - Text: plain/html
 - Others: force download
 */
