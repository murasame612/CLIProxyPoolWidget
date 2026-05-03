import Foundation

enum UsageParser {
    static func parse(_ body: String) -> UsageSnapshot {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else {
            return UsageSnapshot(
                used: nil,
                limit: nil,
                remaining: nil,
                usedPercent: nil,
                planType: nil,
                primaryUsedPercent: nil,
                primaryResetSeconds: nil,
                primaryResetText: nil,
                weeklyUsedPercent: nil,
                weeklyResetSeconds: nil,
                weeklyResetText: nil,
                resetText: nil,
                rawStatus: "invalid usage"
            )
        }

        let pairs = flatten(json)
        if let wham = parseWhamUsage(from: pairs) {
            return wham
        }

        let used = firstNumber(in: pairs, matching: [
            "used", "usage", "consumed", "current", "count", "messages_used", "message_count"
        ])
        let limit = firstNumber(in: pairs, matching: [
            "limit", "total", "cap", "quota", "max", "message_limit", "messages_limit"
        ])
        let remaining = firstNumber(in: pairs, matching: [
            "remaining", "available", "left", "messages_remaining"
        ])
        let reset = firstString(in: pairs, matching: [
            "resets_at", "reset_at", "reset_time", "next_reset", "resets_after", "reset_after", "renewal"
        ])
        let status = firstString(in: pairs, matching: ["status", "tier", "plan", "bucket"])

        return UsageSnapshot(
            used: used,
            limit: limit,
            remaining: remaining,
            usedPercent: nil,
            planType: status,
            primaryUsedPercent: nil,
            primaryResetSeconds: nil,
            primaryResetText: nil,
            weeklyUsedPercent: nil,
            weeklyResetSeconds: nil,
            weeklyResetText: nil,
            resetText: reset,
            rawStatus: status
        )
    }

    private static func parseWhamUsage(from pairs: [(String, Any)]) -> UsageSnapshot? {
        let primaryUsedPercent = number(at: "rate_limit.primary_window.used_percent", in: pairs)
        let secondaryUsedPercent = number(at: "rate_limit.secondary_window.used_percent", in: pairs)
        let usedPercent = primaryUsedPercent ?? secondaryUsedPercent
        let primaryResetSeconds = number(at: "rate_limit.primary_window.reset_after_seconds", in: pairs)
        let secondaryResetSeconds = number(at: "rate_limit.secondary_window.reset_after_seconds", in: pairs)
        let resetSeconds = primaryResetSeconds ?? secondaryResetSeconds
        let planType = string(at: "plan_type", in: pairs) ?? string(at: "account_plan.plan_type", in: pairs)

        if usedPercent == nil && resetSeconds == nil && planType == nil {
            return nil
        }

        return UsageSnapshot(
            used: nil,
            limit: nil,
            remaining: nil,
            usedPercent: usedPercent,
            planType: planType,
            primaryUsedPercent: primaryUsedPercent,
            primaryResetSeconds: primaryResetSeconds,
            primaryResetText: primaryResetSeconds.map(formatDuration(seconds:)),
            weeklyUsedPercent: secondaryUsedPercent,
            weeklyResetSeconds: secondaryResetSeconds,
            weeklyResetText: secondaryResetSeconds.map(formatDuration(seconds:)),
            resetText: resetSeconds.map(formatDuration(seconds:)),
            rawStatus: PlanType.displayName(planType)
        )
    }

    private static func flatten(_ value: Any, path: String = "") -> [(String, Any)] {
        if let dictionary = value as? [String: Any] {
            return dictionary.flatMap { key, nested in
                let nextPath = path.isEmpty ? key : path + "." + key
                return flatten(nested, path: nextPath)
            }
        }
        if let array = value as? [Any] {
            return array.enumerated().flatMap { index, nested in
                flatten(nested, path: path + "[\(index)]")
            }
        }
        return [(path.lowercased(), value)]
    }

    private static func firstNumber(in pairs: [(String, Any)], matching keys: [String]) -> Double? {
        for key in keys {
            if let value = pairs.first(where: { path, _ in pathComponent(path, matches: key) })?.1 {
                if let number = numericValue(value) {
                    return number
                }
            }
        }
        return nil
    }

    private static func firstString(in pairs: [(String, Any)], matching keys: [String]) -> String? {
        for key in keys {
            if let value = pairs.first(where: { path, _ in pathComponent(path, matches: key) })?.1 {
                if let string = value as? String, !string.isEmpty {
                    return string
                }
                if let number = numericValue(value) {
                    return String(Int(number))
                }
            }
        }
        return nil
    }

    private static func number(at path: String, in pairs: [(String, Any)]) -> Double? {
        guard let value = pairs.first(where: { $0.0 == path.lowercased() })?.1 else {
            return nil
        }
        return numericValue(value)
    }

    private static func string(at path: String, in pairs: [(String, Any)]) -> String? {
        guard let value = pairs.first(where: { $0.0 == path.lowercased() })?.1 else {
            return nil
        }
        if let string = value as? String, !string.isEmpty {
            return string
        }
        return nil
    }

    private static func pathComponent(_ path: String, matches key: String) -> Bool {
        let components = path
            .replacingOccurrences(of: "[", with: ".")
            .replacingOccurrences(of: "]", with: "")
            .split(separator: ".")
            .map(String.init)
        return components.contains { component in
            component == key || component.hasSuffix("_" + key) || component.hasSuffix("-" + key)
        }
    }

    private static func numericValue(_ value: Any) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Float:
            return Double(value)
        case let value as Int:
            return Double(value)
        case let value as Int64:
            return Double(value)
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private static func formatDuration(seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "resets in \(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "resets in \(minutes)m"
        }
        return "resets soon"
    }
}
