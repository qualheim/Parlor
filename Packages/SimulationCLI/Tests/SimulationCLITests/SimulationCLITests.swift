// Invariant suite smoke tests for parlor-sim (R-QA-2.1).

import Foundation
import Testing
@testable import SimulationCLI

@Suite("parlor-sim invariant harness")
struct SimulationCLITests {
    @Test("a random-legal Crazy Eights run conserves pieces and finishes bounded")
    func randomLegalCrazyEights() async throws {
        let run = try await SimulationRunner.run(
            game: .crazyEights,
            mode: .randomLegal,
            seed: 20240601,
            maxActions: 128)

        #expect(run.passed)
        #expect(run.checks.pieceConservation)
        #expect(run.checks.onlyLegalActions)
        #expect(run.checks.boundedLength)
        #expect(run.checks.scoringConsistency)
        #expect(run.checks.deterministicReplay)
        #expect(run.actionCount <= 128)
    }

    @Test("AI-vs-AI Crazy Eights uses the same deterministic replay contract")
    func aiCrazyEightsIsReproducible() async throws {
        let first = try await SimulationRunner.run(
            game: .crazyEights,
            mode: .aiVsAI,
            seed: 7,
            maxActions: 128)
        let second = try await SimulationRunner.run(
            game: .crazyEights,
            mode: .aiVsAI,
            seed: 7,
            maxActions: 128)

        #expect(first.passed)
        #expect(first.finalHash == second.finalHash)
        #expect(first.actionCount == second.actionCount)
    }

    @Test("both Klondike policies remain legal and bounded on a seeded deal")
    func klondikePoliciesAreBounded() async throws {
        for mode in SimulationMode.allCases {
            let run = try await SimulationRunner.run(
                game: .klondike,
                mode: mode,
                seed: 99,
                maxActions: 64)
            #expect(run.passed)
            #expect(run.checks.pieceConservation)
            #expect(run.checks.onlyLegalActions)
            #expect(run.checks.boundedLength)
            #expect(run.checks.scoringConsistency)
            #expect(run.checks.deterministicReplay)
            #expect(run.actionCount <= 64)
        }
    }

    @Test("a batch covers every game and policy")
    func batchCoversMatrix() async throws {
        let report = try await SimulationRunner.runBatch(
            gamesPerGame: 2,
            seeds: [1, 2],
            maxActions: 64)

        #expect(report.allPassed)
        #expect(report.runCount == 8)
        for game in SimulationGame.allCases {
            for mode in SimulationMode.allCases {
                #expect(report.runs(for: game, mode: mode).count == 2)
            }
        }
    }

    @Test("invalid batch configuration is rejected")
    func invalidBatchConfiguration() async {
        do {
            _ = try await SimulationRunner.runBatch(
                gamesPerGame: 2,
                seeds: [1],
                maxActions: 64)
            Issue.record("expected a seed-pool configuration error")
        } catch let error as SimulationError {
            #expect(error.invariant == "seed-pool")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("CLI derives a reproducible base-seed pool")
    func baseSeedPoolIsReproducible() throws {
        let options = try SimulationCommandLine.Options(
            arguments: ["parlor-sim", "--games", "3", "--base-seed", "42"])

        #expect(try SimulationCommandLine.loadSeeds(options) == [42, 43, 44])
    }

    @Test("CLI rejects malformed seed-pool entries")
    func malformedSeedPoolIsRejected() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parlor-sim-seeds-\(UUID().uuidString).txt")
        try Data("42\nnot-a-seed\n44\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let options = try SimulationCommandLine.Options(
            arguments: ["parlor-sim", "--games", "2", "--seed-file", url.path])
        do {
            _ = try SimulationCommandLine.loadSeeds(options)
            Issue.record("expected malformed seed-pool entry to be rejected")
        } catch let error as SimulationCommandLine.CLIError {
            #expect(error.description.contains("invalid UInt64 seed"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
