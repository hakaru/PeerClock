import AVFoundation

final class ClickSynthesizer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let sampleRate: Double = 44100

    private let strongBuffer: AVAudioPCMBuffer
    private let mediumBuffer: AVAudioPCMBuffer
    private let weakBuffer: AVAudioPCMBuffer

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        strongBuffer = Self.generateClick(frequency: 1000, duration: 0.02, amplitude: 1.0, format: format)
        mediumBuffer = Self.generateClick(frequency: 800, duration: 0.015, amplitude: 0.7, format: format)
        weakBuffer = Self.generateClick(frequency: 600, duration: 0.01, amplitude: 0.4, format: format)

        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: .mixWithOthers)
        try session.setActive(true)
        try engine.start()
        playerNode.play()
    }

    func stop() {
        playerNode.stop()
        engine.stop()
    }

    var outputLatency: TimeInterval {
        AVAudioSession.sharedInstance().outputLatency
    }

    var currentSampleTime: AVAudioTime? {
        playerNode.lastRenderTime
    }

    func playClick(_ type: TickType) {
        let buffer = buffer(for: type)
        playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
    }

    func scheduleClick(_ type: TickType, at time: AVAudioTime) {
        let buffer = buffer(for: type)
        playerNode.scheduleBuffer(buffer, at: time, options: [], completionHandler: nil)
    }

    private func buffer(for type: TickType) -> AVAudioPCMBuffer {
        switch type {
        case .downbeat: strongBuffer
        case .beat: mediumBuffer
        case .subdivision: weakBuffer
        }
    }

    private static func generateClick(
        frequency: Double, duration: Double, amplitude: Float, format: AVAudioFormat
    ) -> AVAudioPCMBuffer {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let envelope = Float(1.0 - t / duration)
            data[i] = amplitude * envelope * sin(Float(2.0 * .pi * frequency * t))
        }
        return buffer
    }
}
