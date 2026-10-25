import Foundation

/// #250: emission of the subtitle-resolution statement. See `SubtitleResolutionStatement` for what
/// the line claims and why neither the drain window's lead edge nor the drain cursor alone can
/// carry that claim.
///
/// Five emission points, chosen so the line marks transitions rather than ticks: the drainer runs
/// at 2 Hz per channel and a statement per tick would bury the moments that carry information.
///
/// - a drain tick that decoded a post-seek reconstruction window (`reason=reconstruction`)
/// - the 30 s memory probe (`reason=tick`)
/// - the pump reading to the end of the source (`reason=eof`)
/// - the frontier's source changing under a steady tick, e.g. a seek past the reading (`reason=frontier`)
/// - #318: determination first reaching the playhead after a reset (`reason=coverage`)
extension AetherEngine {

    /// The generations a statement is made under. Read on the main actor, where both counters are truth.
    var subtitleResolutionFence: SubtitleResolutionStatement.Fence {
        .init(loadGeneration: loadGeneration, seekGeneration: currentSeekGeneration)
    }

    /// The playhead is passed in rather than read here: a drain tick decides on the value it planned
    /// its window with, and #318 compares that same value against `resolvedThrough`. Re-reading
    /// `sourceTime` inside would let the decision and the latch disagree by however long the tick ran.
    func subtitleResolutionStatement(
        channel: SubtitleChannel, streamIndex: Int32,
        reason: SubtitleResolutionStatement.Reason,
        playhead: Double
    ) -> SubtitleResolutionStatement.Statement {
        let fence = subtitleResolutionFence
        let cursor = subtitleDrainCursors[channel]
        return SubtitleResolutionStatement.make(
            fence: fence,
            streamIndex: streamIndex,
            coveredFrom: cursor?.coverageStart ?? (playhead - Self.subtitleDrainBackscanSeconds),
            // The DRAIN lead, not the pump's: the statement is about decoded display state, and the
            // drainer's window is fixed at `subtitleDrainLeadSeconds` even while the OCR worker has
            // the pump reading 270 s ahead to feed it.
            windowThrough: playhead + Self.subtitleDrainLeadSeconds,
            decodedThrough: cursor?.lastDecodedPts ?? .nan,
            readThrough: subtitleReadThrough(streamIndex: streamIndex, from: playhead),
            // #276: the retained run's floor. Read straight off the cursor, which the drain tick
            // has already folded for this tick; nothing is recomputed here.
            retainedFrom: cursor?.retained?.from,
            reason: reason)
    }

    /// Emit an already-built statement. The drain tick builds one per tick either way, because
    /// #276 banks its `resolvedThrough` into the retained run's high-water whether or not the line
    /// is worth printing, and rebuilding it for the print would read the telemetry twice.
    func emitSubtitleResolutionStatement(_ statement: SubtitleResolutionStatement.Statement,
                                         channel: SubtitleChannel, playhead: Double) {
        subtitleResolutionLastFrontier[channel] = statement.via
        // #318: any line that states coverage has stated it, whatever its reason says. Latching it
        // here rather than at the crossing check keeps the cadence and EOF lines from being followed
        // by a `reason=coverage` line that repeats what they just said.
        if SubtitleResolutionStatement.statesCoverage(statement, playhead: playhead) {
            subtitleResolutionCoverageStated.insert(channel)
        }
        EngineLog.emit(SubtitleResolutionStatement.format(statement), category: .engine)
    }

    func emitSubtitleResolutionStatement(
        channel: SubtitleChannel, streamIndex: Int32,
        reason: SubtitleResolutionStatement.Reason
    ) {
        let playhead = sourceTime
        emitSubtitleResolutionStatement(
            subtitleResolutionStatement(channel: channel, streamIndex: streamIndex,
                                        reason: reason, playhead: playhead),
            channel: channel, playhead: playhead)
    }

    /// A transition is a step change in what the engine can claim, so it is worth a line whenever it
    /// happens rather than waiting up to 30 s for the next cadence tick. Two of them can arrive
    /// under a tick that decoded nothing, because both depend on the reading rather than on the
    /// drainer: determination collapsing to the cursor (the playhead left what was read), and the
    /// frontier climbing past the playhead (#318).
    ///
    /// It is the same decision the decoding path takes, so an idle tick cannot stay quiet about a
    /// crossing that a decoding tick would have announced.
    func emitSubtitleResolutionStatementIfTransitioned(
        channel: SubtitleChannel, streamIndex: Int32, playhead: Double
    ) {
        var statement = subtitleResolutionStatement(channel: channel, streamIndex: streamIndex,
                                                    reason: .frontier, playhead: playhead)
        guard let reason = SubtitleResolutionStatement.transitionReason(
            statement, playhead: playhead, isReset: false,
            coverageStated: subtitleResolutionCoverageStated.contains(channel),
            lastFrontier: subtitleResolutionLastFrontier[channel]) else { return }
        statement.reason = reason
        emitSubtitleResolutionStatement(statement, channel: channel, playhead: playhead)
    }

    /// How far `streamIndex` is known to have been read on unbroken from `from`: its pulled spans when the
    /// index reads it, the pump's harvest coverage otherwise; `.infinity` once the pump read to the end.
    func subtitleReadThrough(streamIndex: Int32, from: Double) -> Double? {
        guard let store = activeSubtitlePacketStore else { return nil }
        return subtitleStreamIsPulled(streamIndex)
            ? store.pulledReach(streamIndex: streamIndex, from: from)
            : store.harvestReach(from: from)
    }

    /// One line per active drain target. Used by the cadence tick and by the pump's end of source.
    func emitSubtitleResolutionStatements(reason: SubtitleResolutionStatement.Reason) {
        for (channel, streamIndex) in subtitleDrainTargets {
            emitSubtitleResolutionStatement(channel: channel, streamIndex: streamIndex,
                                            reason: reason)
        }
    }
}
