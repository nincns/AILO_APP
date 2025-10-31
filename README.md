# AILO

**AI-powered communication and documentation tool for iOS**

AILO ist eine native iOS-App, die KI-Unterstützung für die Verwaltung von Notizen, E-Mails und Audio-Logs bereitstellt. Die App kombiniert klassische Produktivitätsfunktionen mit intelligenter Textverarbeitung und Spracherkennung.

---

## Features

### 📝 Schreiben (Write)
- Schnelle Texteingabe mit Kategorisierung
- Tags und Erinnerungen
- E-Mail-Import zum direkten Übernehmen von Inhalten
- Markdown-Unterstützung

### 🎙️ Sprechen (Speak)
- Audio-Aufnahme mit Live-Transkription
- Automatische Spracherkennung (deutsch/englisch)
- Speicherung von Audio + Transkript

### 📓 Logs
- Zentrale Übersicht aller Einträge (Text + Audio)
- Volltextsuche
- Export-Funktionen
- KI-basierte Überarbeitung gespeicherter Texte

### 📧 E-Mail Integration
- IMAP/SMTP-Unterstützung
- Multi-Account-Verwaltung
- Posteingang direkt in der App
- E-Mails als Log-Einträge speichern

### 🤖 KI-Integration
- OpenAI und Ollama Support
- Konfigurierbare Pre-Prompts
- Automatische Textverbesserung
- Mehrere Provider parallel nutzbar

### 🎯 Dashboard
- Übersicht kürzlich hinzugefügter Einträge
- Schnellzugriff auf häufig genutzte Funktionen

---

## Technologie-Stack

- **Plattform:** iOS 16+, macOS 13+ (Catalyst)
- **Sprache:** Swift 5.9+
- **Framework:** SwiftUI
- **Datenbank:** SwiftData
- **Audio:** AVFoundation, Speech Framework
- **Netzwerk:** URLSession, SwiftNIO (SMTP/IMAP)
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
git clone https://github.com/[username]/AILO.git
cd AILO
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

---

## Projekt-Struktur

```
AILO_APP/
├── App/                    # App-Entry & Navigation
├── Features/               # Feature-Module
│   ├── Dashboard/
│   ├── Logs/
│   ├── Mail/
│   ├── Schreiben/
│   └── Sprechen/
├── Services/              # Business Logic
│   ├── AI/               # KI-Integration
│   ├── Audio/            # Audio-Recording
│   └── Mail/             # IMAP/SMTP
├── Database/             # SwiftData Models & DAOs
├── Configuration/        # Settings & Language
├── Helpers/              # Utilities & Parsers
└── Views/                # Shared UI-Components
```

---

## Lokalisierung

- **Deutsch** (primär)
- **Englisch** (vollständig)

Lokalisierungsdateien: `Configuration/Language/`

---

## Sicherheit & Datenschutz

- Alle API-Keys und Passwörter werden im Keychain gespeichert
- E-Mail-Credentials verschlüsselt
- Lokale Datenspeicherung (keine Cloud-Synchronisation)
- Audio-Dateien bleiben auf dem Gerät

---

## Roadmap

- [ ] iCloud-Synchronisation (optional)
- [ ] Weitere KI-Provider (Anthropic Claude, etc.)
- [ ] Export-Formate (PDF, Markdown)
- [ ] Widget-Support
- [ ] Siri-Shortcuts
- [ ] macOS native App (ohne Catalyst)

---

## Lizenz

[MIT License](LICENSE) *(oder andere Lizenz nach Wunsch)*

---

## Beitragen

Contributions sind willkommen! Bitte erst ein Issue erstellen, bevor größere Pull Requests eingereicht werden.

1. Fork erstellen
2. Feature-Branch erstellen (`git checkout -b feature/AmazingFeature`)
3. Commit (`git commit -m 'Add some AmazingFeature'`)
4. Push (`git push origin feature/AmazingFeature`)
5. Pull Request öffnen

---

## Support

Bei Fragen oder Problemen bitte ein [Issue](https://github.com/[username]/AILO/issues) erstellen.

---

**Made with ❤️ for productive workflows**
