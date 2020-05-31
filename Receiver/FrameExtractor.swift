//
//  FrameExtractor.swift
//  Receiver
//
//  Created by Joseph Janizek on 5/21/20.
//  Copyright © 2020 Joseph Janizek. All rights reserved.
//

import UIKit
import AVFoundation
import Accelerate

protocol FrameExtractorDelegate: class {
    func captured(image: UIImage)
}

class FrameExtractor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    private let position = AVCaptureDevice.Position.back
    private let quality = AVCaptureSession.Preset.medium
    
    private var permissionGranted = false
    private let sessionQueue = DispatchQueue(label: "session queue")
    private let captureSession = AVCaptureSession()
    private let context = CIContext()
    private var lastSixFramesMeanIntensity = [UInt8](repeating: 0, count: 6)
    private var lastFortyEightFramesMeanIntesnity = [Float](repeating: 0, count: 48)
    private var decodedMessage: [UInt8]?
    private var startSymbolFound: Bool = false
    private var endSymbolNotFound: Bool = true
    private var localFrameIndex: Int = 0
    private var waitFrames: Int = 0
    private var totalFrames: Int = 0
    private var receivedMessage: [Character] = []
    
    weak var delegate: FrameExtractorDelegate?
    
    override init() {
        super.init()
        checkPermission()
        sessionQueue.async { [unowned self] in
            self.configureSession()
            self.captureSession.startRunning()
        }
    }
    
    // MARK: AVSession configuration
    private func checkPermission() {
        switch AVCaptureDevice.authorizationStatus(for: AVMediaType.video) {
        case .authorized:
            permissionGranted = true
        case .notDetermined:
            requestPermission()
        default:
            permissionGranted = false
        }
    }
    
    private func requestPermission() {
        sessionQueue.suspend()
        AVCaptureDevice.requestAccess(for: AVMediaType.video) { [unowned self] granted in
            self.permissionGranted = granted
            self.sessionQueue.resume()
        }
    }
    
    private func configureSession() {
        
        let frameRate = 30
        
        guard permissionGranted else { return }
        captureSession.sessionPreset = quality
        guard let captureDevice = selectCaptureDevice() else { return }
//        captureDevice.exposureMode.locked = AVCaptureDevice.ExposureMode(rawValue: 0)
        guard let captureDeviceInput = try? AVCaptureDeviceInput(device: captureDevice) else { return }
        
        guard captureSession.canAddInput(captureDeviceInput) else { return }
        captureSession.addInput(captureDeviceInput)
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "sample buffer"))
        videoOutput.alwaysDiscardsLateVideoFrames = false
        guard captureSession.canAddOutput(videoOutput) else { return }
        captureSession.addOutput(videoOutput)
        guard let connection = videoOutput.connection(with: AVFoundation.AVMediaType.video) else { return }
        guard connection.isVideoOrientationSupported else { return }
        guard connection.isVideoMirroringSupported else { return }
        connection.videoOrientation = .portrait
        connection.isVideoMirrored = position == .front
        
        do {
            try captureDevice.lockForConfiguration()
        } catch {}
        captureDevice.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: Int32(frameRate))
        captureDevice.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: Int32(frameRate))
        captureDevice.exposureMode = AVCaptureDevice.ExposureMode(rawValue: 0)!
        captureDevice.unlockForConfiguration()
        
    }
    
    private func selectCaptureDevice() -> AVCaptureDevice? {
        return AVCaptureDevice.devices().filter {
            ($0 as AnyObject).hasMediaType(AVMediaType.video) &&
            ($0 as AnyObject).position == position
        }.first
    }
    
    // MARK: Sample buffer to UIImage conversion
    private func imageFromSampleBuffer(sampleBuffer: CMSampleBuffer) -> UIImage? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    
    private func ciFilterFromSampleBuffer(sampleBuffer: CMSampleBuffer) -> [UInt8]? {
        var bitmap = [UInt8](repeating: 0, count: 4)
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let extent = ciImage.extent
        let inputExtent = CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.size.width, w: extent.size.height)
        let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: ciImage, kCIInputExtentKey: inputExtent])!
        let outputImage = filter.outputImage!
        let outputExtent = outputImage.extent
        context.render(outputImage, toBitmap: &bitmap, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: CIFormat.RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return bitmap
    }
    
    private func slideWindow(meanIntensity: Float) -> Void {
        lastFortyEightFramesMeanIntesnity[0...46] = lastFortyEightFramesMeanIntesnity[1...47]
        lastFortyEightFramesMeanIntesnity[47] = meanIntensity
    }
    
    private func sqrtq(_ x: [Float]) -> [Float] {
      var results = [Float](repeating: 0.0, count: x.count)
      vvsqrtf(&results, x, [Int32(x.count)])
      return results
    }
        
    func fftTransform(buffer: ArraySlice<Float>) -> [Float] {
      let frameCount = 24
      let log2n = UInt(round(log2(Double(frameCount))))
      let bufferSizePOT = Int(1 << log2n)
      let inputCount = bufferSizePOT / 2
      let fftSetup = vDSP_create_fftsetup(log2n, Int32(kFFTRadix2))

      let floatBuffer = buffer

      var realp = [Float](floatBuffer)
      var imagp = [Float](repeating: 0, count: inputCount)
      var output = DSPSplitComplex(realp: &realp, imagp: &imagp)

      vDSP_fft_zrip(fftSetup!, &output, 1, log2n, FFTDirection(FFT_FORWARD))

      var magnitudes = [Float](repeating: 0.0, count: inputCount)
      vDSP_zvmags(&output, 1, &magnitudes, 1, vDSP_Length(inputCount))

      var normalizedMagnitudes = [Float](repeating: 0.0, count: inputCount)
      vDSP_vsmul(sqrtq(magnitudes), 1, [2.0 / Float(inputCount)],
        &normalizedMagnitudes, 1, vDSP_Length(inputCount))

      vDSP_destroy_fftsetup(fftSetup)

      return normalizedMagnitudes
    }
    
    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let uiImage = imageFromSampleBuffer(sampleBuffer: sampleBuffer) else { return }
        guard let ciFilter = ciFilterFromSampleBuffer(sampleBuffer: sampleBuffer) else { return
        }
        let mean_intensity = (Float(ciFilter[0]) + Float(ciFilter[1]) + Float(ciFilter[2])) / (3*255)

        slideWindow(meanIntensity: mean_intensity)
        totalFrames += 1
        
        let out = fftTransform(buffer: lastFortyEightFramesMeanIntesnity[32...47])
        let newOut = [Float](out[1...out.count-1])
        
        DispatchQueue.main.async { [unowned self] in
            self.delegate?.captured(image: uiImage)
            
            if self.totalFrames % 16 == 0{
                if newOut.argmax == 4 || newOut.argmax == 3 || newOut.argmax == 5 {
                    print(0)
                    self.receivedMessage.append("0")
                }
                else if newOut.argmax == 7 || newOut.argmax == 6 || newOut.argmax == 8 {
                    print(1)
                    self.receivedMessage.append("1")
                }
                else {
                    print(0)
                    self.receivedMessage.append("0")
                }
            }
            
            
        }
        
    }
}

func utf8Decoder(message: String) -> Character {
    let binary = message
    if let number = Int(binary, radix: 2) {
        // Convert Int to a UnicodeScalar.
        if let u = UnicodeScalar(number) {
            // Convert UnicodeScalar to a Character.
            let char = Character(u)
            print(char)
            return char
        }
        else { return Character("%") }
    }
    else { return Character("%") }
}

func decodeMessage(receivedMessage: [Character]) -> String {
    var currentMessage: String = ""
    var outputMessage: String = ""
    for i in 0...receivedMessage.count {
        currentMessage = currentMessage + String(receivedMessage[i])
        if (i + 1) % 8 == 0 {
            print(utf8Decoder(message: currentMessage))
            outputMessage = outputMessage + String(utf8Decoder(message: currentMessage))
            currentMessage = ""
        }
    }
    return outputMessage
}

extension Array where Element == Float{
    var argmax : Int {
        get{
            precondition(self.count > 0)
            let maxValue = self.max()
            for i in 0..<self.count{
                if self[i] == maxValue {
                    return i
                }
            }
        return -1
        }
}
}

extension Sequence where Element: AdditiveArithmetic {
    /// Returns the total sum of all elements in the sequence
    func sum() -> Element { reduce(.zero, +) }
}
extension Collection where Element: BinaryFloatingPoint {
    /// Returns the average of all elements in the array
    func average() -> Element { isEmpty ? .zero : Element(sum()) / Element(count) }
}
