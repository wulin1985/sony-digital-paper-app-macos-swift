//
// main.swift
// DpaNative — Sony Digital Paper (DPT-RP1) 原生 macOS 客户端
//

import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = ContentView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Digital Paper Native"
        window.center()
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let app = NSApplication.shared

// CLI 模式：--smoke（核心链路）/ --full（全 API + roundtrip）/ --roundtrip <pdf> / --p1（重命名/移动/设备配置）
let args = CommandLine.arguments
if args.contains("--smoke") {
    let sem = DispatchSemaphore(value: 0)
    Task {
        await SmokeTest.smoke()
        sem.signal()
    }
    sem.wait()
    exit(0)
}
if args.contains("--p1") {
    let sem = DispatchSemaphore(value: 0)
    Task {
        await SmokeTest.p1()
        sem.signal()
    }
    sem.wait()
    exit(0)
}
if args.contains("--p2") {
    let sem = DispatchSemaphore(value: 0)
    Task {
        await SmokeTest.p2()
        sem.signal()
    }
    sem.wait()
    exit(0)
}
if args.contains("--full") || args.contains("--roundtrip") {
    let pdfArgIndex = args.firstIndex(of: "--roundtrip").flatMap { idx in
        idx + 1 < args.count ? idx + 1 : nil
    }
    let testPDF = pdfArgIndex.map { URL(fileURLWithPath: args[$0]) }
    let sem = DispatchSemaphore(value: 0)
    Task {
        await SmokeTest.full(testPDF: testPDF)
        sem.signal()
    }
    sem.wait()
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
