//
//  ChannelView.swift
//  OwonBinFile
//
//  Bounds-safe drawing for Swift 5 / Xcode 15.2
//

import Cocoa

class ChannelView: NSView {
    private var ch1Values: [UInt8] = []
    private var ch2Values: [UInt8] = []
    private var ch1Count = 0
    private var ch2Count = 0

    override func awakeFromNib() {
        super.awakeFromNib()

        // Der ChannelView ist nicht mehr größer als der sichtbare Bereich.
        // Er wächst und schrumpft immer gemeinsam mit dem ClipView der ScrollView.
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = [.width, .height]
    }

    func addChannels(_ channel1Count: Int, _ channel1Values: [UInt8],
                     _ channel2Count: Int, _ channel2Values: [UInt8]) {
        ch1Values = channel1Values
        ch1Count = min(max(0, channel1Count), channel1Values.count)
        ch2Values = channel2Values
        ch2Count = min(max(0, channel2Count), channel2Values.count)
        needsDisplay = true
    }

    private func drawGrid() {
        let path = NSBezierPath()
        path.lineWidth = 1.0

        // Das Raster füllt den ChannelView in beiden Richtungen vollständig aus.
        // Horizontal: 14 Rastereinheiten (Randfelder je 1/2 Einheit)
        // Vertikal:   10 Rastereinheiten
        let xStep = bounds.width / 14.0
        let yStep = bounds.height / 10.0
        let originX = bounds.minX
        let originY = bounds.minY

        // 10 vertikale Kästchen = 11 horizontale Linien.
        for i in 0...10 {
            let y = originY + CGFloat(i) * yStep
            path.move(to: NSPoint(x: originX, y: y))
            path.line(to: NSPoint(x: bounds.maxX, y: y))
        }

        // Vertikale Linien: erstes und letztes Feld je halb so breit.
        var x = originX
        path.move(to: NSPoint(x: x, y: originY))
        path.line(to: NSPoint(x: x, y: bounds.maxY))

        x += 0.5 * xStep
        path.move(to: NSPoint(x: x, y: originY))
        path.line(to: NSPoint(x: x, y: bounds.maxY))

        for _ in 0..<13 {
            x += xStep
            path.move(to: NSPoint(x: x, y: originY))
            path.line(to: NSPoint(x: x, y: bounds.maxY))
        }

        x += 0.5 * xStep
        path.move(to: NSPoint(x: x, y: originY))
        path.line(to: NSPoint(x: x, y: bounds.maxY))

        NSColor.gridColor.setStroke()
        path.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSColor(red: 28.0 / 255.0,
                green: 60.0 / 255.0,
                blue: 121.0 / 255.0,
                alpha: 1.0).setFill()
        bounds.fill()

        drawGrid()
        drawChannel(ch1Values, byteCount: ch1Count, color: NSColor.white.withAlphaComponent(0.6))
        drawChannel(ch2Values, byteCount: ch2Count, color: NSColor.yellow.withAlphaComponent(0.6))
    }

    private func drawChannel(_ bytes: [UInt8], byteCount requestedByteCount: Int, color: NSColor) {
        let byteCount = min(max(0, requestedByteCount), bytes.count)
        let evenByteCount = byteCount - (byteCount % 2)
        guard evenByteCount >= 2 else { return }

        color.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.0

        let sampleCount = evenByteCount / 2
        var byteOffset = 0
        var sampleIndex = 0

        while byteOffset + 1 < evenByteCount {
            let raw = UInt16(bytes[byteOffset]) | (UInt16(bytes[byteOffset + 1]) << 8)
            let value = Int16(bitPattern: raw)

            // Die Zeitachse belegt unabhängig von der Fenstergröße immer
            // exakt die gesamte Breite des Bordered Scroll View.
            let x: CGFloat
            if sampleCount > 1 {
                x = bounds.minX + CGFloat(sampleIndex) * bounds.width / CGFloat(sampleCount - 1)
            } else {
                x = bounds.midX
            }

            // Bisher entsprach die Darstellung bei 500 pt Höhe der Skalierung 1:10.
            // Der gleiche Verlauf wird nun proportional mit der View-Höhe skaliert.
            let referenceHeight: CGFloat = 500.0
            let yScale = bounds.height / referenceHeight
            let y = bounds.midY + (CGFloat(value) / 10.0) * yScale

            let point = NSPoint(x: x, y: y)
            if sampleIndex == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }

            byteOffset += 2
            sampleIndex += 1
        }

        path.stroke()
    }
}
