pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common

Singleton {
    id: root

    property var translations: ({})
    property var generatedTranslations: ({})
    property var availableLanguages: ["en_US"]
    property var availableGeneratedLanguages: []
    property var allAvailableLanguages: {
        const combined = new Set([...root.availableLanguages, ...root.availableGeneratedLanguages]);
        return Array.from(combined).sort();
    }
    property bool isScanning: scanLanguagesProcess.running
    property string translationKeepSuffix: "/*keep*/"
    property string translationsDir: Quickshell.shellPath("translations")
    property string generatedTranslationsDir: Directories.shellConfig + "/translations"

    property string languageCode: {
        var configLang = Config?.options.language.ui ?? "auto";

        if (configLang !== "auto")
            return configLang;

        return Qt.locale().name;
    }

    TranslationScanner {
        id: scanLanguagesProcess
        translationsDir: root.translationsDir
        onLanguagesScanned: (languages) => {
            root.availableLanguages = [...languages];
        }
    }

    TranslationScanner {
        id: scanGeneratedLanguagesProcess
        translationsDir: root.generatedTranslationsDir
        onLanguagesScanned: (languages) => {
            root.availableGeneratedLanguages = [...languages];
        }
    }

    // A regional variant had no table at all: the readers asked for <code>.json and gave up, so
    // en_GB, pt_PT, zh_TW and the rest loaded nothing and every tr() returned its source key.
    // Exact code first, so an en_GB.json added later still wins; then any shipped language with
    // the same prefix (pt_PT -> pt_BR); then en_US.
    function candidatesFor(code) {
        const out = [code];
        const prefix = code.split("_")[0];
        for (const lang of root.availableLanguages) {
            if (lang.split("_")[0] === prefix && !out.includes(lang))
                out.push(lang);
        }
        if (!out.includes("en_US"))
            out.push("en_US");
        return out;
    }

    onLanguageCodeChanged: {
        print("[Translation] Language changed to", root.languageCode);
        translationFileView.languageCode = root.languageCode;
        generatedTranslationFileView.languageCode = root.languageCode;
        translationFileView.reread();
        generatedTranslationFileView.reread();
    }

    // The scanner answers after the first read, and it is the only thing that can tell the chain
    // that a same-language table (pt_BR for a pt_PT user) exists at all.
    onAvailableLanguagesChanged: {
        translationFileView.reread();
        generatedTranslationFileView.reread();
    }

    TranslationReader {
        id: translationFileView
        translationsDir: root.translationsDir
        languageCode: root.languageCode
        onContentLoaded: (data) => {
            root.translations = data;
        }
    }

    TranslationReader {
        id: generatedTranslationFileView
        translationsDir: root.generatedTranslationsDir
        languageCode: root.languageCode
        onContentLoaded: (data) => {
            root.generatedTranslations = data;
        }
    }

    function tr(text) {
        // Special cases
        if (!text) return "";
        var key = text.toString();
        if (!root?.translations?.hasOwnProperty(key) && !root?.generatedTranslations?.hasOwnProperty(key))
            return key;
        
        // Normal cases
        var translation = root.translations[key] || root.generatedTranslations[key] || key;
        // print(key, "-> [", root.translations[key], root.generatedTranslations[key], key, "] ->", translation);
        if (translation.endsWith(root.translationKeepSuffix)) {
            translation = translation.substring(0, translation.length - root.translationKeepSuffix.length).trim();
        }
        return translation;
    }

    component TranslationScanner: Process {
        id: translationScanner
        required property string translationsDir
        signal languagesScanned(var languages)

        command: ["find", translationScanner.translationsDir, "-name", "*.json", "-printf", "%f\\n"]
        running: true

        stdout: StdioCollector {
            id: languagesCollector
            onStreamFinished: {
                const output = languagesCollector.text;
                const files = output.trim().split('\n').map(f => f.trim().replace(/\.json$/, "")).filter(f => f.length > 0);
                translationScanner.languagesScanned(files);
            }
        }

        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                translationScanner.languagesScanned(["en_US"]);
            }
        }
    }

    component TranslationReader: FileView {
        id: translationReader
        required property string translationsDir
        property string languageCode: root.languageCode
        property int candidate: 0
        signal contentLoaded(var data)

        // Every candidate but the last is meant to miss, so a miss is not an error to report.
        printErrors: false

        function reread() { // Proper reload in case the file was incorrect before
            translationReader.candidate = 0;
            translationReader.loadCandidate();
        }
        function loadCandidate() {
            const candidates = root.candidatesFor(translationReader.languageCode);
            translationReader.path = "";
            if (translationReader.candidate >= candidates.length) {
                translationReader.contentLoaded({});
                return;
            }
            translationReader.path = `${translationReader.translationsDir}/${candidates[translationReader.candidate]}.json`;
            translationReader.reload();
        }
        path: ""

        onLoaded: {
            var textContent = "";
            try {
                textContent = text();
                var jsonData = JSON.parse(textContent);
                translationReader.contentLoaded(jsonData);
            } catch (e) {
                console.log("[Translation] Failed to load translations:", e);
                translationReader.contentLoaded({});
            }
        }
        onLoadFailed: error => {
            // The blank path loadCandidate() sets between reads is not a candidate miss.
            if (translationReader.path.length === 0) return;
            translationReader.candidate++;
            translationReader.loadCandidate();
        }
    }
}
