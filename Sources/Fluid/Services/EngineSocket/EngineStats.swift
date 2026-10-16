import Foundation

/// Dictation statistics for myOS, worked out by the same code as LaVoix's own Stats page. Numbers only: no text from any
/// dictation leaves the history store.
nonisolated protocol EngineStatsProviding: Sendable {
    func snapshot() async throws -> [String: Any]
}

nonisolated struct LiveEngineStats: EngineStatsProviding {
    func snapshot() async throws -> [String: Any] {
        let (entries, typingWPM, weekdays) = await MainActor.run {
            (TranscriptionHistoryStore.shared.entries, SettingsStore.shared.userTypingWPM, SettingsStore.shared.weekendsDontBreakStreak)
        }
        let calendar = Calendar.current
        let now = Date()
        // Off the main thread: a long history takes a moment to add up.
        let built = try await Task.detached(priority: .utility) { try StatsSnapshot.build(entries: entries, now: now, calendar: calendar) }.value
        return Self.describe(weekdays ? built.usingWeekdays(true) : built, typingWPM: typingWPM, weekdays: weekdays, calendar: calendar)
    }

    static func describe(_ s: StatsSnapshot, typingWPM: Int, weekdays: Bool, calendar: Calendar) -> [String: Any] {
        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.dateFormat = "yyyy-MM-dd"
        func milestones(_ list: [(target: Int, achieved: Bool, label: String)]) -> [[String: Any]] {
            list.map { ["target": $0.target, "achieved": $0.achieved, "label": $0.label] }
        }
        var out: [String: Any] = [
            "total_words": s.totalWords, "total_transcriptions": s.totalTranscriptions, "total_characters": s.totalCharacters,
            "average_words": s.averageWordsPerTranscription, "longest_words": s.longestTranscriptionWords,
            "most_words_in_day": s.mostWordsInDay, "most_transcriptions_in_day": s.mostTranscriptionsInDay,
            "current_streak": s.currentStreak, "best_streak": s.bestStreak, "streak_skips_weekends": weekdays,
            "peak_hour": s.peakHourFormatted, "ai_rate": s.aiEnhancementRate,
            "time_saved": s.formattedTimeSaved(typingWPM: typingWPM), "typing_wpm": typingWPM,
            "top_apps": s.topAppUsage.map { ["name": $0.name, "sessions": $0.sessions] as [String: Any] },
            "hourly": s.hourlySessions,
            "activity": s.activity.map { ["date": day.string(from: $0.date), "words": $0.words] as [String: Any] },
            "milestones": ["words": milestones(s.wordMilestones), "dictations": milestones(s.transcriptionMilestones), "streak": milestones(s.streakMilestones)],
            "milestones_achieved": s.totalMilestonesAchieved, "milestones_possible": s.totalMilestonesPossible,
        ]
        if let wpm = s.talkingWordsPerMinute { out["talking_wpm"] = wpm }
        return out
    }
}
