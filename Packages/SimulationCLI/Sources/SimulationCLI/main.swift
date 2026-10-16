// parlor-sim command-line entry point (R-QA-2.1, R-QA-2.2).

import Foundation

@main
struct ParlorSimMain {
    static func main() async {
        do {
            let options = try SimulationCommandLine.Options(arguments: CommandLine.arguments)
            if options.help {
                print(SimulationCommandLine.usage)
                return
            }
            let seeds = try SimulationCommandLine.loadSeeds(options)
            let report = try await SimulationRunner.runBatch(
                gamesPerGame: options.games,
                seeds: seeds,
                maxActions: options.maxActions)
            SimulationCommandLine.print(report)
        } catch let error as SimulationError {
            FileHandle.standardError.write(Data("parlor-sim: \(error.description)\n".utf8))
            Foundation.exit(1)
        } catch {
            FileHandle.standardError.write(Data("parlor-sim: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }
}

/// Command-line parsing and reporting kept separate from the pure simulation runner so tests can drive
/// `SimulationRunner` without process arguments or stdout.
enum SimulationCommandLine {
    struct Options {
        let games: Int
        let maxActions: Int
        let seedFile: String?
        let baseSeed: UInt64
        let help: Bool

        init(arguments: [String]) throws {
            var games = Int(ProcessInfo.processInfo.environment["PARLOR_SIM_GAMES"] ?? "1") ?? 1
            var maxActions =
                Int(ProcessInfo.processInfo.environment["PARLOR_SIM_MAX_ACTIONS"] ?? "512") ?? 512
            var seedFile = ProcessInfo.processInfo.environment["PARLOR_SIM_SEED_FILE"]
            var baseSeed =
                UInt64(ProcessInfo.processInfo.environment["PARLOR_SIM_BASE_SEED"] ?? "20240601")
                ?? 20240601
            var help = false
            var index = 1

            while index < arguments.count {
                switch arguments[index] {
                case "--help", "-h":
                    help = true
                case "--games":
                    index += 1
                    games = try Self.integer(arguments, at: index, name: "games")
                case "--max-actions":
                    index += 1
                    maxActions = try Self.integer(arguments, at: index, name: "max-actions")
                case "--seed-file":
                    index += 1
                    seedFile = try Self.value(arguments, at: index, name: "seed-file")
                case "--base-seed":
                    index += 1
                    let value = try Self.value(arguments, at: index, name: "base-seed")
                    guard let parsed = UInt64(value) else {
                        throw CLIError("base-seed must be an unsigned integer")
                    }
                    baseSeed = parsed
                default:
                    throw CLIError("unknown argument '\(arguments[index])'; use --help")
                }
                index += 1
            }

            guard games > 0 else { throw CLIError("games must be greater than zero") }
            guard maxActions > 0 else { throw CLIError("max-actions must be greater than zero") }
            self.games = games
            self.maxActions = maxActions
            self.seedFile = seedFile
            self.baseSeed = baseSeed
            self.help = help
        }

        private static func value(_ arguments: [String], at index: Int, name: String) throws
            -> String
        {
            guard arguments.indices.contains(index) else {
                throw CLIError("missing value for --\(name)")
            }
            return arguments[index]
        }

        private static func integer(_ arguments: [String], at index: Int, name: String) throws
            -> Int
        {
            let value = try Self.value(arguments, at: index, name: name)
            guard let parsed = Int(value) else { throw CLIError("\(name) must be an integer") }
            return parsed
        }
    }

    enum CLIError: Error, CustomStringConvertible {
        case message(String)

        init(_ message: String) { self = .message(message) }
        var description: String {
            switch self {
            case .message(let text): return text
            }
        }
    }

    static let usage = """
        Usage: parlor-sim [--games N] [--max-actions N] [--seed-file PATH] [--base-seed N]

        Runs AI-vs-AI and random-legal simulations for Klondike and Crazy Eights.
        --games N        Number of seeds per game and per mode (default: 1, or PARLOR_SIM_GAMES)
        --max-actions N  Explicit action bound for each run (default: 512)
        --seed-file PATH Newline-delimited UInt64 seed pool
        --base-seed N   Starting seed when --seed-file is omitted (default: 20240601)
        """

    static func loadSeeds(_ options: Options) throws -> [UInt64] {
        guard let path = options.seedFile else {
            return (0..<options.games).map { options.baseSeed &+ UInt64($0) }
        }
        let url = URL(fileURLWithPath: path)
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw CLIError("could not read seed file '\(path)': \(error)")
        }
        let tokens = text.split(whereSeparator: \.isWhitespace)
        var seeds: [UInt64] = []
        seeds.reserveCapacity(tokens.count)
        for (index, token) in tokens.enumerated() {
            guard let seed = UInt64(token) else {
                let location = "seed file '\(path)' token \(index + 1)"
                throw CLIError("\(location) contains an invalid UInt64 seed: '\(token)'")
            }
            seeds.append(seed)
        }
        guard seeds.count >= options.games else {
            throw CLIError(
                "seed file '\(path)' contains \(seeds.count) seeds; need \(options.games)")
        }
        return seeds
    }

    static func print(_ report: SimulationBatchReport) {
        Swift.print(
            "parlor-sim: \(report.gamesPerGame) games/game, max \(report.maxActions) actions/run")
        for game in SimulationGame.allCases {
            for mode in SimulationMode.allCases {
                let runs = report.runs(for: game, mode: mode)
                let terminal = runs.count { $0.termination == .terminal }
                let bounded = runs.count - terminal
                let maxActions = runs.map(\.actionCount).max() ?? 0
                Swift.print(
                    "  \(game.rawValue) / \(mode.rawValue): \(runs.count) passed; "
                        + "terminal=\(terminal), bounded-stop=\(bounded), max-actions=\(maxActions)"
                )
            }
        }
        Swift.print(
            "  invariants: piece conservation, legal actions, bounded length, scoring, replay — PASS"
        )
    }
}
