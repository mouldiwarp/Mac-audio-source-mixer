import CMixEngine

extension FxSetting {
    /// The engine's parameter block for these settings.
    var cParams: FxParams {
        var p = FxParams()
        FxParamsDefault(&p)
        p.denoise = FxDenoise(on: denoiseOn, amount: denoiseAmount)
        p.gate = FxGate(on: gateOn, thresholdDB: gateThresholdDB, rangeDB: gateRangeDB,
                        attackMs: gateAttackMs, holdMs: gateHoldMs, releaseMs: gateReleaseMs)
        p.eq3 = FxEq3(on: eq3On, lowDB: eqLowDB, midDB: eqMidDB, highDB: eqHighDB)
        p.peq.on = peqOn
        withUnsafeMutableBytes(of: &p.peq.band) { raw in
            let bands = raw.bindMemory(to: FxPeqBand.self)
            for (i, b) in peq.prefix(bands.count).enumerated() {
                bands[i] = FxPeqBand(on: b.on, type: b.type.rawValue, freq: b.freq, gainDB: b.gainDB, q: b.q)
            }
        }
        p.comp = FxComp(on: compOn, thresholdDB: compThresholdDB, ratio: compRatio, kneeDB: compKneeDB,
                        attackMs: compAttackMs, releaseMs: compReleaseMs, makeupDB: compMakeupDB)
        p.limiter = FxLimiter(on: limiterOn, ceilingDB: limiterCeilingDB, releaseMs: limiterReleaseMs)
        p.monoOut = monoOut
        return p
    }

    /// Static compressor curve (output dBFS for input dBFS), from the engine.
    func compCurve(_ inDB: Float) -> Float {
        var k = FxComp(on: true, thresholdDB: compThresholdDB, ratio: compRatio, kneeDB: compKneeDB,
                       attackMs: compAttackMs, releaseMs: compReleaseMs, makeupDB: compMakeupDB)
        return FxCompStaticCurve(&k, inDB)
    }
}
