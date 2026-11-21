import Foundation

/// Parsing of the model's replies; a line-for-line port of agent.py (parse_command, parse_actions, parse_plan).
enum Actions {
    struct ParseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Bookkeeping keys that are not part of the action itself.
    static let meta: Set<String> = ["t", "thought", "thought_zh", "think_s", "act_s", "shot", "_shot", "changed"]

    /// action name -> argument names; numeric arguments are 0-1000 screen coordinates
    static let actions: [String: [String]] = [
        "tap": ["x", "y"], "swipe": ["x1", "y1", "x2", "y2"], "circle": ["x", "y", "r"], "path": ["points"],
        "type": ["text"], "key": ["combo"], "done": ["answer"], "fail": ["reason"],
        "home": [], "back": [], "wait": [], "replan": [],
    ]
    static let textArgs: Set<String> = ["text", "combo", "answer", "reason"]

    /// One DO line, e.g. "tap 152 362" -> {"action": "tap", "x": 152, "y": 362}.
    static func parseCommand(_ line: String) throws -> JObject {
        let (head, rest) = partition(line.trimmingCharacters(in: .whitespacesAndNewlines))
        let name = head.lowercased()
        guard let keys = actions[name] else { throw ParseError(message: "unknown action: \(line.prefix(100))") }
        if let first = keys.first, textArgs.contains(first) {
            let text = rest.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return ["action": .str(name), first: .str(text)]
        }
        let fields = rest.split(whereSeparator: \.isWhitespace)
        let coords = name == "tap" && fields.last?.lowercased() == "precise" ? fields.dropLast() : fields[...]
        let numbers = try coords.map { field -> Int in
            guard let value = Double(field), value.isFinite, (0...1000).contains(value) else {
                throw ParseError(message: "coordinates must be numbers in 0...1000")
            }
            return Int(value)
        }
        if keys == ["points"] {
            guard numbers.count >= 4, numbers.count % 2 == 0 else {
                throw ParseError(message: "path needs 2+ x y pairs: \(line.prefix(100))")
            }
            let points = stride(from: 0, to: numbers.count, by: 2).prefix(20)
                .map { JValue.arr([.int(numbers[$0]), .int(numbers[$0 + 1])]) }
            return ["action": .str(name), "points": .arr(Array(points))]
        }
        guard numbers.count == keys.count else {
            throw ParseError(message: "\(name) needs \(keys.count) numbers: \(line.prefix(100))")
        }
        var action: JObject = ["action": .str(name)]
        for (k, n) in zip(keys, numbers) { action[k] = .int(n) }
        if name == "tap" && fields.last?.lowercased() == "precise" { action["precise"] = .bool(true) }
        return action
    }

    /// Parse a THINK / DO… reply (an optional ZH line is kept); the thought goes on the first action.
    static func parseActions(_ text: String) throws -> [JObject] {
        let thought = firstGroup(#"^\s*THINK\s*[:：]\s*(.*?)\s*$"#, in: text, multiline: true)
        let zh = firstGroup(#"^\s*ZH\s*[:：]\s*(.*?)\s*$"#, in: text, multiline: true)
        var acts = try allGroups(#"^\s*DO\s*[:：]\s*(.*?)\s*$"#, in: text).map(parseCommand).prefix(6).map { $0 }
        guard !acts.isEmpty else { throw ParseError(message: "no DO line in reply: \(text.prefix(200))") }
        acts[0] = JObject([("thought", .str(thought ?? "")), ("thought_zh", .str(zh ?? ""))]).merging(acts[0])
        return acts
    }

    /// Split an optional EN: / ZH: plan reply; a plain reply is used for both.
    static func parsePlan(_ text: String) -> (String, String) {
        let re = try! NSRegularExpression(pattern: #"EN\s*[:：](.*?)ZH\s*[:：](.*)"#,
                                          options: [.dotMatchesLineSeparators, .caseInsensitive])
        let ns = text as NSString
        if let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            return (trim(ns.substring(with: m.range(at: 1))), trim(ns.substring(with: m.range(at: 2))))
        }
        return (trim(text), trim(text))
    }

    /// The action itself, without thoughts, timings and other bookkeeping.
    static func key(_ step: JObject) -> JObject { step.without(meta) }

    /// The same move: same action and arguments, except that 0–1000 coordinates may differ by up to `slack`.
    /// The actor often nudges a target by a few units and repeats the same miss, which an exact match misses.
    static func sameMove(_ a: JObject, _ b: JObject, slack: Double = 25) -> Bool {
        guard a["action"] == b["action"] else { return false }
        let name = a["action"]?.str ?? ""
        // A swipe is the same gesture when it goes the same way over a similar distance. The model routinely
        // retries an ineffective swipe with a slightly different y (450, 500, 600, 700); comparing coordinates
        // would never call that a repeat and the run burns its whole step budget on it.
        if name == "swipe", let swipe = swipeShape(a), let other = swipeShape(b) {
            return swipe.horizontal == other.horizontal && swipe.sign == other.sign
                && abs(swipe.span - other.span) <= max(slack * 4, swipe.span * 0.5)
        }
        for arg in actions[name] ?? [] {
            if let x = a[arg]?.double, let y = b[arg]?.double {
                if abs(x - y) > slack { return false }
            } else if a[arg] != b[arg] {
                return false
            }
        }
        return true
    }

    /// Dominant axis, its direction and the travel distance of a swipe, in model grid units.
    private static func swipeShape(_ o: JObject) -> (horizontal: Bool, sign: Int, span: Double)? {
        guard let x1 = o["x1"]?.double, let y1 = o["y1"]?.double,
              let x2 = o["x2"]?.double, let y2 = o["y2"]?.double else { return nil }
        let dx = x2 - x1, dy = y2 - y1
        let horizontal = abs(dx) >= abs(dy)
        let primary = horizontal ? dx : dy
        guard abs(primary) >= 40 else { return nil }  // too short to be a scroll
        return (horizontal, primary < 0 ? -1 : 1, abs(primary))
    }

    // MARK: - helpers

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func partition(_ s: String) -> (String, String) {
        guard let i = s.firstIndex(of: " ") else { return (s, "") }
        return (String(s[..<i]), String(s[s.index(after: i)...]))
    }

    private static func regex(_ p: String, multiline: Bool) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: multiline ? [.anchorsMatchLines, .caseInsensitive] : [])
    }

    private static func firstGroup(_ p: String, in s: String, multiline: Bool) -> String? {
        let ns = s as NSString
        guard let m = regex(p, multiline: multiline).firstMatch(in: s, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func allGroups(_ p: String, in s: String) -> [String] {
        let ns = s as NSString
        return regex(p, multiline: true).matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }
}

/// Screen points (fractions) the pointer passes through for one action.
func pointerPath(_ act: JObject) -> [CGPoint] {
    func n(_ k: String) -> Double { act[k]?.double ?? 0 }
    func f(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x / 1000, y: y / 1000) }
    switch act["action"]?.str {
    case "tap": return [f(n("x"), n("y"))]
    case "swipe": return [f(n("x1"), n("y1")), f(n("x2"), n("y2"))]
    case "path": return points(act).map { f($0.x, $0.y) }
    case "circle": return [f(n("x") + n("r"), n("y"))]
    case "home": return [CGPoint(x: 0.5, y: 0.995), CGPoint(x: 0.5, y: 0.6)]
    case "back": return [CGPoint(x: 0.005, y: 0.45), CGPoint(x: 0.6, y: 0.45)]
    default: return []
    }
}

/// The [[x, y], …] points of a path action, in 0-1000 units.
func points(_ act: JObject) -> [CGPoint] {
    guard case .arr(let items)? = act["points"] else { return [] }
    return items.compactMap {
        guard case .arr(let p) = $0, p.count == 2, let x = p[0].double, let y = p[1].double else { return nil }
        return CGPoint(x: x, y: y)
    }
}

/// Points around a circle; r is a fraction of the width, aspect = width / height.
func circle(_ x: Double, _ y: Double, _ r: Double, aspect: Double, n: Int = 24) -> [CGPoint] {
    (0...n).map { i in
        let a = 2 * Double.pi * Double(i) / Double(n)
        return CGPoint(x: x + r * cos(a), y: y + r * aspect * sin(a))
    }
}
