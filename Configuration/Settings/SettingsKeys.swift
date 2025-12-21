import Foundation

// Zentrale UserDefaults-Keys
// AI-Server/Modelle
let kAIServerAddress      = "config.ai.server.address"
let kAIServerPort         = "config.ai.server.port"      // leer -> 443
let kAIAPIKey             = "config.ai.server.apikey"
let kAIModel              = "config.ai.server.model"
let kAIPrePrompt          = "config.ai.preprompt"

// Pre-Prompt Presets
let kAIPresetsKey         = "config.ai.preprompts"           // JSON [AIPrePromptPreset]
let kAISelectedPresetKey  = "config.ai.preprompt.selected"   // UUID().uuidString
let kPrePromptMenuKey     = "config.ai.preprompt.menu"       // JSON [PrePromptMenuItem]
let kPrePromptRecipesKey  = "config.ai.preprompt.recipes"    // JSON [PrePromptRecipe]
let kRecipeMenuKey        = "config.ai.preprompt.recipemenu" // JSON [RecipeMenuItem] - Kochbuch-Struktur

// Schreiben/Kategorien
let kCategories           = "config.categories"

// Mikro/Transkription
let kMicSensitivity       = "config.mic.sensitivity"    // Double 0...1
let kSilenceThreshold     = "config.mic.silenceDB"      // Double -60...0 dB
let kChunkSeconds         = "config.mic.chunkSeconds"   // Double 1...10
let kSpeechLang           = "config.speech.lang"        // z.B. "de-DE"
