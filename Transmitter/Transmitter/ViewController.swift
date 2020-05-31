//
//  ViewController.swift
//  Transmitter
//
//  Created by Joseph Janizek on 5/20/20.
//  Copyright © 2020 Joseph Janizek. All rights reserved.
//

import Cocoa
import CoreGraphics

extension FixedWidthInteger {
    var binaryString: String {
        var result: [String] = []
        for i in 0..<(Self.bitWidth / 8) {
            let byte = UInt8(truncatingIfNeeded: self >> (i * 8))
            let byteString = String(byte, radix: 2)
            let padding = String(repeating: "0",
                                 count: 8 - byteString.count)
            result.append(padding + byteString)
        }
        return result.reversed().joined(separator: "_")
    }
}

class ViewController: NSViewController {
    var bgImage: NSImageView?
    var timer = Timer()
    var alternating: Double = 0.0
    var currentFrame: Int32 = 0
    var encodedMessage: [UInt8] = []
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let string = "Here is the message that I'm sending"
        
        self.encodedMessage = BFSKEncoding(message: string)
 
        // Do any additional setup after loading the view.
        let image: NSImage = NSImage(named: "IMG_3933")!
        bgImage = NSImageView(image: image)
        bgImage!.frame = CGRect(x: 0, y: 0, width: self.view.frame.width*3, height: self.view.frame.height*3)
        self.view.addSubview(bgImage!)
        self.view.wantsLayer = true
        self.view.layer?.backgroundColor = NSColor.black.cgColor
                
        scheduledTimerWithTimeInterval()
    }
    
    func scheduledTimerWithTimeInterval(){
        // Scheduling timer to Call the function "updateCounting" with the interval of 1 seconds
        timer = Timer.scheduledTimer(timeInterval: 1.0/30.0, target: self, selector: #selector(flickerAlpha), userInfo: nil, repeats: true)
    }
    
    func BFSKEncoding(message: String) -> [UInt8] {
        var BFSKEncoded: [UInt8] = []
        let startChar = "%"
        let endChar = "/"
        
        for char in startChar.utf8{
            for bit in char.binaryString {
                if bit == "1" {
                    BFSKEncoded.append(contentsOf: [1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0])
                }
                else {
                    BFSKEncoded.append(contentsOf: [1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1])
                }
            }
        }
                
        for char in message.utf8{
            for bit in char.binaryString {
                if bit == "1" {
                    BFSKEncoded.append(contentsOf: [1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0])
                }
                else {
                    BFSKEncoded.append(contentsOf: [1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1])
                }
            }
        }
        
        for char in endChar.utf8{
            for bit in char.binaryString {
                if bit == "1" {
                    BFSKEncoded.append(contentsOf: [1, 0, 1, 0, 1, 0])
                }
                else {
                    BFSKEncoded.append(contentsOf: [1, 0, 0, 1, 0, 0])
                }
            }
        }
        return BFSKEncoded
    }
    
    @objc func flickerAlpha(){
        let currentBit: UInt8 = self.encodedMessage[Int(self.currentFrame)]
        if currentBit == 0 {
            self.bgImage?.alphaValue = 0.5
//            print(0)
        }
        else {
            self.bgImage?.alphaValue = 1.0
//            print(1)
        }
        
        self.currentFrame += 1
        
        if self.currentFrame == self.encodedMessage.count {
            timer.invalidate()
        }
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }


}
