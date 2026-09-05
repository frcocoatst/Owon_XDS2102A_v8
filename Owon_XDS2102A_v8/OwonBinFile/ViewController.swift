//
//  ViewController.swift
//  OwonBinFile
//
//  Bounds-safe OWON BIN reader for Swift 5 / Xcode 15.2
//

import Cocoa

struct Waveform: Decodable {
    let MODEL: String
    let IDN: String
    let channel: [Channel]
}

struct Channel: Decodable {
    let Index: String
    let Availability_Flag: String
    let Display_Switch: String
    let Wave_Character: String
    let Sample_Rate: String
    let Acqu_Mode: String
    let Storage_Depth: String
    let Display_Mode: String
    let Hscale: String
    let Vscale: String
    let Reference_Zero: String
    let Scroll_Pos_Time: String
    let Trig_After_Time: String
    let Trig_Tops_Tme: String
    let Adc_Data_Time: String
    let Adc_Data0_Time: String
    let Voltage_Rate: String
    let Data_Length: String
    let Probe_Magnification: String
    let Current_Rate: Float
    let Current_Ratio: Float
    let Measure_Current_Switch: String
    let Cyc: String
    let Freq: String
    let PRECISION: Int
}

extension NSOpenPanel {
    var selectUrl: URL? {
        title = "Select File"
        allowsMultipleSelection = false
        canChooseDirectories = false
        canChooseFiles = true
        canCreateDirectories = false
        allowedFileTypes = ["bin", "BIN"]
        return runModal() == .OK ? urls.first : nil
    }
}

private enum OWONParserError: LocalizedError {
    case fileTooShort(Int)
    case invalidSignature(String)
    case invalidJSONLength(Int, available: Int)
    case invalidJSON(Error)
    case truncatedLengthField(offset: Int)
    case invalidChannelLength(channel: Int, declared: Int, available: Int)
    case noChannelData

    var errorDescription: String? {
        switch self {
        case .fileTooShort(let count):
            return "Die Datei ist zu kurz (\(count) Bytes). Ein OWON-Header benötigt mindestens 10 Bytes."
        case .invalidSignature(let signature):
            return "Ungültige OWON-Signatur: \"\(signature)\" statt \"SPBXDS\"."
        case .invalidJSONLength(let length, let available):
            return "Ungültige JSON-Länge \(length). Ab Offset 10 sind nur \(available) Bytes verfügbar."
        case .invalidJSON(let error):
            return "Der OWON-JSON-Header konnte nicht gelesen werden: \(error.localizedDescription)"
        case .truncatedLengthField(let offset):
            return "Unvollständiges 4-Byte-Längenfeld bei Offset \(offset)."
        case .invalidChannelLength(let channel, let declared, let available):
            return "Kanal \(channel): Datenblock meldet \(declared) Bytes, verfügbar sind aber nur \(available) Bytes."
        case .noChannelData:
            return "Die Datei enthält keine lesbaren Kanaldaten."
        }
    }
}

private struct OWONFile {
    let waveform: Waveform
    let channels: [Data]
    let jsonLength: Int
}

/// Sequential, bounds-safe reader. Every read checks the remaining byte count first.
private struct DataCursor {
    let data: Data
    private(set) var offset: Int

    init(data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    var remaining: Int { data.count - offset }

    mutating func readData(count: Int) -> Data? {
        guard count >= 0, offset >= 0, count <= remaining else { return nil }
        let start = offset
        offset += count
        return data.subdata(in: start..<offset)
    }

    mutating func readUInt32LE() -> UInt32? {
        guard let bytes = readData(count: 4) else { return nil }
        return bytes.withUnsafeBytes { rawBuffer in
            let b = rawBuffer.bindMemory(to: UInt8.self)
            return UInt32(b[0]) |
                (UInt32(b[1]) << 8) |
                (UInt32(b[2]) << 16) |
                (UInt32(b[3]) << 24)
        }
    }
}

private enum OWONParser {
    static func parse(_ data: Data) throws -> OWONFile {
        guard data.count >= 10 else { throw OWONParserError.fileTooShort(data.count) }

        var cursor = DataCursor(data: data)

        guard let signatureData = cursor.readData(count: 6) else {
            throw OWONParserError.fileTooShort(data.count)
        }
        let signature = String(data: signatureData, encoding: .ascii) ?? "<nicht ASCII>"
        guard signature == "SPBXDS" else {
            throw OWONParserError.invalidSignature(signature)
        }

        guard let jsonLength32 = cursor.readUInt32LE() else {
            throw OWONParserError.fileTooShort(data.count)
        }
        let jsonLength = Int(jsonLength32)
        guard jsonLength >= 0, jsonLength <= cursor.remaining else {
            throw OWONParserError.invalidJSONLength(jsonLength, available: cursor.remaining)
        }

        guard let rawJSON = cursor.readData(count: jsonLength) else {
            throw OWONParserError.invalidJSONLength(jsonLength, available: cursor.remaining)
        }

        let waveform: Waveform
        do {
            waveform = try decodeOWONJSON(rawJSON)
        } catch {
            throw OWONParserError.invalidJSON(error)
        }

        let sampleByteCounts = waveform.channel.map { channel -> Int? in
            guard let samples = Int(channel.Data_Length), samples >= 0 else { return nil }
            return samples.multipliedReportingOverflow(by: 2).overflow ? nil : samples * 2
        }

        var channels: [Data] = []
        let expectedChannels = max(1, waveform.channel.count)

        for channelIndex in 0..<expectedChannels {
            guard cursor.remaining > 0 else { break }

            let blockStart = cursor.offset

            // Current XDS format: UInt32 byte count before every channel block.
            if cursor.remaining >= 4, let declared32 = cursor.readUInt32LE() {
                let declared = Int(declared32)
                let expected = channelIndex < sampleByteCounts.count ? sampleByteCounts[channelIndex] : nil

                // Treat the UInt32 as a block length only if it is plausible. This keeps
                // compatibility with older files where raw samples may directly follow JSON.
                let plausibleLength = declared > 0 && declared <= cursor.remaining && declared % 2 == 0
                let agreesWithMetadata = expected == nil || expected == declared

                if plausibleLength && agreesWithMetadata {
                    guard let channelData = cursor.readData(count: declared) else {
                        throw OWONParserError.invalidChannelLength(
                            channel: channelIndex + 1,
                            declared: declared,
                            available: cursor.remaining
                        )
                    }
                    channels.append(channelData)
                    continue
                }
            }

            // Legacy fallback: no 4-byte block length. Rewind and use Data_Length from JSON.
            cursor = DataCursor(data: data, offset: blockStart)
            guard channelIndex < sampleByteCounts.count, let expected = sampleByteCounts[channelIndex] else {
                throw OWONParserError.truncatedLengthField(offset: blockStart)
            }
            guard expected <= cursor.remaining else {
                throw OWONParserError.invalidChannelLength(
                    channel: channelIndex + 1,
                    declared: expected,
                    available: cursor.remaining
                )
            }
            guard let channelData = cursor.readData(count: expected) else {
                throw OWONParserError.invalidChannelLength(
                    channel: channelIndex + 1,
                    declared: expected,
                    available: cursor.remaining
                )
            }
            channels.append(channelData)
        }

        guard !channels.isEmpty else { throw OWONParserError.noChannelData }
        return OWONFile(waveform: waveform, channels: channels, jsonLength: jsonLength)
    }

    private static func decodeOWONJSON(_ data: Data) throws -> Waveform {
        do {
            return try JSONDecoder().decode(Waveform.self, from: data)
        } catch {
            // Some OWON firmware versions emit trailing commas, e.g. "},]}".
            // Foundation's JSONDecoder correctly rejects this, so remove only commas
            // immediately followed by ']' or '}' and decode again.
            guard var text = String(data: data, encoding: .utf8) else { throw error }
            text = text.replacingOccurrences(
                of: #",\s*(\]|\})"#,
                with: "$1",
                options: .regularExpression
            )
            guard let repaired = text.data(using: .utf8) else { throw error }
            return try JSONDecoder().decode(Waveform.self, from: repaired)
        }
    }
}

class ViewController: NSViewController, NSWindowDelegate {
    @IBOutlet weak var channelViewOutlet: ChannelView!
    @IBOutlet weak var infolabel: NSTextField!
    @IBOutlet weak var ch1InfoLabel: NSTextField!
    @IBOutlet weak var ch2InfoLabel: NSTextField!

    override func viewDidLoad() {
        super.viewDidLoad()

        configureChannelScrollView()
    }

    // Abstände außerhalb des Bordered Scroll View. Sie werden beim ersten
    // Anzeigen aus dem Storyboard-Layout ermittelt und bleiben beim Resizing konstant.
    private var windowHorizontalExtra: CGFloat = 0.0
    private var windowVerticalExtra: CGFloat = 0.0
    private var scrollBorderWidth: CGFloat = 0.0
    private var scrollBorderHeight: CGFloat = 0.0
    private var resizeGeometryReady = false

    override func viewDidAppear() {
        super.viewDidAppear()

        syncChannelViewToVisibleArea()
        captureResizeGeometry()

        // Nicht das ganze Fenster hat ein fixes Seitenverhältnis: Unter dem Grid
        // befinden sich drei Labelzeilen. Darum berechnet der Window-Delegate die
        // passende Gegenrichtung so, dass nur der Grid-/Clip-Bereich stets 14:10 bleibt.
        view.window?.contentAspectRatio = .zero
        view.window?.delegate = self

        // Auch die im Storyboard gespeicherte Startgröße sofort auf ein exakt
        // quadratisches Raster korrigieren. Die Breite bleibt dabei unverändert.
        if let window = view.window, resizeGeometryReady {
            let currentWidth = view.bounds.width
            let targetHeight = contentHeight(forContentWidth: currentWidth)
            if abs(targetHeight - view.bounds.height) > 0.1 {
                window.setContentSize(NSSize(width: currentWidth, height: targetHeight))
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        syncChannelViewToVisibleArea()
    }

    private func captureResizeGeometry() {
        guard let scrollView = channelViewOutlet.enclosingScrollView else { return }

        // Der zusätzliche Platz umfasst die Außenränder und den gesamten Bereich
        // mit Filename-, CH1- und CH2-Label. Dieser Teil wird nicht skaliert.
        windowHorizontalExtra = view.bounds.width - scrollView.frame.width
        windowVerticalExtra = view.bounds.height - scrollView.frame.height

        // Beim Bezel liegt der tatsächliche Zeichenbereich etwas innerhalb des
        // Scroll-View-Rahmens (im Storyboard z. B. 700x500 -> 698x498).
        scrollBorderWidth = scrollView.frame.width - scrollView.contentView.bounds.width
        scrollBorderHeight = scrollView.frame.height - scrollView.contentView.bounds.height

        resizeGeometryReady = windowHorizontalExtra >= 0.0 &&
            windowVerticalExtra >= 0.0 &&
            scrollBorderWidth >= 0.0 &&
            scrollBorderHeight >= 0.0
    }

    /// Liefert die notwendige Content-Höhe für eine vorgegebene Content-Breite.
    /// Der tatsächliche ChannelView (ClipView) hat immer 14:10, damit alle
    /// Rasterkästchen quadratisch bleiben.
    private func contentHeight(forContentWidth contentWidth: CGFloat) -> CGFloat {
        let scrollWidth = max(scrollBorderWidth + 14.0, contentWidth - windowHorizontalExtra)
        let gridWidth = max(14.0, scrollWidth - scrollBorderWidth)
        let gridHeight = gridWidth * 10.0 / 14.0
        let scrollHeight = gridHeight + scrollBorderHeight
        return scrollHeight + windowVerticalExtra
    }

    /// Umkehrfunktion zu contentHeight(forContentWidth:), wenn der Benutzer
    /// überwiegend in vertikaler Richtung zieht.
    private func contentWidth(forContentHeight contentHeight: CGFloat) -> CGFloat {
        let scrollHeight = max(scrollBorderHeight + 10.0, contentHeight - windowVerticalExtra)
        let gridHeight = max(10.0, scrollHeight - scrollBorderHeight)
        let gridWidth = gridHeight * 14.0 / 10.0
        let scrollWidth = gridWidth + scrollBorderWidth
        return scrollWidth + windowHorizontalExtra
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard resizeGeometryReady else { return frameSize }

        // Rahmenanteile (Titelleiste etc.) vom Fenster auf den Content umrechnen.
        let chromeWidth = sender.frame.width - view.bounds.width
        let chromeHeight = sender.frame.height - view.bounds.height
        var proposedContentWidth = max(1.0, frameSize.width - chromeWidth)
        var proposedContentHeight = max(1.0, frameSize.height - chromeHeight)

        let widthDelta = abs(frameSize.width - sender.frame.width)
        let heightDelta = abs(frameSize.height - sender.frame.height)

        // Je nachdem, welche Richtung der Benutzer stärker verändert, wird die
        // andere Dimension nachgeführt. Dadurch funktioniert auch Ziehen an einer
        // horizontalen oder vertikalen Fensterkante sinnvoll.
        if heightDelta > widthDelta {
            proposedContentWidth = contentWidth(forContentHeight: proposedContentHeight)
        } else {
            proposedContentHeight = contentHeight(forContentWidth: proposedContentWidth)
        }

        return NSSize(width: proposedContentWidth + chromeWidth,
                      height: proposedContentHeight + chromeHeight)
    }

    private func configureChannelScrollView() {
        guard let scrollView = channelViewOutlet.enclosingScrollView else { return }

        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none

        syncChannelViewToVisibleArea()
    }

    private func syncChannelViewToVisibleArea() {
        guard let scrollView = channelViewOutlet.enclosingScrollView else { return }

        let clipView = scrollView.contentView
        let visibleSize = clipView.bounds.size

        if channelViewOutlet.frame.origin != .zero || channelViewOutlet.frame.size != visibleSize {
            channelViewOutlet.frame = NSRect(origin: .zero, size: visibleSize)
        }

        clipView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(clipView)
        channelViewOutlet.needsDisplay = true
    }

    override var representedObject: Any? {
        didSet { }
    }


    private func channelInfoText(prefix: String, channel: Channel?, data: [UInt8]) -> String {
        guard let channel = channel, !data.isEmpty else {
            return "\(prefix): —"
        }

        let samples = data.count / 2
        return "\(prefix): samples=\(samples), rate=\(channel.Sample_Rate), Vscale=\(channel.Vscale)"
    }

    @IBAction func openDocument(_ sender: NSMenuItem) {
        guard let url = NSOpenPanel().selectUrl else { return }

        print("file selected  = \(url.path)")
        print("filename       = \(url.lastPathComponent)")
        print("pathExtension  = \(url.pathExtension)")
        infolabel.stringValue = "Filename: \(url.lastPathComponent)"

        do {
            let data = try Data(contentsOf: url)
            let owonFile = try OWONParser.parse(data)

            print("file size      = \(data.count)")
            print("jsonlength     = \(owonFile.jsonLength)")
            print("MODEL          = \(owonFile.waveform.MODEL)")
            print("IDN            = \(owonFile.waveform.IDN)")

            for (index, channel) in owonFile.waveform.channel.enumerated() {
                let actualBytes = index < owonFile.channels.count ? owonFile.channels[index].count : 0
                print("\(channel.Index): samples=\(channel.Data_Length), bytes=\(actualBytes), rate=\(channel.Sample_Rate), Vscale=\(channel.Vscale)")
            }

            let channel1 = owonFile.channels.indices.contains(0) ? [UInt8](owonFile.channels[0]) : []
            let channel2 = owonFile.channels.indices.contains(1) ? [UInt8](owonFile.channels[1]) : []

            channelViewOutlet.addChannels(
                channel1.count, channel1,
                channel2.count, channel2
            )

            let channelDescriptions = owonFile.waveform.channel
            ch1InfoLabel.stringValue = channelInfoText(
                prefix: "CH1",
                channel: channelDescriptions.indices.contains(0) ? channelDescriptions[0] : nil,
                data: channel1
            )
            ch2InfoLabel.stringValue = channelInfoText(
                prefix: "CH2",
                channel: channelDescriptions.indices.contains(1) ? channelDescriptions[1] : nil,
                data: channel2
            )

            infolabel.stringValue = "Filename: \(url.lastPathComponent) — \(channel1.count / 2) Samples CH1" +
                (channel2.isEmpty ? "" : ", \(channel2.count / 2) Samples CH2")

        } catch {
            channelViewOutlet.addChannels(0, [], 0, [])
            ch1InfoLabel.stringValue = "CH1: —"
            ch2InfoLabel.stringValue = "CH2: —"
            infolabel.stringValue = "Fehler: \(error.localizedDescription)"
            presentError(error)
            print("OWON parse error: \(error)")
        }
    }
}

