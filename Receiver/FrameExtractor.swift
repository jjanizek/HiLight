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
    
    weak var delegate: FrameExtractorDelegate?
    
    override init() {
        super.init()
        checkPermission()
        sessionQueue.async { [unowned self] in
            self.configureSession()
            self.captureSession.startRunning()
            print("HI")
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
        guard permissionGranted else { return }
        captureSession.sessionPreset = quality
        guard let captureDevice = selectCaptureDevice() else { return }
        guard let captureDeviceInput = try? AVCaptureDeviceInput(device: captureDevice) else { return }
        guard captureSession.canAddInput(captureDeviceInput) else { return }
        captureSession.addInput(captureDeviceInput)
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "sample buffer"))
        guard captureSession.canAddOutput(videoOutput) else { return }
        captureSession.addOutput(videoOutput)
        guard let connection = videoOutput.connection(with: AVFoundation.AVMediaType.video) else { return }
        guard connection.isVideoOrientationSupported else { return }
        guard connection.isVideoMirroringSupported else { return }
        connection.videoOrientation = .portrait
        connection.isVideoMirrored = position == .front
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
        lastFortyEightFramesMeanIntesnity[1...47] = lastFortyEightFramesMeanIntesnity[0...46]
        lastFortyEightFramesMeanIntesnity[0] = meanIntensity
    }
    
    private func windowedFFT() -> [Float] {
        let fft1 = fftTransform(buffer: lastFortyEightFramesMeanIntesnity[0...5])
        
        return fft1
    }
    
    private func sqrtq(_ x: [Float]) -> [Float] {
      var results = [Float](repeating: 0.0, count: x.count)
      vvsqrtf(&results, x, [Int32(x.count)])
      return results
    }
    
    private func fftTransform(buffer: ArraySlice<Float>) -> [Float] {
      let frameCount = 6
      let log2n = UInt(round(log2(Double(frameCount))))
      let bufferSizePOT = Int(1 << log2n)
      let inputCount = bufferSizePOT / 2
      let fftSetup = vDSP_create_fftsetup(log2n, Int32(kFFTRadix2))

      var realp = [Float](buffer)
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
        let mean_intensity = (Float(ciFilter[0]) + Float(ciFilter[1]) + Float(ciFilter[2])) / 3
//        if startSymbolFound && endSymbolNotFound {
//
//        }
        slideWindow(meanIntensity: mean_intensity)
        DispatchQueue.main.async { [unowned self] in
            self.delegate?.captured(image: uiImage)
            print(self.windowedFFT())
        }
        
    }
}
