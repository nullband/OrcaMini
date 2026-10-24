//
//  Parameters.swift
//  OrcaMiniExtension
//

import Foundation
import AudioToolbox

let OrcaMiniExtensionParameterSpecs = ParameterTreeSpec {
    ParameterGroupSpec(identifier: "clock", name: "Clock") {
        ParameterSpec(
            address: OrcaMiniExtensionParameterAddress.speedIndex.rawValue,
            identifier: "speed",
            name: "Speed",
            units: .indexed,
            valueRange: 0...7,
            defaultValue: 3,
            valueStrings: ["1/4", "1/8", "1/8T", "1/16", "1/16T", "1/32", "1/32T", "1/64"]
        )
    }
}
