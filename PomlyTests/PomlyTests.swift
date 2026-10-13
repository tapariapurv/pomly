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
}
