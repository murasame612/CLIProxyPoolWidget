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

        let bodyLowercased = body.lowercased()
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
            "resets_at", "reset_at", "reset_time", "next_reset", "resets_after", "reset_after",
            "reset_after_seconds", "resetafterseconds", "retry_after", "retryafter",
            "resets_in_seconds", "reset_in_seconds", "resetsinseconds", "resetinseconds",
            "clears_in", "clearsin", "wait_seconds", "waitseconds", "renewal"
        ])
        let resetSeconds = firstNumber(in: pairs, matching: [
            "reset_after_seconds", "resets_after_seconds", "reset_after", "resets_after",
            "resetafterseconds", "resetsafterseconds", "resetafter", "resetsafter",
            "retry_after", "retryafter", "resets_in_seconds", "reset_in_seconds",
            "resetsinseconds", "resetinseconds", "clears_in", "clearsin",
            "wait_seconds", "waitseconds"
        ]) ?? firstNumber(in: pairs, matching: [
            "resets_at", "reset_at", "reset_time", "next_reset", "renewal"
        ]).flatMap(secondsUntilEpoch) ?? reset.flatMap(secondsUntilReset)
        let planType = firstString(in: pairs, matching: ["plan_type", "plan-type", "plan"])
        let status = firstString(in: pairs, matching: ["status", "tier", "plan", "bucket", "type", "code"])
        let statusLowercased = status?.lowercased() ?? ""
        let looksQuotaLimited = [
            "usage_limit_reached", "quota", "rate_limit", "rate limit", "limit", "limited",
            "cap", "capacity", "exceeded", "too many", "try again"
        ].contains { needle in
            bodyLowercased.contains(needle) || statusLowercased.contains(needle)
        }
        let inferredPrimaryUsedPercent = looksQuotaLimited ? 100.0 : nil

        return UsageSnapshot(
            used: used,
            limit: limit,
            remaining: remaining,
            usedPercent: nil,
            planType: planType ?? (looksQuotaLimited ? nil : status),
            primaryUsedPercent: inferredPrimaryUsedPercent,
            primaryResetSeconds: resetSeconds,
            primaryResetText: resetSeconds.map(formatDuration(seconds:)),
            weeklyUsedPercent: nil,
            weeklyResetSeconds: nil,
            weeklyResetText: nil,
            resetText: reset ?? resetSeconds.map(formatDuration(seconds:)),
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

        if usedPercent == nil && resetSeconds == nil {
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

    private static func secondsUntilReset(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let seconds = Double(trimmed) {
            return seconds
        }
        if let date = DateParser.parse(trimmed) {
            return max(0, date.timeIntervalSinceNow)
        }

        let lowercased = trimmed.lowercased()
        var total: Double = 0
        total += firstDurationValue(in: lowercased, unit: "d") * 86_400
        total += firstDurationValue(in: lowercased, unit: "day") * 86_400
        total += firstDurationValue(in: lowercased, unit: "days") * 86_400
        total += firstDurationValue(in: lowercased, unit: "h") * 3_600
        total += firstDurationValue(in: lowercased, unit: "hour") * 3_600
        total += firstDurationValue(in: lowercased, unit: "hours") * 3_600
        total += firstDurationValue(in: lowercased, unit: "m") * 60
        total += firstDurationValue(in: lowercased, unit: "min") * 60
        total += firstDurationValue(in: lowercased, unit: "mins") * 60
        total += firstDurationValue(in: lowercased, unit: "minute") * 60
        total += firstDurationValue(in: lowercased, unit: "minutes") * 60
        total += firstDurationValue(in: lowercased, unit: "s")
        total += firstDurationValue(in: lowercased, unit: "sec")
        total += firstDurationValue(in: lowercased, unit: "secs")
        total += firstDurationValue(in: lowercased, unit: "second")
        total += firstDurationValue(in: lowercased, unit: "seconds")

        return total > 0 ? total : nil
    }

    private static func secondsUntilEpoch(_ value: Double) -> Double? {
        guard value > 0 else {
            return nil
        }
        let seconds = value > 10_000_000 ? value - Date().timeIntervalSince1970 : value
        return max(0, seconds)
    }

    private static func firstDurationValue(in text: String, unit: String) -> Double {
        let pattern = #"(\d+(?:\.\d+)?)\s*\#(unit)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return 0
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text),
              let value = Double(text[valueRange])
        else {
            return 0
        }
        return value
    }
}
