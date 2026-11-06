import Foundation

public enum HelperError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}

/// Edits top-level keys of a JSON object in place, leaving every other byte of the file untouched
/// (key order, number formatting, escaping). Every patch is checked by re-parsing the result.
public enum TopLevelJSON {
    struct Member {
        let key: String
        let valueRange: Range<Int>
    }

    static func members(_ b: [UInt8]) throws -> (members: [Member], closeBrace: Int) {
        var i = 0
        func ws() { while i < b.count, b[i] == 0x20 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 } }
        func fail(_ what: String) -> HelperError { .message("JSON patch: \(what) at byte \(i)") }
        func skipString() throws {
            guard i < b.count, b[i] == 0x22 else { throw fail("expected string") }
            i += 1
            while i < b.count {
                if b[i] == 0x5C { i += 2; continue }
                if b[i] == 0x22 { i += 1; return }
                i += 1
            }
            throw fail("unterminated string")
        }
        func skipValue() throws {
            guard i < b.count else { throw fail("missing value") }
            switch b[i] {
            case 0x22: try skipString()
            case 0x7B, 0x5B:
                var depth = 0
                while i < b.count {
                    let c = b[i]
                    if c == 0x22 { try skipString(); continue }
                    if c == 0x7B || c == 0x5B { depth += 1 }
                    if c == 0x7D || c == 0x5D {
                        depth -= 1
                        if depth == 0 { i += 1; return }
                    }
                    i += 1
                }
                throw fail("unterminated container")
            default:
                while i < b.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x0A, 0x0D, 0x09].contains(b[i]) { i += 1 }
            }
        }

        ws()
        guard i < b.count, b[i] == 0x7B else { throw fail("expected {") }
        i += 1
        var out: [Member] = []
        while true {
            ws()
            guard i < b.count else { throw fail("unexpected end") }
            if b[i] == 0x7D { return (out, i) }
            let keyStart = i
            try skipString()
            let keyData = Data(b[keyStart..<i])
            guard let key = try JSONSerialization.jsonObject(with: keyData, options: .fragmentsAllowed) as? String else { throw fail("bad key") }
            ws()
            guard i < b.count, b[i] == 0x3A else { throw fail("expected :") }
            i += 1
            ws()
            let vStart = i
            try skipValue()
            out.append(Member(key: key, valueRange: vStart..<i))
            ws()
            guard i < b.count else { throw fail("unexpected end") }
            if b[i] == 0x2C { i += 1; continue }
            if b[i] == 0x7D { return (out, i) }
            throw fail("expected , or }")
        }
    }

    /// Remove top-level keys (and their separating comma), leaving every other byte untouched.
    public static func remove(_ data: Data, keys: [String]) throws -> Data {
        var bytes = [UInt8](data)
        for key in keys {
            let (members, _) = try members(bytes)
            guard let idx = members.firstIndex(where: { $0.key == key }) else { continue }
            // The member starts at its key: walk back from the value start to the opening quote of the key.
            var start = members[idx].valueRange.lowerBound
            var quotes = 0
            while start > 0 {
                start -= 1
                if bytes[start] == 0x22 && (start == 0 || bytes[start - 1] != 0x5C) {
                    quotes += 1
                    if quotes == 2 { break }
                }
            }
            var end = members[idx].valueRange.upperBound
            if idx < members.count - 1 {
                // Drop the comma after this member.
                while end < bytes.count, bytes[end] != 0x2C { end += 1 }
                end += 1
            } else if idx > 0 {
                // Last member: drop the comma before it.
                while start > 0, bytes[start - 1] != 0x2C { start -= 1 }
                start -= 1
            }
            bytes.removeSubrange(start..<end)
        }
        let result = Data(bytes)
        guard var before = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let after = try JSONSerialization.jsonObject(with: result) as? [String: Any] else {
            throw HelperError.message("JSON remove produced something that is not an object")
        }
        keys.forEach { before[$0] = nil }
        guard NSDictionary(dictionary: before).isEqual(to: after) else {
            throw HelperError.message("JSON remove verification failed")
        }
        return result
    }

    public static func encode(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    }

    /// Set several top-level keys. `changes` maps key -> new value (String, Bool, NSNumber, ...).
    public static func patch(_ data: Data, set changes: [(String, Any)]) throws -> Data {
        var bytes = [UInt8](data)
        for (key, value) in changes {
            let valueBytes = [UInt8](try encode(value))
            let (members, close) = try members(bytes)
            if let m = members.first(where: { $0.key == key }) {
                bytes.replaceSubrange(m.valueRange, with: valueBytes)
            } else {
                var insert: [UInt8] = []
                if !members.isEmpty { insert.append(0x2C) }
                insert += [UInt8](try encode(key)) + [0x3A] + valueBytes
                bytes.insert(contentsOf: insert, at: close)
            }
        }
        let result = Data(bytes)
        // Verify: the patched file must parse and equal the original with exactly these keys changed.
        guard let before = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let after = try JSONSerialization.jsonObject(with: result) as? [String: Any] else {
            throw HelperError.message("JSON patch produced something that is not an object")
        }
        var expected = before
        for (k, v) in changes { expected[k] = v }
        guard NSDictionary(dictionary: expected).isEqual(to: after) else {
            throw HelperError.message("JSON patch verification failed")
        }
        return result
    }
}
