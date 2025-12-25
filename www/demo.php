<?php
/**
 * AILO App - Interactive Demo Browser
 * Ermöglicht das Durchblättern der App-Screens via Web
 */

// Screen-Konfiguration
$screens = [
    // Tab: Dashboard
    'dashboard' => [
        'title' => 'Dashboard',
        'image' => 'screens/dashboard.png',
        'tab' => 'dashboard',
        'hotspots' => [
            ['x' => 10, 'y' => 75, 'w' => 80, 'h' => 20, 'target' => 'dashboard-reminder', 'hint' => 'Erinnerung öffnen']
        ]
    ],
    'dashboard-reminder' => [
        'title' => 'Erinnerung',
        'image' => 'screens/dashboard-reminder.png',
        'tab' => 'dashboard',
        'back' => 'dashboard',
        'hotspots' => []
    ],

    // Tab: Mail
    'mail-list' => [
        'title' => 'Posteingang',
        'image' => 'screens/mail-list.png',
        'tab' => 'mail',
        'hotspots' => [
            ['x' => 5, 'y' => 25, 'w' => 90, 'h' => 12, 'target' => 'mail-detail', 'hint' => 'E-Mail öffnen', 'marker' => true]
        ]
    ],
    'mail-detail' => [
        'title' => 'E-Mail',
        'image' => 'screens/mail-detail.png',
        'tab' => 'mail',
        'back' => 'mail-list',
        'hotspots' => []
    ],
    'mail-compose' => [
        'title' => 'Neue E-Mail',
        'image' => 'screens/mail-compose.png',
        'tab' => 'mail',
        'back' => 'mail-list',
        'hotspots' => []
    ],
    'mail-folders' => [
        'title' => 'Ordner',
        'image' => 'screens/mail-folders.png',
        'tab' => 'mail',
        'back' => 'mail-list',
        'hotspots' => []
    ],

    // Tab: Logs
    'logs-list' => [
        'title' => 'Logs',
        'image' => 'screens/logs-list.png',
        'tab' => 'logs',
        'hotspots' => [
            ['x' => 5, 'y' => 30, 'w' => 90, 'h' => 15, 'target' => 'logs-detail', 'hint' => 'Eintrag öffnen']
        ]
    ],
    'logs-detail' => [
        'title' => 'Log-Eintrag',
        'image' => 'screens/logs-detail.png',
        'tab' => 'logs',
        'back' => 'logs-list',
        'hotspots' => []
    ],
    'logs-audio' => [
        'title' => 'Audio-Aufnahme',
        'image' => 'screens/logs-audio.png',
        'tab' => 'logs',
        'back' => 'logs-list',
        'hotspots' => []
    ],
    'logs-text' => [
        'title' => 'Text-Eintrag',
        'image' => 'screens/logs-text.png',
        'tab' => 'logs',
        'back' => 'logs-list',
        'hotspots' => []
    ],

    // Tab: Settings
    'settings' => [
        'title' => 'Einstellungen',
        'image' => 'screens/settings.png',
        'tab' => 'settings',
        'hotspots' => [
            ['x' => 5, 'y' => 20, 'w' => 90, 'h' => 8, 'target' => 'settings-mail', 'hint' => 'E-Mail-Konten'],
            ['x' => 5, 'y' => 30, 'w' => 90, 'h' => 8, 'target' => 'settings-ai', 'hint' => 'KI-Einstellungen']
        ]
    ],
    'settings-mail' => [
        'title' => 'E-Mail-Konten',
        'image' => 'screens/settings-mail.png',
        'tab' => 'settings',
        'back' => 'settings',
        'hotspots' => []
    ],
    'settings-ai' => [
        'title' => 'KI-Provider',
        'image' => 'screens/settings-ai.png',
        'tab' => 'settings',
        'back' => 'settings',
        'hotspots' => []
    ],
    'settings-prompts' => [
        'title' => 'Pre-Prompts',
        'image' => 'screens/settings-prompts.png',
        'tab' => 'settings',
        'back' => 'settings',
        'hotspots' => []
    ]
];

// Tab-Konfiguration
$tabs = [
    'dashboard' => ['icon' => '📊', 'label' => 'Dashboard', 'screen' => 'dashboard'],
    'mail' => ['icon' => '✉️', 'label' => 'Mail', 'screen' => 'mail-list'],
    'logs' => ['icon' => '📝', 'label' => 'Logs', 'screen' => 'logs-list'],
    'settings' => ['icon' => '⚙️', 'label' => 'Einstellungen', 'screen' => 'settings']
];

// Aktueller Screen
$currentScreen = isset($_GET['screen']) ? $_GET['screen'] : 'dashboard';
if (!isset($screens[$currentScreen])) {
    $currentScreen = 'dashboard';
}
$screen = $screens[$currentScreen];
$currentTab = $screen['tab'];
?>
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AILO App Demo – <?= htmlspecialchars($screen['title']) ?></title>
    <link rel="stylesheet" href="ailo-theme.css">
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Arial, sans-serif;
            background: linear-gradient(135deg, #0b1e46, #a83244);
            min-height: 100vh;
            display: flex;
            flex-direction: column;
            align-items: center;
            color: white;
        }

        /* Header */
        .demo-header {
            text-align: center;
            padding: 1.5rem 1rem;
            width: 100%;
            max-width: 1200px;
        }
        .demo-header h1 {
            font-size: 1.8rem;
            margin-bottom: 0.5rem;
        }
        .demo-header p {
            opacity: 0.8;
            font-size: 1rem;
        }

        /* Main Container */
        .demo-container {
            display: flex;
            gap: 3rem;
            align-items: flex-start;
            justify-content: center;
            padding: 1rem 2rem 3rem;
            flex-wrap: wrap;
            max-width: 1400px;
        }

        /* iPhone Frame */
        .iphone-frame {
            position: relative;
            width: 320px;
            height: 692px;
            background: #1a1a1a;
            border-radius: 50px;
            padding: 12px;
            box-shadow:
                0 0 0 3px #333,
                0 0 0 6px #1a1a1a,
                0 25px 50px rgba(0,0,0,0.5);
        }

        .iphone-notch {
            position: absolute;
            top: 12px;
            left: 50%;
            transform: translateX(-50%);
            width: 150px;
            height: 30px;
            background: #1a1a1a;
            border-radius: 0 0 20px 20px;
            z-index: 10;
        }

        .iphone-notch::before {
            content: '';
            position: absolute;
            top: 8px;
            left: 50%;
            transform: translateX(-50%);
            width: 60px;
            height: 6px;
            background: #333;
            border-radius: 3px;
        }

        .iphone-screen {
            position: relative;
            width: 100%;
            height: 100%;
            background: #000;
            border-radius: 40px;
            overflow: hidden;
        }

        .screen-content {
            position: relative;
            width: 100%;
            height: calc(100% - 70px);
            overflow: hidden;
        }

        .screen-image {
            width: 100%;
            height: 100%;
            object-fit: cover;
            object-position: top;
        }

        .screen-placeholder {
            width: 100%;
            height: 100%;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            background: linear-gradient(180deg, #1c1c1e, #2c2c2e);
            color: #888;
            text-align: center;
            padding: 2rem;
        }
        .screen-placeholder .icon { font-size: 4rem; margin-bottom: 1rem; }
        .screen-placeholder .text { font-size: 0.9rem; }

        /* Hotspots */
        .hotspot {
            position: absolute;
            cursor: pointer;
            transition: all 0.2s;
            border-radius: 8px;
        }
        .hotspot:hover {
            background: rgba(0, 199, 190, 0.3);
            box-shadow: 0 0 0 2px rgba(0, 199, 190, 0.6);
        }
        .hotspot.marker::after {
            content: '👆';
            position: absolute;
            right: -10px;
            top: 50%;
            transform: translateY(-50%);
            font-size: 1.2rem;
            animation: pulse 1.5s infinite;
        }
        @keyframes pulse {
            0%, 100% { opacity: 1; transform: translateY(-50%) scale(1); }
            50% { opacity: 0.7; transform: translateY(-50%) scale(1.2); }
        }

        /* Tab Bar */
        .tab-bar {
            position: absolute;
            bottom: 0;
            left: 0;
            right: 0;
            height: 70px;
            background: rgba(30, 30, 30, 0.95);
            backdrop-filter: blur(10px);
            display: flex;
            justify-content: space-around;
            align-items: center;
            padding: 0 10px 15px;
            border-top: 1px solid rgba(255,255,255,0.1);
        }

        .tab-item {
            display: flex;
            flex-direction: column;
            align-items: center;
            text-decoration: none;
            color: #888;
            font-size: 0.65rem;
            padding: 5px 12px;
            border-radius: 8px;
            transition: all 0.2s;
        }
        .tab-item:hover {
            color: #00c7be;
            background: rgba(0, 199, 190, 0.1);
        }
        .tab-item.active {
            color: #00c7be;
        }
        .tab-item .icon {
            font-size: 1.4rem;
            margin-bottom: 2px;
        }

        /* Back Button */
        .back-button {
            position: absolute;
            top: 50px;
            left: 15px;
            z-index: 20;
            background: rgba(0,0,0,0.5);
            border: none;
            color: #00c7be;
            font-size: 0.9rem;
            padding: 6px 12px;
            border-radius: 15px;
            cursor: pointer;
            text-decoration: none;
            display: flex;
            align-items: center;
            gap: 4px;
        }
        .back-button:hover {
            background: rgba(0,0,0,0.7);
        }

        /* Sidebar Info */
        .demo-sidebar {
            max-width: 400px;
            padding: 1.5rem;
            background: rgba(255,255,255,0.1);
            border-radius: 20px;
            backdrop-filter: blur(10px);
        }
        .demo-sidebar h2 {
            font-size: 1.4rem;
            margin-bottom: 1rem;
            color: #00c7be;
        }
        .demo-sidebar p {
            margin-bottom: 1rem;
            line-height: 1.6;
            opacity: 0.9;
        }
        .demo-sidebar ul {
            margin: 1rem 0;
            padding-left: 1.5rem;
        }
        .demo-sidebar li {
            margin: 0.5rem 0;
            opacity: 0.9;
        }

        /* Action Buttons */
        .action-buttons {
            display: flex;
            flex-direction: column;
            gap: 0.8rem;
            margin-top: 1.5rem;
        }
        .btn {
            display: inline-flex;
            align-items: center;
            justify-content: center;
            gap: 0.5rem;
            padding: 0.8rem 1.2rem;
            border-radius: 12px;
            text-decoration: none;
            font-weight: 600;
            transition: all 0.2s;
            text-align: center;
        }
        .btn-primary {
            background: #fff;
            color: #000;
        }
        .btn-primary:hover {
            background: #f0f0f0;
            transform: translateY(-2px);
        }
        .btn-secondary {
            background: rgba(255,255,255,0.15);
            color: #fff;
            border: 2px solid rgba(255,255,255,0.3);
        }
        .btn-secondary:hover {
            background: rgba(255,255,255,0.25);
            border-color: rgba(255,255,255,0.5);
        }

        /* Screen Navigation */
        .screen-nav {
            margin-top: 1.5rem;
            padding-top: 1.5rem;
            border-top: 1px solid rgba(255,255,255,0.2);
        }
        .screen-nav h3 {
            font-size: 1rem;
            margin-bottom: 0.8rem;
            opacity: 0.7;
        }
        .screen-links {
            display: flex;
            flex-wrap: wrap;
            gap: 0.5rem;
        }
        .screen-link {
            padding: 0.4rem 0.8rem;
            background: rgba(255,255,255,0.1);
            border-radius: 8px;
            color: #fff;
            text-decoration: none;
            font-size: 0.85rem;
            transition: all 0.2s;
        }
        .screen-link:hover {
            background: rgba(0, 199, 190, 0.3);
        }
        .screen-link.active {
            background: #00c7be;
            color: #000;
        }

        /* Footer */
        .demo-footer {
            text-align: center;
            padding: 2rem;
            opacity: 0.7;
            font-size: 0.9rem;
        }
        .demo-footer a {
            color: #00c7be;
            text-decoration: none;
        }

        /* Responsive */
        @media (max-width: 900px) {
            .demo-container {
                flex-direction: column;
                align-items: center;
            }
            .demo-sidebar {
                max-width: 320px;
            }
        }

        @media (max-width: 400px) {
            .iphone-frame {
                transform: scale(0.85);
                transform-origin: top center;
            }
        }
    </style>
</head>
<body>
    <header class="demo-header">
        <h1>📱 AILO App Demo</h1>
        <p>Entdecke die App interaktiv – klicke auf Elemente und navigiere durch die Tabs</p>
    </header>

    <div class="demo-container">
        <!-- iPhone Device -->
        <div class="iphone-frame">
            <div class="iphone-notch"></div>
            <div class="iphone-screen">
                <div class="screen-content">
                    <?php if (isset($screen['back'])): ?>
                        <a href="?screen=<?= $screen['back'] ?>" class="back-button">
                            ← Zurück
                        </a>
                    <?php endif; ?>

                    <?php if (file_exists($screen['image'])): ?>
                        <img src="<?= htmlspecialchars($screen['image']) ?>"
                             alt="<?= htmlspecialchars($screen['title']) ?>"
                             class="screen-image">
                    <?php else: ?>
                        <div class="screen-placeholder">
                            <div class="icon">📱</div>
                            <div class="text">
                                <strong><?= htmlspecialchars($screen['title']) ?></strong><br><br>
                                Screenshot wird geladen...<br>
                                <small style="opacity:0.6"><?= htmlspecialchars($screen['image']) ?></small>
                            </div>
                        </div>
                    <?php endif; ?>

                    <!-- Hotspots -->
                    <?php foreach ($screen['hotspots'] as $hotspot): ?>
                        <a href="?screen=<?= $hotspot['target'] ?>"
                           class="hotspot <?= isset($hotspot['marker']) && $hotspot['marker'] ? 'marker' : '' ?>"
                           style="left: <?= $hotspot['x'] ?>%; top: <?= $hotspot['y'] ?>%; width: <?= $hotspot['w'] ?>%; height: <?= $hotspot['h'] ?>%;"
                           title="<?= htmlspecialchars($hotspot['hint']) ?>">
                        </a>
                    <?php endforeach; ?>
                </div>

                <!-- Tab Bar -->
                <nav class="tab-bar">
                    <?php foreach ($tabs as $tabId => $tab): ?>
                        <a href="?screen=<?= $tab['screen'] ?>"
                           class="tab-item <?= $currentTab === $tabId ? 'active' : '' ?>">
                            <span class="icon"><?= $tab['icon'] ?></span>
                            <span><?= $tab['label'] ?></span>
                        </a>
                    <?php endforeach; ?>
                </nav>
            </div>
        </div>

        <!-- Sidebar -->
        <aside class="demo-sidebar">
            <h2><?= htmlspecialchars($screen['title']) ?></h2>

            <?php if ($currentTab === 'dashboard'): ?>
                <p>Das Dashboard zeigt dir auf einen Blick deine wichtigsten Informationen:</p>
                <ul>
                    <li>Anstehende Erinnerungen</li>
                    <li>Letzte Einträge (Text & Audio)</li>
                    <li>Schnellzugriff auf alle Funktionen</li>
                </ul>
            <?php elseif ($currentTab === 'mail'): ?>
                <p>Der vollwertige E-Mail-Client unterstützt:</p>
                <ul>
                    <li>IMAP/POP3 Konten</li>
                    <li>Mehrere Accounts gleichzeitig</li>
                    <li>Rich-Text E-Mails mit Anhängen</li>
                    <li>KI-gestützte Textgenerierung</li>
                </ul>
            <?php elseif ($currentTab === 'logs'): ?>
                <p>Verwalte deine Notizen und Aufnahmen:</p>
                <ul>
                    <li>Text- und Audio-Einträge</li>
                    <li>Live-Transkription bei Sprachaufnahmen</li>
                    <li>KI-Überarbeitung von Texten</li>
                    <li>Kategorien und Tags</li>
                </ul>
            <?php elseif ($currentTab === 'settings'): ?>
                <p>Konfiguriere AILO nach deinen Wünschen:</p>
                <ul>
                    <li>E-Mail-Konten verwalten</li>
                    <li>KI-Provider einrichten</li>
                    <li>Pre-Prompts definieren</li>
                    <li>Aufnahme-Einstellungen</li>
                </ul>
            <?php endif; ?>

            <div class="action-buttons">
                <a href="https://testflight.apple.com/join/a1WE6GrB" class="btn btn-primary" target="_blank">
                    📱 TestFlight Beta beitreten
                </a>
                <a href="docs/ailo-handbuch.pdf" class="btn btn-secondary" target="_blank">
                    📖 Handbuch (PDF)
                </a>
                <a href="docs/ailo-kurzanleitung.pdf" class="btn btn-secondary" target="_blank">
                    📄 Kurzanleitung (PDF)
                </a>
                <a href="index.html" class="btn btn-secondary">
                    🏠 Zur Startseite
                </a>
            </div>

            <!-- Quick Navigation -->
            <div class="screen-nav">
                <h3>Alle Screens</h3>
                <div class="screen-links">
                    <?php foreach ($screens as $screenId => $screenData): ?>
                        <a href="?screen=<?= $screenId ?>"
                           class="screen-link <?= $currentScreen === $screenId ? 'active' : '' ?>">
                            <?= htmlspecialchars($screenData['title']) ?>
                        </a>
                    <?php endforeach; ?>
                </div>
            </div>
        </aside>
    </div>

    <footer class="demo-footer">
        <p>&copy; 2025 <a href="index.html">AILO.network</a> – Alle Rechte vorbehalten</p>
    </footer>
</body>
</html>
