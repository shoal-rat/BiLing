import XCTest

@testable import BackboneEngine

/// The versioned config file: per-field validation with safe fallback.
final class EngineConfigTests: XCTestCase {
    private func parse(_ json: String) -> EngineConfig {
        EngineConfig.parse(Data(json.utf8))
    }

    func testValidFileOverridesEverything() {
        let config = parse(
            #"{"schema":"biling-config","version":1,"gate_threshold":0.2,"character_fan_in":32,"tolerant_fan_in":4,"model_timeout_ms":1000,"diagnostics":true}"#
        )
        XCTAssertEqual(config.gateThreshold, 0.2)
        XCTAssertEqual(config.characterFanIn, 32)
        XCTAssertEqual(config.tolerantFanIn, 4)
        XCTAssertEqual(config.modelTimeoutMilliseconds, 1000)
        XCTAssertTrue(config.diagnostics)
    }

    func testOutOfRangeFieldFallsBackAlone() {
        // One bad field must not reset the others.
        let config = parse(
            #"{"schema":"biling-config","version":1,"gate_threshold":7.5,"character_fan_in":32}"#
        )
        XCTAssertEqual(config.gateThreshold, EngineConfig.fallback.gateThreshold)
        XCTAssertEqual(config.characterFanIn, 32)
    }

    func testWrongTypeFallsBack() {
        let config = parse(
            #"{"schema":"biling-config","version":1,"character_fan_in":"twenty"}"#
        )
        XCTAssertEqual(config.characterFanIn, EngineConfig.fallback.characterFanIn)
    }

    func testGarbageAndWrongSchemaYieldDefaults() {
        for json in ["not json at all", #"{"schema":"other","version":1}"#, #"{"version":9}"#] {
            let config = parse(json)
            XCTAssertEqual(config.gateThreshold, EngineConfig.fallback.gateThreshold)
            XCTAssertFalse(config.diagnostics)
        }
    }

    func testDiagnosticsNeverDefaultOn() {
        XCTAssertFalse(EngineConfig.fallback.diagnostics)
        XCTAssertFalse(parse(#"{"schema":"biling-config","version":1}"#).diagnostics)
    }
}
