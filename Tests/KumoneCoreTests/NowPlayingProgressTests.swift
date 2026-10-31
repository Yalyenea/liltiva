import Testing
@testable import KumoneCore

struct NowPlayingProgressTests {
    @Test func steadyPlaybackPublishesOnlyPeriodicCorrections() {
        var publication = NowPlayingProgressPublication()
        #expect(publication.shouldPublish(elapsed: 30, rate: 1, at: 100, periodic: true) == true)
        for tick in 1..<50 {
            let interval = Double(tick) * 0.2
            #expect(publication.shouldPublish(elapsed: 30 + interval, rate: 1,
                                              at: 100 + interval, periodic: true) == false)
        }
        #expect(publication.shouldPublish(elapsed: 40, rate: 1, at: 110, periodic: true) == true)
        #expect(publication.shouldPublish(elapsed: 40.6, rate: 1, at: 110.6, periodic: true) == false)
    }

    @Test func explicitSeekPauseAndResumePublishImmediately() {
        var publication = NowPlayingProgressPublication()
        #expect(publication.shouldPublish(elapsed: 30, rate: 1, at: 100) == true)
        // Even a seek smaller than the drift threshold is an explicit action.
        #expect(publication.shouldPublish(elapsed: 30.3, rate: 1, at: 100.2) == true)
        #expect(publication.shouldPublish(elapsed: 30.3, rate: 0, at: 100.3) == true)
        #expect(publication.shouldPublish(elapsed: 30.3, rate: 0, at: 101, periodic: true) == false)
        #expect(publication.shouldPublish(elapsed: 30.3, rate: 1, at: 101) == true)
    }

    @Test func stallsAndRateChangesCorrectTheSystemClockImmediately() {
        var publication = NowPlayingProgressPublication()
        #expect(publication.shouldPublish(elapsed: 30, rate: 1, at: 100) == true)
        #expect(publication.shouldPublish(elapsed: 30, rate: 1, at: 100.6, periodic: true) == true)
        #expect(publication.shouldPublish(elapsed: 30, rate: 0, at: 100.7, periodic: true) == true)
        #expect(publication.shouldPublish(elapsed: 30, rate: 1, at: 100.8, periodic: true) == true)
    }

    @Test func artworkAndMetadataPublicationsResetTheCorrectionClock() {
        var publication = NowPlayingProgressPublication()
        #expect(publication.shouldPublish(elapsed: 30, rate: 1, at: 100) == true)
        #expect(publication.shouldPublish(elapsed: 35, rate: 1, at: 105) == true)
        #expect(publication.shouldPublish(elapsed: 40, rate: 1, at: 110, periodic: true) == false)
        #expect(publication.shouldPublish(elapsed: 45, rate: 1, at: 115, periodic: true) == true)
        #expect(publication.shouldPublish(elapsed: 0, rate: 1, at: 115.1) == true)
    }
}
