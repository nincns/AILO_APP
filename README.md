# AILO

**AI-powered communication and documentation tool for iOS**

AILO ist eine native iOS-App, die KI-Unterstützung für die Verwaltung von Notizen, E-Mails und Audio-Logs bereitstellt. Die App kombiniert klassische Produktivitätsfunktionen mit intelligenter Textverarbeitung und Spracherkennung.

**Website:** [ailo.network](https://ailo.network)
**Beta-Test:** [TestFlight beitreten](https://testflight.apple.com/join/a1WE6GrB)

---

## Features

### 📊 Dashboard
- Übersicht anstehender Erinnerungen
- Schnellzugriff auf kürzlich hinzugefügte Einträge
- Zentrale Navigation zu allen Funktionen

### ✉️ E-Mail Client
- Vollwertiger IMAP/SMTP-Client
- Multi-Account-Verwaltung
- Rich-Text-Editor mit Anhängen
- KI-gestützte Textgenerierung beim Verfassen
- Badge zeigt ungelesene Nachrichten (App Icon + Tab Bar)
- Automatische Gelesen/Ungelesen-Synchronisation
- Ordner-Verwaltung (INBOX, Gesendet, Entwürfe, etc.)

### 📝 Logs
- Text- und Audio-Einträge erstellen
- Live-Transkription bei Sprachaufnahmen
- KI-Überarbeitung von Texten
- Kategorien, Tags und Erinnerungen
- Per Swipe direkt als E-Mail versenden
- Volltextsuche über alle Einträge

### 🎙️ Audio-Aufnahmen
- Hochwertige Audio-Aufnahme
- Automatische Spracherkennung (deutsch/englisch)
- Echtzeit-Transkription
- Speicherung von Audio + Transkript

### 🤖 KI-Integration
- **OpenAI** (GPT-4, GPT-3.5, etc.)
- **Ollama** (lokale Modelle)
- **Eigene Server** (kompatible API)
- Pre-Prompt-Katalog ("Kochbuch") für häufige Anweisungen
- Automatische Textverbesserung
- Mehrere Provider parallel nutzbar

### ⚙️ Einstellungen
- E-Mail-Konten konfigurieren (IMAP/SMTP)
- KI-Provider verwalten
- Pre-Prompts als Kochbuch organisieren
- Eigene Kategorien für Logs definieren
- Auto-Mark-As-Read Toggle

---

## Technologie-Stack

- **Plattform:** iOS 16+, macOS 13+ (Catalyst)
- **Sprache:** Swift 5.9+
- **Framework:** SwiftUI
- **Datenbank:** SwiftData
- **Audio:** AVFoundation, Speech Framework
- **Netzwerk:** SwiftNIO (SMTP/IMAP), URLSession
- **Sicherheit:** Keychain für sensible Daten

---

## Installation

### Voraussetzungen
- Xcode 15.0+
- iOS 16+ Deployment Target
- Apple Developer Account (für Geräte-Testing)

### Setup

1. Repository klonen:
```bash
git clone https://github.com/nincns/AILO_APP.git
cd AILO_APP
```

2. Projekt in Xcode öffnen:
```bash
open AILO_APP.xcodeproj
```

3. Dependencies sind bereits im Projekt integriert (keine externen Package Manager erforderlich)

4. Build und Run in Xcode (⌘R)

---

## Konfiguration

### KI-Provider einrichten

**OpenAI:**
1. Settings → KI-Provider → Provider hinzufügen
2. Typ: OpenAI
3. API-Key eintragen
4. Modell auswählen (z.B. `gpt-4`)

**Ollama (lokal):**
1. Ollama lokal starten
2. Settings → KI-Provider → Provider hinzufügen
3. Typ: Ollama
4. Server-Adresse: `http://localhost:11434`
5. Modell auswählen

### E-Mail-Konto hinzufügen

1. Settings → E-Mail-Konten → Konto hinzufügen
2. IMAP/SMTP-Zugangsdaten eingeben
3. Verbindung testen
4. Ordner-Zuordnung (Posteingang, Gesendet, etc.)

**Hinweis:** Für Gmail/Outlook App-Passwörter statt normaler Passwörter verwenden.

---

## Projekt-Struktur

```
AILO_APP/
├── App/                    # App-Entry & Navigation
├── Views/                  # UI-Komponenten
│   ├── Dashboard/
│   ├── Mail/
│   ├── LogsList/
│   ├── Schreiben/
│   ├── Sprechen/
│   └── Config/
├── Services/              # Business Logic
│   ├── AppBadgeManager    # App Icon Badge
│   ├── AI/                # KI-Integration
│   ├── Audio/             # Audio-Recording
│   └── Mail/              # IMAP/SMTP
├── Database/              # SwiftData Models & DAOs
├── Configuration/         # Settings & Language
├── Helpers/               # Utilities & Parsers
│   └── Utilities/         # IMAP Parser, Mail Transport
├── www/                   # Website (ailo.network)
│   ├── index.html         # Landing Page
│   ├── demo.php           # Interaktive Demo
│   └── docs/              # PDF-Dokumentation
└── scripts/               # Build & Deploy Scripts
```

---

## Web-Demo

Eine interaktive Demo der App ist unter [ailo.network/demo.php](https://ailo.network/demo.php) verfügbar.

Die Demo zeigt alle Hauptbereiche der App mit navigierbaren Screenshots.

---

## Lokalisierung

- **Deutsch** (primär)
- **Englisch** (vollständig)

Lokalisierungsdateien: `Configuration/Language/`

---

## Sicherheit & Datenschutz

- Alle API-Keys und Passwörter werden im iOS Keychain gespeichert
- E-Mail-Credentials verschlüsselt
- Lokale Datenspeicherung (keine Cloud-Synchronisation)
- Audio-Dateien bleiben auf dem Gerät
- Keine Tracking- oder Analytics-Dienste

---

## Changelog (Neueste Änderungen)

### Version 1.0 Beta
- App Icon Badge für ungelesene E-Mails
- Teal-farbiges Tab Bar Badge
- Log-Einträge direkt als E-Mail versenden (integrierter Composer)
- Verbesserte IMAP-Performance (optimiertes Parsing)
- Read/Unread-Status Synchronisation mit Server
- Auto-Mark-As-Read Option
- Pre-Prompt "Kochbuch" für KI-Anweisungen
- Interaktive Web-Demo

---

## Roadmap

- [ ] iCloud-Synchronisation (optional)
- [ ] Weitere KI-Provider (Anthropic Claude, etc.)
- [ ] Export-Formate (PDF, Markdown)
- [ ] Widget-Support
- [ ] Siri-Shortcuts
- [ ] Push-Notifications für neue E-Mails
- [ ] macOS native App (ohne Catalyst)

---

## Lizenz

Proprietär - Alle Rechte vorbehalten.

---

## Support

- **TestFlight:** Feedback-Funktion in der App nutzen
- **E-Mail:** [support@ailo.network](mailto:support@ailo.network)
- **Issues:** [GitHub Issues](https://github.com/nincns/AILO_APP/issues)

---

**Made with ❤️ for productive workflows**

© 2025 AILO.network
