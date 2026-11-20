import Foundation

/// Имена проектов для HUD: полное имя и короткая метка под иконкой агента.
/// Когда все сессии — один агент (иконки одинаковые), отличать их приходится по проекту.
public enum ProjectNames {
    /// Безликие имена папок: для них показываем и родительскую папку («hrm/front»).
    static let generic: Set<String> = [
        "front", "frontend", "back", "backend", "app", "apps", "web", "client", "server", "src",
        "mobile", "api", "ui", "packages", "main", "admin", "site",
    ]

    public static func displayName(cwd: String) -> String {
        // Пустой путь URL превратил бы в текущую папку процесса.
        guard !cwd.isEmpty else { return "" }
        let url = URL(fileURLWithPath: cwd)
        let base = url.lastPathComponent
        guard !base.isEmpty, base != "/" else { return cwd }
        if generic.contains(base.lowercased()) {
            let parent = url.deletingLastPathComponent().lastPathComponent
            if !parent.isEmpty, parent != "/" { return parent + "/" + base }
        }
        return base
    }

    static func tokens(_ name: String) -> [String] {
        name.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Короткие метки для набора проектов: общий для всех префикс отбрасывается
    /// («acme-mobile-app», «acme-web-client» → «mobile», «web»), совпадения уточняются следующим словом.
    public static func shortLabels(for cwds: [String], maxLength: Int = 9) -> [String: String] {
        let unique = Array(Set(cwds.filter { !$0.isEmpty })).sorted()
        var names: [String: [String]] = [:]
        for c in unique {
            let t = tokens(displayName(cwd: c))
            names[c] = t.isEmpty ? [displayName(cwd: c).lowercased()] : t
        }
        guard unique.count > 1 else {
            return Dictionary(uniqueKeysWithValues: unique.map { ($0, clip(names[$0]!.joined(separator: "-"), maxLength)) })
        }
        // Общий префикс из целых слов, но у каждого имени остаётся хотя бы одно слово.
        while let first = names.values.first?.first,
              names.values.allSatisfy({ $0.count > 1 && $0.first == first }) {
            for k in names.keys { names[k]!.removeFirst() }
        }
        var taken = Array(repeating: 1, count: unique.count)
        func label(_ i: Int) -> String { names[unique[i]]!.prefix(taken[i]).joined(separator: "-") }
        // Уточняем, пока есть совпадения и есть чем уточнять. Совпавшие уточняются одновременно,
        // иначе первая метка уйдёт вперёд, а вторая останется короткой.
        for _ in 0..<4 {
            let current = unique.indices.map(label)
            let clashing = unique.indices.filter { i in
                unique.indices.contains { $0 != i && current[$0] == current[i] } && taken[i] < names[unique[i]]!.count
            }
            if clashing.isEmpty { break }
            for i in clashing { taken[i] += 1 }
        }
        return Dictionary(uniqueKeysWithValues: unique.indices.map { (unique[$0], clip(label($0), maxLength)) })
    }

    static func clip(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n - 1)) + "…" : s
    }

    /// Стабильный оттенок цвета проекта (0…1) — один и тот же в HUD, панели и на карте.
    public static func hue(cwd: String) -> Double {
        Double(stableHash("project:" + cwd) % 360) / 360
    }
}
