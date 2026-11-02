import Testing
@testable import KumoneCore

@Suite struct PlaybackModeTests {
    @Test func cycleVisitsEveryModeOnce() {
        var mode = PlaybackMode.ordered
        var visited: [PlaybackMode] = []
        for _ in 0..<3 {
            visited.append(mode)
            mode = mode.next()
        }
        #expect(visited == [.ordered, .shuffled, .repeatOne])
        #expect(mode == .ordered)
    }

    @Test(arguments: PlaybackMode.allCases)
    func everySelectionRoundTripsThroughEngineState(_ mode: PlaybackMode) {
        #expect(PlaybackMode(queueOrder: mode.queueOrder, repeatMode: mode.repeatMode) == mode)
    }

    @Test func leavingSingleRepeatClearsItEvenAfterRestoringAShuffledSession() {
        let restored = PlaybackMode(queueOrder: .shuffled, repeatMode: .one)
        #expect(restored == .repeatOne)
        let next = restored.next()
        #expect(next.queueOrder == .listed)
        #expect(next.repeatMode == .all)
        #expect(PlaybackMode.shuffled.repeatMode == .all)
    }

    @Test(arguments: [RepeatMode.off, .all])
    func listedSessionsRestoreWithListRepeat(_ repeatMode: RepeatMode) {
        let restored = PlaybackMode(queueOrder: .listed, repeatMode: repeatMode)
        #expect(restored == .ordered)
        #expect(restored.repeatMode == .all)
    }
}
