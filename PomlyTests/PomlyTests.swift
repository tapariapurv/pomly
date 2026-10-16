import Testing
import Foundation
@testable import Pomly

struct PomlyTests {
    @Test func remainingIsDateBased() {
        let now = Date()
        var s = TimerSnapshot(status: .running, planned: 1500, endDate: now + 600)
        #expect(s.remaining(at: now) == 600)
        #expect(s.remaining(at: now + 700) == 0)
        s.status = .paused
        s.remaining = 42
        #expect(s.remaining(at: now + 9999) == 42)
    }

    @Test func dialLapsAndClamps() {
        #expect(DialView.minutes(forAngle: 150, current: 20) == 25)
        #expect(DialView.minutes(forAngle: 6, current: 58) == 61)    // past 12 → second lap
        #expect(DialView.minutes(forAngle: 354, current: 61) == 59)  // back across 12
        #expect(DialView.minutes(forAngle: 354, current: 1) == 1)    // floor
        #expect(DialView.minutes(forAngle: 6, current: 120) == 120)  // ceiling
        #expect(DialView.angle(of: CGPoint(x: 10, y: 0), center: CGPoint(x: 0, y: 0)) == 90)
    }

    @Test func roomCountsOnlyFreshMembers() {
        let now = Date(timeIntervalSince1970: 1_000)
        let ms = now.timeIntervalSince1970 * 1000
        #expect(Room.present(["a": ms + 90_000, "b": ms + 1, "c": ms - 1, "d": ms], at: now) == 2) // lapsed and exactly-now drop off
        #expect(Room.present([:], at: now) == 0)
    }

    @Test func longBreakEveryN() {
        #expect(Pref.breakMinutes(focusCount: 4, every: 4, short: 5, long: 15) == 15)
        #expect(Pref.breakMinutes(focusCount: 3, every: 4, short: 5, long: 15) == 5)
        #expect(Pref.breakMinutes(focusCount: 4, every: 0, short: 5, long: 15) == 5)
    }

    @Test func streakCountsBackFromToday() {
        let cal = Calendar.current, today = cal.startOfDay(for: .now)
        let d = { (n: Int) in cal.date(byAdding: .day, value: -n, to: today)! }
        #expect(Stats.streak([today, d(1), d(2), d(4)], today: today) == 3)
        #expect(Stats.streak([d(1), d(2)], today: today) == 2)
        #expect(Stats.streak([d(2)], today: today) == 0)
    }

    @Test func streakFreezeForgivesOneDayPerWeek() {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 1
        cal.timeZone = TimeZone(identifier: "UTC")!
        let wed = cal.date(from: DateComponents(year: 2026, month: 10, day: 14))!
        let d = { (n: Int) in cal.date(byAdding: .day, value: -n, to: wed)! }
        // Wed Tue [Mon frozen] Sun | Sat [Fri frozen, last week] [Thu missing → ends]
        #expect(Stats.streak([wed, d(1), d(3), d(4)], today: wed, freezes: true, calendar: cal) == 4)
        #expect(Stats.streak([wed, d(1), d(3), d(4)], today: wed, calendar: cal) == 2)
        // Two misses in one week break it.
        #expect(Stats.streak([wed, d(3)], today: wed, freezes: true, calendar: cal) == 1)
    }

    @Test func bestHourAndFeel() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let at = { (h: Int) in cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: h, minute: 10))! }
        #expect(Insights.bestHour([(at(9), 1500), (at(9), 1500), (at(14), 2700)], calendar: cal) == 9)
        #expect(Insights.bestHour([], calendar: cal) == nil)
        #expect(Insights.bestFeel([(at(9), 5), (at(14), 2)], calendar: cal) == nil) // needs 3 ratings
        #expect(Insights.bestFeel([(at(9), 5), (at(9), 4), (at(14), 3), (at(15), 0)], calendar: cal)?.hour == 9)
    }

    @Test func freeGapFitsBlock() {
        let t0 = Date(timeIntervalSince1970: 0), m = { (n: Double) in t0 + n * 60 }
        let busy = [DateInterval(start: m(10), end: m(40)), DateInterval(start: m(30), end: m(60)), DateInterval(start: m(80), end: m(120))]
        #expect(Planner.nextGap(busy: busy, from: m(0), until: m(200), length: 600) == DateInterval(start: m(0), end: m(10)))
        #expect(Planner.nextGap(busy: busy, from: m(0), until: m(200), length: 1500) == DateInterval(start: m(120), end: m(200)))
        #expect(Planner.nextGap(busy: busy, from: m(65), until: m(100), length: 1500) == nil)
        #expect(Planner.nextGap(busy: [], from: m(0), until: m(30), length: 1500) == DateInterval(start: m(0), end: m(30)))
    }
}
