//
//  OrcaMiniExtensionAudioUnit.swift
//  OrcaMiniExtension
//

import AVFoundation

public class OrcaMiniExtensionAudioUnit: AUAudioUnit, @unchecked Sendable {

    let kernelPtr: OrcaKernelRef
    let runtime: OrcaRuntime

    private var outputBus: AUAudioUnitBus?
    private var _outputBusses: AUAudioUnitBusArray!
    private var format: AVAudioFormat

    @objc override init(componentDescription: AudioComponentDescription,
                        options: AudioComponentInstantiationOptions) throws {
        self.format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let k = OrcaKernelCreate()!
        kernelPtr = k
        runtime = OrcaRuntime(kernel: k)
        try super.init(componentDescription: componentDescription, options: options)
        outputBus = try AUAudioUnitBus(format: self.format)
        outputBus?.maximumChannelCount = 2
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus!])
        OrcaKernelInitialize(kernelPtr, outputBus!.format.sampleRate)
        runtime.start()
    }

    deinit {
        runtime.stop()
        OrcaKernelDestroy(kernelPtr)
    }

    public override var outputBusses: AUAudioUnitBusArray { return _outputBusses }

    public override var maximumFramesToRender: AUAudioFrameCount {
        get { return OrcaKernelMaxFrames(kernelPtr) }
        set { OrcaKernelSetMaxFrames(kernelPtr, newValue) }
    }

    public override var shouldBypassEffect: Bool {
        get { return OrcaKernelIsBypassed(kernelPtr) }
        set { OrcaKernelSetBypass(kernelPtr, newValue) }
    }

    /// without a name here the host does not offer this plugin's MIDI output
    public override var midiOutputNames: [String] { ["OrcaMini Out"] }

    public override var audioUnitMIDIProtocol: MIDIProtocolID {
        return OrcaKernelMIDIProtocol()
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        return OrcaKernelRenderBlock(kernelPtr)
    }

    public override func allocateRenderResources() throws {
        OrcaKernelSetBlocks(kernelPtr, self.musicalContextBlock, self.transportStateBlock, self.midiOutputEventListBlock, self.midiOutputEventBlock)
        OrcaKernelInitialize(kernelPtr, outputBus!.format.sampleRate)
        try super.allocateRenderResources()
    }

    public override func deallocateRenderResources() {
        OrcaKernelDeinitialize(kernelPtr)
        super.deallocateRenderResources()
    }

    // the patch is saved inside the host's session (AUM / Drambo project)
    public override var fullState: [String: Any]? {
        get { var s = super.fullState ?? [:]; s["orcaPatch"] = runtime.patchText(); return s }
        set {
            super.fullState = newValue
            if let t = newValue?["orcaPatch"] as? String { runtime.loadPatch(t) }
        }
    }

    public func setupParameterTree(_ parameterTree: AUParameterTree) {
        self.parameterTree = parameterTree
        for param in parameterTree.allParameters { OrcaKernelSetParameter(kernelPtr, param.address, param.value) }
        parameterTree.implementorValueObserver = { [weak self] param, value in
            if let k = self?.kernelPtr { OrcaKernelSetParameter(k, param.address, value) }
        }
        parameterTree.implementorValueProvider = { [weak self] param in
            if let k = self?.kernelPtr { return OrcaKernelGetParameter(k, param.address) }; return 0
        }
        parameterTree.implementorStringFromValueCallback = { param, valuePtr in
            guard let value = valuePtr?.pointee else { return "-" }
            let names = ["1/4", "1/8", "1/8T", "1/16", "1/16T", "1/32", "1/32T", "1/64"]
            return names[max(0, min(7, Int(value.rounded())))]
        }
    }
}
