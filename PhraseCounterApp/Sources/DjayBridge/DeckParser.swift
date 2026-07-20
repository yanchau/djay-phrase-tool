import ApplicationServices

// MARK: - Find Decks group

public func findDecksGroup(_ app: AXUIElement) -> AXUIElement? {
    for window in getChildren(app) {
        for child in getChildren(window) {
            let label = getLabel(child) ?? ""
            let title = getTitle(child) ?? ""
            if label == "Decks" || title == "Decks" {
                return child
            }
        }
    }
    return nil
}

// MARK: - Parse deck number from label

/// Extracts the deck number from labels like "Key, Deck 1" → 1
/// Also handles djay Pro's French UI, where deck labels use "Platine N" instead of "Deck N".
public func parseDeckNumber(from label: String) -> Int? {
    for keyword in ["Deck", "Platine"] {
        guard let range = label.range(of: "\(keyword) (\\d+)", options: .regularExpression) else {
            continue
        }
        let numberStr = label[range].dropFirst(keyword.count + 1) // drop "Deck " / "Platine "
        return Int(numberStr)
    }
    return nil
}

// MARK: - Get deck info (used by Reader)

func findLabeledElements(_ element: AXUIElement, prefix: String, depth: Int = 0) -> [String: String] {
    var results: [String: String] = [:]

    let label = getLabel(element) ?? ""
    let value = getValue(element) ?? getTitle(element) ?? ""

    if !label.isEmpty && label.contains(prefix) && !value.isEmpty {
        results[label] = value
    }

    if depth < 6 {
        for child in getChildren(element) {
            let childResults = findLabeledElements(child, prefix: prefix, depth: depth + 1)
            results.merge(childResults) { _, new in new }
        }
    }

    return results
}

/// Extracts the property name from a label like "Key, Deck 1" → "Key"
/// Also handles djay Pro's French UI ("Clé, Platine 1" → "Clé").
private func labelPrefix(_ label: String) -> String {
    for suffix in [", Deck ", ", Platine "] {
        if let commaRange = label.range(of: suffix) {
            return String(label[label.startIndex..<commaRange.lowerBound])
        }
    }
    return label
}

public func getDeckInfo(app: AXUIElement, deckNumber: Int) -> DeckInfo {
    // djay Pro's French UI labels decks "Platine N" instead of "Deck N".
    var allElements = findLabeledElements(app, prefix: "Deck \(deckNumber)")
    allElements.merge(findLabeledElements(app, prefix: "Platine \(deckNumber)")) { _, new in new }

    var info = DeckInfo()
    for (label, value) in allElements {
        let lower = label.lowercased()
        let prop = labelPrefix(label)

        if lower.starts(with: "key,") || lower.starts(with: "clé,") { info.key = value }
        else if lower.starts(with: "title,") || lower.starts(with: "titre,") { info.title = value }
        else if lower.starts(with: "artist,") || lower.starts(with: "artiste,") { info.artist = value }
        else if lower.starts(with: "elapsed time,") { info.elapsedTime = value }
        else if lower.starts(with: "remaining time,") { info.remainingTime = value }
        else if lower.starts(with: "play /") { info.isPlaying = (value == "Active") }
        // Value-as-label: BPM is a numeric label like "124.0, Deck 1"
        else if prop.range(of: #"^\d+\.\d+$"#, options: .regularExpression) != nil {
            info.bpm = prop
        }
        // Value-as-label: BPM% is a percentage label like "+7.3%, Deck 1" or "-2.0%, Deck 1"
        else if prop.range(of: #"^[+-]?\d+\.\d+%$"#, options: .regularExpression) != nil {
            info.bpmPercent = prop
        }
        else if lower.starts(with: "line volume,") { info.lineVolume = value }
    }
    return info
}

// MARK: - Get crossfader (global, not per-deck)

public func getCrossfader(app: AXUIElement) -> String? {
    let elements = findLabeledElements(app, prefix: "Crossfader")
    return elements.first(where: { $0.key == "Crossfader" })?.value
}

// MARK: - Get all elements (used by Dump)

public func getAllElements(decksGroup: AXUIElement) -> [String: [ElementInfo]] {
    var result: [String: [ElementInfo]] = [:]

    for child in getChildren(decksGroup) {
        let label = getLabel(child) ?? ""
        guard !label.isEmpty else { continue }

        let element = ElementInfo(
            label: label,
            role: getRole(child),
            value: getValue(child) ?? getTitle(child),
            subrole: getAttr(child, "AXSubrole") as? String
        )

        let deckKey: String
        if let deckNumber = parseDeckNumber(from: label) {
            deckKey = "\(deckNumber)"
        } else {
            deckKey = "other"
        }

        result[deckKey, default: []].append(element)
    }

    return result
}
