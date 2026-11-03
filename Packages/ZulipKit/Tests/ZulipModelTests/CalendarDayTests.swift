import Foundation
import Testing
@testable import ZulipModel

struct CalendarDayTests {
    /// Tuesday 2026-11-03, midday UTC.
    private let now = Date(timeIntervalSince1970: 1_793_707_200)

    private func day(_ iso: String) -> CalendarDay {
        CalendarDay(iso: iso)!
    }

    private func suggestions(_ text: String) -> [String] {
        CalendarDay.suggestions(for: text, now: now, timeZone: .gmt).map(\.iso)
    }

    @Test func parsesStrictISODays() {
        #expect(CalendarDay(iso: "2025-12-01") == CalendarDay(year: 2025, month: 12, day: 1))
        #expect(CalendarDay(iso: "2024-02-29") != nil)
        // Unpadded, impossible, or not a date at all.
        #expect(CalendarDay(iso: "2026-1-1") == nil)
        #expect(CalendarDay(iso: "2025-02-29") == nil)
        #expect(CalendarDay(iso: "2025-13-01") == nil)
        #expect(CalendarDay(iso: "2025-00-10") == nil)
        #expect(CalendarDay(iso: "２０２５-12-01") == nil)
        #expect(CalendarDay(iso: "2025-12-01T00:00") == nil)
        #expect(day("2025-12-01").iso == "2025-12-01")
    }

    @Test func codesAsTheISOString() throws {
        let data = try JSONEncoder().encode([day("2025-12-01")])
        #expect(String(decoding: data, as: UTF8.self) == #"["2025-12-01"]"#)
        #expect(try JSONDecoder().decode([CalendarDay].self, from: data) == [day("2025-12-01")])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([CalendarDay].self, from: Data(#"["2025-02-30"]"#.utf8))
        }
    }

    @Test func startsAtLocalMidnight() throws {
        let newYork = try #require(TimeZone(identifier: "America/New_York"))
        #expect(day("2025-12-01").start(in: newYork) == Date(timeIntervalSince1970: 1_764_565_200))
        #expect(day("2025-12-01").start(in: .gmt) == Date(timeIntervalSince1970: 1_764_547_200))
        // The day a date falls on depends on the zone.
        let lateEvening = Date(timeIntervalSince1970: 1_764_565_200 - 1)
        #expect(CalendarDay(lateEvening, timeZone: newYork) == day("2025-11-30"))
        #expect(CalendarDay(lateEvening, timeZone: .gmt) == day("2025-12-01"))
    }

    @Test func searchableFrom1970ThroughThisYear() {
        #expect(day("1970-01-01").isSearchable(now: now, timeZone: .gmt))
        #expect(day("2026-12-31").isSearchable(now: now, timeZone: .gmt))
        #expect(!day("1969-12-31").isSearchable(now: now, timeZone: .gmt))
        #expect(!day("2027-01-01").isSearchable(now: now, timeZone: .gmt))
    }

    @Test func quickPicksReadByName() {
        func name(_ iso: String) -> String? {
            day(iso).relativeName(now: now, timeZone: .gmt)
        }
        #expect(name("2026-11-03") == "today")
        #expect(name("2026-11-02") == "yesterday")
        #expect(name("2026-11-01") == nil)
        #expect(name("2026-10-27") == "a week ago")
        #expect(name("2026-10-03") == "a month ago")
        #expect(name("2025-12-01") == nil)
    }

    @Test func suggestsQuickPicksByWordPrefix() {
        #expect(suggestions("yes") == ["2026-11-02"])
        #expect(suggestions("Today") == ["2026-11-03"])
        #expect(suggestions("week") == ["2026-10-27"])
        #expect(suggestions("ago") == ["2026-10-27", "2026-10-03"])
        // Too short without the operator; inside a word doesn't count.
        #expect(suggestions("to").isEmpty)
        #expect(suggestions("day").isEmpty)
        #expect(suggestions("date:to") == ["2026-11-03"])
        #expect(suggestions("launch").isEmpty)
    }

    @Test func theTypedOperatorAloneOffersEveryQuickPick() {
        #expect(suggestions("date:") == [
            "2026-11-03", "2026-11-02", "2026-11-01", "2026-10-27", "2026-10-03",
        ])
        #expect(suggestions("").isEmpty)
    }

    @Test func completesHalfTypedDatesTowardQuickPicks() {
        #expect(suggestions("2025-12-01") == ["2025-12-01"])
        #expect(suggestions(" Date: 2025-12-01 ") == ["2025-12-01"])
        // On course for this month's picks, then for last month's.
        #expect(suggestions("2026-1") == [
            "2026-11-03", "2026-11-02", "2026-11-01", "2026-10-27", "2026-10-03",
        ])
        #expect(suggestions("2026-10") == ["2026-10-01", "2026-10-27", "2026-10-03"])
        // Diverged at the year: missing parts default to 01, short ones pad.
        #expect(suggestions("2025-") == ["2025-01-01"])
        #expect(suggestions("2025-1") == ["2025-10-01"])
        #expect(suggestions("2025-0") == ["2025-01-01"])
        // A bare number reads as text to search for; the operator says
        // it's a date.
        #expect(suggestions("2026").isEmpty)
        #expect(suggestions("date:2025") == ["2025-01-01"])
    }

    @Test func refusesDaysThatCantBeSearched() {
        #expect(suggestions("2027-01-01").isEmpty)
        #expect(suggestions("1969-12-31").isEmpty)
        #expect(suggestions("2025-02-30").isEmpty)
        #expect(suggestions("2025-12-01-05").isEmpty)
        #expect(suggestions("2025-123").isEmpty)
    }
}
