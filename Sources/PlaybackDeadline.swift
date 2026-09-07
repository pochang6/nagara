import Foundation

// 音声が用意されているのに完了通知が来ない場合だけ復旧する。
// 無音（ミュート）も正常な再生であり、音量を故障の判定に使ってはいけない。
struct PlaybackDeadline {
    private var remaining: TimeInterval?
    private var overdue: TimeInterval = 0
    private var lastTick: TimeInterval?

    mutating func begin(duration: TimeInterval) {
        remaining = duration
        overdue = 0
        resetClock()
    }

    mutating func clear() {
        remaining = nil
        overdue = 0
        resetClock()
    }

    mutating func resetClock() { lastTick = nil }

    mutating func tick(now: TimeInterval, rate: Double, playing: Bool) -> Bool {
        defer { lastTick = now }
        guard playing, let remaining, let previous = lastTick else { return false }
        let elapsed = max(0, now - previous)
        let speed = max(0.5, rate)
        self.remaining = max(0, remaining - elapsed * speed)
        overdue += max(0, elapsed - remaining / speed)
        // TimePitch の遅延やメインスレッドの混雑を、出力の故障と取り違えない。
        return overdue >= 5
    }
}
