// Views/Assistant/Modules/MailSetup/MailProviderPresets.swift
// AILO - Vorkonfigurierte E-Mail Provider

import Foundation

// MARK: - Email Provider Preset

struct EmailProviderPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String
    let domains: [String]

    // IMAP Einstellungen
    let imapHost: String
    let imapPort: Int
    let imapEncryption: EncryptionType

    // SMTP Einstellungen
    let smtpHost: String
    let smtpPort: Int
    let smtpEncryption: EncryptionType

    // Authentifizierung
    let authType: AuthType
    let requiresAppPassword: Bool
    let appPasswordURL: String?

    // Hinweise für Benutzer
    let setupNotes: String?

    enum EncryptionType: String, CaseIterable {
        case ssl = "SSL/TLS"
        case starttls = "STARTTLS"
        case none = "None"
    }

    enum AuthType: String {
        case password = "Password"
        case appPassword = "App-Password"
        case oauth2 = "OAuth2"
    }
}

// MARK: - Provider Database

struct EmailProviderDatabase {

    /// Findet Provider anhand der E-Mail-Domain
    static func detect(email: String) -> EmailProviderPreset? {
        guard let domain = email.split(separator: "@").last?.lowercased() else {
            return nil
        }

        return allProviders.first { provider in
            provider.domains.contains { $0.lowercased() == domain }
        }
    }

    /// Alle verfügbaren Provider
    static let allProviders: [EmailProviderPreset] = [
        gmx,
        webde,
        gmail,
        outlook,
        tonline,
        yahoo,
        icloud,
        posteo,
        mailbox
    ]

    // MARK: - Deutsche Provider

    static let gmx = EmailProviderPreset(
        id: "gmx",
        name: "GMX",
        icon: "envelope.fill",
        domains: ["gmx.de", "gmx.net", "gmx.at", "gmx.ch"],
        imapHost: "imap.gmx.net",
        imapPort: 993,
        imapEncryption: .ssl,
        smtpHost: "mail.gmx.net",
        smtpPort: 587,
        smtpEncryption: .starttls,
        authType: .password,
        requiresAppPassword: false,
        appPasswordURL: nil,
        setupNotes: String(localized: "provider.gmx.note")
    )

    static let webde = EmailProviderPreset(
        id: "webde",
        name: "WEB.DE",
        icon: "envelope.fill",
        domains: ["web.de"],
        imapHost: "imap.web.de",
        imapPort: 993,
        imapEncryption: .ssl,
        smtpHost: "smtp.web.de",
        smtpPort: 587,
        smtpEncryption: .starttls,
        authType: .password,
        requiresAppPassword: false,
        appPasswordURL: nil,
        setupNotes: String(localized: "provider.webde.note")
    )

    static let tonline = EmailProviderPreset(
        id: "t-online",
        name: "T-Online",
        icon: "envelope.fill",
        domains: ["t-online.de"],
        imapHost: "secureimap.t-online.de",
        imapPort: 993,
        imapEncryption: .ssl,
        smtpHost: "securesmtp.t-online.de",
        smtpPort: 587,
        smtpEncryption: .starttls,
        authType: .password,
        requiresAppPassword: false,
        appPasswordURL: nil,
        setupNotes: nil
    )

    static let posteo = EmailProviderPreset(
        id: "posteo",
        name: "Posteo",
        icon: "leaf.fill",
        domains: ["posteo.de", "posteo.net"],
        imapHost: "posteo.de",
        imapPort: 993,
        imapEncryption: .ssl,
        smtpHost: "posteo.de",
        smtpPort: 587,
        smtpEncryption: .starttls,
        authType: .password,
        requiresAppPassword: false,
        appPasswordURL: nil,
        setupNotes: nil
    )

    static let mailbox = EmailProviderPreset(
        id: "mailbox",
        name: "mailbox.org",
        icon: "lock.shield.fill",
        domains: ["mailbox.org"],
        imapHost: "imap.mailbox.org",
        imapPort: 993,
        imapEncryption: .ssl,
        smtpHost: "smtp.mailbox.org",
        smtpPort: 587,
        smtpEncryption: .starttls,
        authType: .password,
        requiresAppPassword: false,
        appPasswordURL: nil,
        setupNotes: nil
    )

    // MARK: - Internationale Provider

    static let gmail = EmailProviderPreset(
        id: "gmail",
        name: "Gmail",
        icon: "envelope.badge.fill",
        domains: ["gmail.com", "googlemail.com"],
        imapHost: "imap.gmail.com",
        imapPort: 993,
        imapEncryption: .ssl,
        smtpHost: "smtp.gmail.com",
        smtpPort: 587,
        smtpEncryption: .starttls,
        authType: .appPassword,
        requiresAppPassword: true,
        appPasswordURL: "https://myaccount.google.com/apppasswords",
        setupNotes: String(localized: "provider.gmail.note")
    )

    static let outlook = EmailProviderPreset(
        id: "outlook",
        name: "Outlook / Hotmail",
        icon: "envelope.fill",
        domains: ["outlook.com", "outlook.de", "hotmail.com", "hotmail.de", "live.com", "live.de", "msn.com"],
        imapHost: "imap-mail.outlook.com",
        imapPort: 993,
        imapEncryption: .ssl,
        smtpHost: "smtp-mail.outlook.com",
        smtpPort: 587,
        smtpEncryption: .starttls,
        authType: .password,
        requiresAppPassword: false,
        appPasswordURL: nil,
        setupNotes: nil
    )

    static let yahoo = EmailProviderPreset(
        id: "yahoo",
        name: "Yahoo",
        icon: "envelope.fill",
        domains: ["yahoo.de", "yahoo.com"],
        imapHost: "imap.mail.yahoo.com",
        imapPort: 993,
        imapEncryption: .ssl,
        smtpHost: "smtp.mail.yahoo.com",
        smtpPort: 587,
        smtpEncryption: .starttls,
        authType: .appPassword,
        requiresAppPassword: true,
        appPasswordURL: "https://login.yahoo.com/account/security",
        setupNotes: String(localized: "provider.yahoo.note")
    )

    static let icloud = EmailProviderPreset(
        id: "icloud",
        name: "iCloud",
        icon: "icloud.fill",
        domains: ["icloud.com", "me.com", "mac.com"],
        imapHost: "imap.mail.me.com",
        imapPort: 993,
        imapEncryption: .ssl,
        smtpHost: "smtp.mail.me.com",
        smtpPort: 587,
        smtpEncryption: .starttls,
        authType: .appPassword,
        requiresAppPassword: true,
        appPasswordURL: "https://appleid.apple.com/account/manage",
        setupNotes: String(localized: "provider.icloud.note")
    )
}
