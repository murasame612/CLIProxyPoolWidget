import Foundation

struct PoolSummaryService {
    let client: PoolAPIClient
    private let maxConcurrentUsageFetches = 4

    func loadSummary() async -> PoolSummary {
        do {
            let files = try await client.fetchAuthFiles()
            let visibleFiles = client.settings.showOnlyCodex ? files.filter(\.isCodexLike) : files

            let accounts = await loadAccountUsage(for: visibleFiles)

            let cooling = visibleFiles.filter { $0.unavailable || $0.nextRetryAfter != nil }.count
            let disabled = visibleFiles.filter(\.disabled).count
            let failedRecent = visibleFiles.reduce(0) { total, file in
                total + file.recentRequests.suffix(3).reduce(0) { $0 + $1.failed }
            }
            let recentRequests = mergeRecentRequests(from: visibleFiles, limit: 20)
            let activeAccounts = accounts.filter(\.isAvailable)
            let weightedCapacity = activeAccounts.reduce(0) { $0 + $1.weight }
            let primaryRemaining = activeAccounts.reduce(0) { $0 + $1.primaryWeightedRemaining }
            let weeklyRemaining = activeAccounts.reduce(0) { $0 + $1.weeklyWeightedRemaining }
            let breakdown = makePlanBreakdown(from: activeAccounts)
            let primaryResetHint = makeResetHint(
                from: activeAccounts.flatMap(primaryResetEvents(for:)),
                currentUnits: primaryRemaining,
                capacityUnits: weightedCapacity
            )
            let weeklyResetHint = makeResetHint(
                from: activeAccounts.compactMap { account in
                    guard let seconds = account.usage?.weeklyResetSeconds else {
                        return nil
                    }
                    return ResetEvent(secondsUntil: seconds, restoredUnits: account.weeklyResetRestoredUnits)
                },
                currentUnits: weeklyRemaining,
                capacityUnits: weightedCapacity
            )

            return PoolSummary(
                generatedAt: Date(),
                totalAccounts: visibleFiles.count,
                availableAccounts: visibleFiles.filter(\.isAvailable).count,
                coolingAccounts: cooling,
                disabledAccounts: disabled,
                failedRecentRequests: failedRecent,
                primaryRemainingUnits: primaryRemaining,
                primaryCapacityUnits: weightedCapacity,
                weeklyRemainingUnits: weeklyRemaining,
                weeklyCapacityUnits: weightedCapacity,
                nextPrimaryResetHint: primaryResetHint,
                nextWeeklyResetHint: weeklyResetHint,
                recentRequests: recentRequests,
                planBreakdown: breakdown,
                accounts: accounts,
                errorMessage: nil
            )
        } catch {
            return PoolSummary(
                generatedAt: Date(),
                totalAccounts: 0,
                availableAccounts: 0,
                coolingAccounts: 0,
                disabledAccounts: 0,
                failedRecentRequests: 0,
                primaryRemainingUnits: 0,
                primaryCapacityUnits: 0,
                weeklyRemainingUnits: 0,
                weeklyCapacityUnits: 0,
                nextPrimaryResetHint: nil,
                nextWeeklyResetHint: nil,
                recentRequests: [],
                planBreakdown: [],
                accounts: [],
                errorMessage: error.localizedDescription
            )
        }
    }

    private func loadAccountUsage(for files: [AuthFile]) async -> [AccountUsage] {
        var values: [AccountUsage] = []
        let batchSize = max(1, maxConcurrentUsageFetches)

        var start = files.startIndex
        while start < files.endIndex {
            let end = files.index(start, offsetBy: batchSize, limitedBy: files.endIndex) ?? files.endIndex
            let batch = files[start..<end]
            let batchValues = await withTaskGroup(of: AccountUsage.self) { group in
                for file in batch {
                    group.addTask {
                        await usage(for: file)
                    }
                }

                var batchResults: [AccountUsage] = []
                for await value in group {
                    batchResults.append(value)
                }
                return batchResults
            }
            values.append(contentsOf: batchValues)
            start = end
        }

        return values.sorted { lhs, rhs in
            if lhs.isAvailable != rhs.isAvailable {
                return lhs.isAvailable && !rhs.isAvailable
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func usage(for file: AuthFile) async -> AccountUsage {
        do {
            var snapshot = try await fetchUsageWithRetry(for: file)
            if snapshot.planType == nil {
                snapshot.planType = file.idToken?.planType
            }
            return AccountUsage(
                authIndex: file.authIndex,
                name: file.displayName,
                provider: file.normalizedProvider,
                isAvailable: isQuotaAvailable(file: file, usage: snapshot),
                statusText: statusText(for: file, usage: snapshot),
                weight: client.settings.weight(for: snapshot.planType),
                weeklyKillLinePercent: client.settings.weeklyKillLinePercent,
                recentRequests: Array(file.recentRequests.suffix(20)),
                usage: snapshot,
                error: nil
            )
        } catch {
            return AccountUsage(
                authIndex: file.authIndex,
                name: file.displayName,
                provider: file.normalizedProvider,
                isAvailable: file.isAvailable,
                statusText: statusText(for: file),
                weight: client.settings.weight(for: file.idToken?.planType),
                weeklyKillLinePercent: client.settings.weeklyKillLinePercent,
                recentRequests: Array(file.recentRequests.suffix(20)),
                usage: nil,
                error: error.localizedDescription
            )
        }
    }

    private func mergeRecentRequests(from files: [AuthFile], limit: Int) -> [RecentRequestBucket] {
        let bucketCount = max(0, limit)
        guard bucketCount > 0 else {
            return []
        }

        var merged = Array(repeating: RecentRequestBucket(success: 0, failed: 0), count: bucketCount)
        for file in files {
            let buckets = Array(file.recentRequests.suffix(bucketCount))
            let offset = bucketCount - buckets.count
            for (index, bucket) in buckets.enumerated() {
                let target = offset + index
                merged[target] = RecentRequestBucket(
                    time: bucket.time ?? merged[target].time,
                    success: merged[target].success + bucket.success,
                    failed: merged[target].failed + bucket.failed
                )
            }
        }
        return merged
    }

    private func fetchUsageWithRetry(for file: AuthFile) async throws -> UsageSnapshot {
        var lastError: Error?

        for attempt in 0..<2 {
            do {
                return try await client.fetchWhamUsage(
                    authIndex: file.authIndex,
                    chatgptAccountID: file.idToken?.chatgptAccountID
                )
            } catch {
                lastError = error
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                }
            }
        }

        throw lastError ?? PoolAPIError.invalidResponse
    }

    private func isQuotaAvailable(file: AuthFile, usage: UsageSnapshot) -> Bool {
        if file.disabled {
            return false
        }
        if usage.hasQuotaSignal {
            return true
        }
        return file.isAvailable
    }

    private func makePlanBreakdown(from accounts: [AccountUsage]) -> [PlanBreakdown] {
        let grouped = Dictionary(grouping: accounts) { account in
            PlanType.normalize(account.planType)
        }
        return grouped.map { planType, accounts in
            PlanBreakdown(
                planType: planType,
                count: accounts.count,
                weight: accounts.first?.weight ?? client.settings.weight(for: planType),
                primaryRemainingUnits: accounts.reduce(0) { $0 + $1.primaryWeightedRemaining },
                weeklyRemainingUnits: accounts.reduce(0) { $0 + $1.weeklyWeightedRemaining }
            )
        }
        .sorted { lhs, rhs in
            if lhs.weight != rhs.weight {
                return lhs.weight > rhs.weight
            }
            return lhs.planType < rhs.planType
        }
    }

    private struct ResetEvent {
        let secondsUntil: Double
        let restoredUnits: Double
    }

    private func primaryResetEvents(for account: AccountUsage) -> [ResetEvent] {
        var events: [ResetEvent] = []

        if let seconds = account.usage?.primaryResetSeconds {
            events.append(ResetEvent(secondsUntil: seconds, restoredUnits: account.primaryResetRestoredUnits))
        }

        if let seconds = account.usage?.weeklyResetSeconds {
            events.append(ResetEvent(secondsUntil: seconds, restoredUnits: account.weeklyResetReleasedPrimaryUnits))
        }

        return events
    }

    private func makeResetHint(
        from events: [ResetEvent],
        currentUnits: Double,
        capacityUnits: Double
    ) -> QuotaResetHint? {
        let sorted = events
            .filter { $0.secondsUntil >= 0 && $0.restoredUnits > 0.0001 }
            .sorted { $0.secondsUntil < $1.secondsUntil }
        guard let first = sorted.first else {
            return nil
        }

        let bucketEnd = first.secondsUntil +
            Double(PoolWatchConstants.resetAggregationSeconds + PoolWatchConstants.resetAggregationToleranceSeconds)
        let bucket = sorted.filter { $0.secondsUntil <= bucketEnd }
        let restoredUnits = bucket.reduce(0) { $0 + $1.restoredUnits }
        guard restoredUnits > 0 else {
            return nil
        }

        let latestSeconds = bucket.map(\.secondsUntil).max() ?? first.secondsUntil
        return QuotaResetHint(
            accountCount: bucket.count,
            secondsUntil: latestSeconds,
            restoredUnits: restoredUnits,
            targetUnits: min(capacityUnits, currentUnits + restoredUnits),
            capacityUnits: capacityUnits
        )
    }

    private func statusText(for file: AuthFile, usage: UsageSnapshot? = nil) -> String {
        if let usage, usage.hasQuotaSignal, file.unavailable || !file.isAvailable {
            if isPrimaryQuotaLimited(usage) {
                return "quota limited"
            }
            return "active"
        }
        if file.disabled {
            return "disabled"
        }
        if file.unavailable {
            if let next = file.nextRetryAfter {
                return "cooling until " + next.formatted(date: .omitted, time: .shortened)
            }
            return "cooling"
        }
        if let message = file.statusMessage, !message.isEmpty {
            return message
        }
        if let status = file.status, !status.isEmpty {
            return status
        }
        return file.isAvailable ? "active" : "unknown"
    }

    private func isPrimaryQuotaLimited(_ usage: UsageSnapshot) -> Bool {
        guard let remaining = usage.primaryRemainingPercent else {
            return false
        }
        return remaining <= 0.05
    }
}
