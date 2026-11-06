// Copyright (C) 2026 Twarge LLC
// SPDX-License-Identifier: Apache-2.0
//
// Converts the Zulip web app's notification sounds into the CAF files the
// app bundles in Zephyr/Sounds: IMA4, which both system sounds and
// notification banners play. The send sound is the web app's "swish",
// made quieter than the others.
//
// The sounds are CC0 (Stefan Mertens; "zulip" by Vidsyn), except "ding",
// which is CC BY 3.0 (InspectorJ, https://freesound.org/s/411089/) and is
// credited in the About panel and README.
//
// Usage, from the repository root, with a Zulip checkout:
//   swift Scripts/import-zulip-sounds.swift <zulip>/static/audio/notification_sounds

import AVFoundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    print("usage: swift Scripts/import-zulip-sounds.swift <notification_sounds directory>")
    exit(1)
}
let source = URL(fileURLWithPath: arguments[1], isDirectory: true)
let destination = URL(fileURLWithPath: "Zephyr/Sounds", isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

/// The bundled file's name for a web app sound name ("deep tom" → deep-tom).
func slug(_ name: String) -> String {
    name.lowercased().replacingOccurrences(of: " ", with: "-")
        .replacingOccurrences(of: "_", with: "-")
}

func convert(_ input: URL, to output: URL, gainDecibels: Float = 0) throws {
    let file = try AVAudioFile(forReading: input)
    let format = file.processingFormat
    guard let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
    else { throw CocoaError(.fileReadCorruptFile) }
    try file.read(into: buffer)
    if gainDecibels != 0, let channels = buffer.floatChannelData {
        let scale = powf(10, gainDecibels / 20)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                channels[channel][frame] *= scale
            }
        }
    }
    try? FileManager.default.removeItem(at: output)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatAppleIMA4,
        AVSampleRateKey: format.sampleRate,
        AVNumberOfChannelsKey: format.channelCount,
    ]
    let out = try AVAudioFile(
        forWriting: output, settings: settings,
        commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    try out.write(from: buffer)
}

let inputs = try FileManager.default.contentsOfDirectory(
    at: source, includingPropertiesForKeys: nil
).filter { $0.pathExtension == "mp3" }.sorted { $0.path < $1.path }
guard !inputs.isEmpty else {
    print("no .mp3 files in \(source.path)")
    exit(1)
}
for input in inputs {
    let name = input.deletingPathExtension().lastPathComponent
    try convert(input, to: destination.appendingPathComponent(slug(name) + ".caf"))
    print(name)
}
if let swish = inputs.first(where: { $0.deletingPathExtension().lastPathComponent == "swish" }) {
    try convert(swish, to: destination.appendingPathComponent("send.caf"), gainDecibels: -8)
    print("send (swish, -8 dB)")
}
