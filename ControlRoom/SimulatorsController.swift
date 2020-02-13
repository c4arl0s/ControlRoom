//
//  SimulatorsController.swift
//  ControlRoom
//
//  Created by Dave DeLong on 2/12/20.
//  Copyright © 2020 Paul Hudson. All rights reserved.
//

import Combine
import Foundation
import SwiftUI

private enum SimCtl {

    private static let runtimePattern = "com\\.apple\\.CoreSimulator\\.SimRuntime\\.([a-zA-Z]+)-([0-9-]+)$"
    static let osVersionRegex = try? NSRegularExpression(pattern: runtimePattern, options: .caseInsensitive)
    
    /// Handles decoding the device list from simctl
    struct DeviceList: Decodable {
        var devices: [String: [Simulator]]
    }

    struct Simulator: Decodable {
        let status: String?
        let isAvailable: Bool
        let name: String
        let udid: String
        let deviceTypeIdentifier: String?
        let dataPath: String?
        var osVersion: String?
    }

    struct DeviceTypeList: Decodable {
        let devicetypes: [DeviceType]
    }

    struct DeviceType: Decodable {
        let bundlePath: String
        let name: String
        let identifier: String

        var modelTypeIdentifier: TypeIdentifier? {
            guard let bundle = Bundle(path: bundlePath) else { return nil }
            guard let plist = bundle.url(forResource: "profile", withExtension: "plist") else { return nil }
            guard let contents = NSDictionary(contentsOf: plist) else { return nil }
            guard let modelIdentifier = contents.object(forKey: "modelIdentifier") as? String else { return nil }

            return TypeIdentifier(modelIdentifier: modelIdentifier)
        }
    }

}

/// A centralized class that loads simulator data and handles filtering.
class SimulatorsController: ObservableObject {

    /// Tracks the state of fetching simulator data from simctl.
    enum LoadingStatus {
        /// Loading is in progress
        case loading

        /// Loading succeeded
        case success

        /// Loading failed
        case failed
    }

    /// The current loading state; defaults to .loading
    @Published var loadingStatus: LoadingStatus = .loading

    /// An array of all simulators that match the user's current filter.
    @Published var simulators = [Simulator]()

    /// An array of all simulators that were loaded from simctl.
    private var allSimulators = [Simulator]()

    /// A string that filters the list of available simulators.
    var filterText = "" {
        willSet { objectWillChange.send() }
        didSet { filterSimulators() }
    }

    /// The simulator the user is actively working with.
    var selectedSimulator: Simulator? {
        willSet { objectWillChange.send() }
    }

    init() {
        loadSimulators()
    }

    private func getOSVersion(from runtime: String) -> String? {
        guard let match = SimCtl.osVersionRegex?.firstMatch(in: runtime, range: NSRange(location: 0, length: runtime.count)) else { return nil }
        var groups = [String]()
        for index in  0 ..< match.numberOfRanges {
            let group = String(runtime[Range(match.range(at: index), in: runtime)!])
            groups.append(group)
        }
        guard groups.count == 3 else { return nil }
        return groups[2].replacingOccurrences(of: "-", with: ".")
    }

    /// Fetches all simulators from simctl.
    private func loadSimulators() {
        loadingStatus = .loading

        Command.simctl("list", "devices", "available", "-j") { result in
            switch result {
            case .success(let data):
                do {
                    let list = try JSONDecoder().decode(SimCtl.DeviceList.self, from: data)
                    var parsed = [SimCtl.Simulator]()
                    for runtime in list.devices.keys {
                        if let simulators = list.devices[runtime], simulators.count > 0 {
                            for var simulator in simulators {
                                simulator.osVersion = self.getOSVersion(from: runtime)
                                parsed.append(simulator)
                            }
                        }
                    }
                    self.loadDeviceTypes(parsedSimulators: parsed)
                } catch {
                    print(error)
                }
            case .failure:
                self.loadDeviceTypes(parsedSimulators: nil)
            }
        }
    }

    /// Fetches the kinds of simulators supports by simctl
    private func loadDeviceTypes(parsedSimulators: [SimCtl.Simulator]?) {
        Command.simctl("list", "devicetypes", "-j") { result in
            switch result {
            case .success(let data):
                let list = try? JSONDecoder().decode(SimCtl.DeviceTypeList.self, from: data)
                self.merge(parsedSimulators: parsedSimulators, deviceTypes: list?.devicetypes)
            case .failure:
                self.merge(parsedSimulators: parsedSimulators, deviceTypes: nil)
            }
        }
    }

    /// Merges the known simulators with the simulator definitions
    private func merge(parsedSimulators: [SimCtl.Simulator]?, deviceTypes: [SimCtl.DeviceType]?) {
        let rawTypes = deviceTypes ?? []
        let typesByIdentifier = Dictionary(grouping: rawTypes, by: { $0.identifier }).compactMapValues({ $0.first })

        let merged = parsedSimulators?.map { sim -> Simulator in
            let deviceType = typesByIdentifier[sim.deviceTypeIdentifier ?? ""]
            let simulatorName: String
            if let osVersion = sim.osVersion {
                simulatorName = "\(sim.name) - (\(osVersion))"
            } else {
                simulatorName = sim.name
            }
            return Simulator(name: simulatorName, udid: sim.udid, typeIdentifier: deviceType?.modelTypeIdentifier ?? .anyDevice)
        }

        handleParsedSimulators(merged)
    }

    /// Filters the loaded simulators and updates our UI.
    private func handleParsedSimulators(_ newSimulators: [Simulator]?) {
        objectWillChange.send()

        if let new = newSimulators {
            allSimulators = [.default] + new
            filterSimulators()
            loadingStatus = .success
        } else {
            loadingStatus = .failed
        }
    }

    /// Filters the list of simulators using `filterText`, and assigns the result to `simulators`.
    private func filterSimulators() {
        let trimmed = filterText.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty == false {
            simulators = allSimulators.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
        } else {
            simulators = allSimulators
        }

        if let current = selectedSimulator {
            if simulators.firstIndex(of: current) == nil {
                // the current simulator is not in the list of filtered simulators
                // deselect it
                selectedSimulator = nil
            }
        }

        if selectedSimulator == nil {
            selectedSimulator = simulators.first
        }
    }

}
