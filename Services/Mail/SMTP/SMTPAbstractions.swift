// SMTPAbstractions.swift
// Protocols to decouple MailSendService from a concrete SMTP client implementation.
// This lets us swap in a SwiftNIO-based client for proper STARTTLS later without touching callers.

import Foundation

public protocol SMTPClientProtocol: Sendable {
    func testConnection(_ config: SMTPConfig) async -> Result<Void, SMTPError>
    func send(_ message: MailMessage, using config: SMTPConfig) async -> DeliveryResult
}
