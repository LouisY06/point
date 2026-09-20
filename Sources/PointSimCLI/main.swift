import Foundation
import PointSim

/// `swift run point-sim run --all` — no argument parsing dependency, the flags stay obvious.
struct Options {
    var scenarioPaths: [String] = []
    var all = false
    var outputDirectory: URL? = SimRunner.Paths.output
    var fixturesDirectory: URL = SimRunner.Paths.fixtures
    var scenariosDirectory: URL = SimRunner.Paths.scenarios
    var seed: UInt64?
    var quiet = false
}

func usage() -> String {
    """
    point-sim run [options]

      --scenario <path>   Scenario file to run; repeatable.
      --all               Run every scenario in the scenarios directory.
      --dir <path>        Scenarios directory (default Scenarios/).
      --fixtures <path>   Route fixtures directory (default Fixtures/routes/).
      --out <path>        Artifact directory (default .sim-out/). Use "none" to skip writing.
      --seed <number>     Override the scenario seed.
      --quiet             Print the summary table only.
    """
}

@MainActor func run() async -> Int32 {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first, command == "run" else {
        print(usage())
        return arguments.first == "--help" || arguments.isEmpty ? 0 : 2
    }
    arguments.removeFirst()

    var options = Options()
    var index = 0
    while index < arguments.count {
        let flag = arguments[index]
        func value() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        switch flag {
        case "--scenario": options.scenarioPaths.append(value() ?? "")
        case "--all": options.all = true
        case "--dir": options.scenariosDirectory = URL(fileURLWithPath: value() ?? "")
        case "--fixtures": options.fixturesDirectory = URL(fileURLWithPath: value() ?? "")
        case "--out":
            let path = value() ?? ""
            options.outputDirectory = path == "none" ? nil : URL(fileURLWithPath: path)
        case "--seed": options.seed = UInt64(value() ?? "")
        case "--quiet": options.quiet = true
        case "--help": print(usage()); return 0
        default:
            FileHandle.standardError.write(Data("unknown option \(flag)\n".utf8))
            return 2
        }
        index += 1
    }

    do {
        var urls = options.scenarioPaths.map { URL(fileURLWithPath: $0) }
        if options.all || urls.isEmpty {
            urls = try SimRunner.scenarioURLs(in: options.scenariosDirectory)
        }
        guard !urls.isEmpty else {
            FileHandle.standardError.write(Data("no scenarios found\n".utf8))
            return 2
        }
        var traces: [Trace] = []
        for url in urls {
            let artifacts = try await SimRunner.run(scenarioURL: url,
                                                    outputDirectory: options.outputDirectory,
                                                    fixturesDirectory: options.fixturesDirectory,
                                                    seedOverride: options.seed)
            traces.append(artifacts.trace)
            if !options.quiet {
                print(Report.markdown(for: artifacts.trace))
                if let reportURL = artifacts.reportURL { print("report: \(reportURL.path)\n") }
            }
        }
        print(Report.summary(for: traces))
        return traces.allSatisfy(\.passed) ? 0 : 1
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        return 70
    }
}

exit(await run())
