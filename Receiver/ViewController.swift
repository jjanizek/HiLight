//
//  ViewController.swift
//  Receiver
//
//  Created by Joseph Janizek on 5/21/20.
//  Copyright © 2020 Joseph Janizek. All rights reserved.
//

import UIKit

class ViewController: UIViewController {

    var frameExtractor: FrameExtractor!
    @IBOutlet weak var mainLabel: UILabel!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        frameExtractor = FrameExtractor()
    }

}

