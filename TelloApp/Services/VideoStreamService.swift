// VideoStreamService.swift
// Tello text-SDK: raw H264 on UDP port 11111.
// Each UDP packet either starts with 00 00 00 01 (new NAL) or is a continuation.
// We accumulate bytes and emit a NAL each time we see a new start code.
// SPS/PPS are hardcoded (constant across all Tello drones).
//
// Performance fixes:
//   - Frame enqueue runs on a dedicated serial video queue, NOT main thread
//   - Zero-copy packet handling: uses UnsafeBufferPointer instead of Array copies
//   - nalBuf pre-reserved capacity to avoid repeated reallocs
//   - displayLayer.controlTimebase removed; uses host clock directly

import Foundation
import AVFoundation
import VideoToolbox
import UIKit

final class VideoStreamService {

    static let shared = VideoStreamService()
    private init() { prebuildFmtDesc() }

    let displayLayer: AVSampleBufferDisplayLayer = {
        let l = AVSampleBufferDisplayLayer()
        l.videoGravity    = .resizeAspect
        l.backgroundColor = UIColor.black.cgColor
        // Immediate display — do not buffer/reorder frames
        l.preventsDisplaySleepDuringVideoPlayback = false
        return l
    }()

    // Hardcoded SPS/PPS — same for every Tello (confirmed from pcap)
    private let kSPS = Data([0x67, 0x4d, 0x40, 0x28, 0x95, 0xa0, 0x3c, 0x05, 0xb9])
    private let kPPS = Data([0x68, 0xee, 0x38, 0x80])

    private var sock:         Int32 = -1
    private var running       = false
    private var fmtDesc:      CMVideoFormatDescription?
    private var waitingForIDR = true
    private var frameCount    = 0

    // Dedicated serial queue for all video work — keeps main thread free
    private let videoQueue = DispatchQueue(label: "tello.video", qos: .userInteractive)

    // NAL accumulation buffer — pre-reserved to avoid reallocs
    private var nalBuf = Data(capacity: 128 * 1024)

    // MARK: - Public
    func start() {
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.running       = true
            self.waitingForIDR = true
            self.nalBuf        = Data(capacity: 128 * 1024)
            self.frameCount    = 0
            self.openAndReceive()
        }
    }

    func stop() {
        running = false
        if sock >= 0 { Darwin.close(sock); sock = -1 }
    }

    // MARK: - Format description
    private func prebuildFmtDesc() {
        fmtDesc = makeFmtDesc(sps: kSPS, pps: kPPS)
        if let d = fmtDesc {
            let dim = CMVideoFormatDescriptionGetDimensions(d)
            print("[Video] ✅ Pre-built format description \(dim.width)×\(dim.height)")
        }
    }

    private func makeFmtDesc(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var desc: CMVideoFormatDescription?
        let ok = sps.withUnsafeBytes { sp in
            pps.withUnsafeBytes { pp in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2,
                    parameterSetPointers: [
                        sp.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        pp.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    ],
                    parameterSetSizes: [sps.count, pps.count],
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc)
            }
        }
        return ok == noErr ? desc : nil
    }

    // MARK: - Receive loop (runs on videoQueue)
    private func openAndReceive() {
        sock = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var rcvbuf: Int32 = 4 * 1024 * 1024
        setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout.size(ofValue: rcvbuf)))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family      = sa_family_t(AF_INET)
        addr.sin_port        = UInt16(11111).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        print("[Video] bind(:11111) = \(bindResult) errno=\(bindResult < 0 ? errno : 0)")
        print("[Video] Listening on :11111")

        // Stack-allocated receive buffer — no heap allocation per packet
        var buf = [UInt8](repeating: 0, count: 65536)
        var pktCount = 0

        while running {
            let n = Darwin.recv(sock, &buf, buf.count, 0)
            if n < 0 {
                if errno == EBADF || errno == EINVAL { break }
                continue
            }
            guard n > 0 else { continue }
            pktCount += 1

            if pktCount <= 5 {
                let hex = buf.prefix(12).map { String(format:"%02x",$0) }.joined(separator:" ")
                print("[Video] PKT#\(pktCount) size=\(n) bytes: \(hex)")
            }

            // Pass a direct pointer — no Array copy
            buf.withUnsafeBufferPointer { ptr in
                handlePacket(ptr, count: n)
            }
        }
        print("[Video] Recv loop ended after \(pktCount) packets")
    }

    // MARK: - Per-packet handler (zero-copy: works with raw pointer)
    private func handlePacket(_ pkt: UnsafeBufferPointer<UInt8>, count: Int) {
        guard count > 0 else { return }

        // Detect start code at the beginning of this packet
        var scLen = 0
        if count >= 4 && pkt[0]==0 && pkt[1]==0 && pkt[2]==0 && pkt[3]==1 { scLen = 4 }
        else if count >= 3 && pkt[0]==0 && pkt[1]==0 && pkt[2]==1 { scLen = 3 }

        if scLen > 0 {
            // New NAL starting — flush the previous one first
            if !nalBuf.isEmpty {
                processNAL(nalBuf)
                nalBuf.removeAll(keepingCapacity: true)  // keeps the reserved 128KB
            }
            // Append new NAL bytes (skip start code)
            nalBuf.append(contentsOf: UnsafeBufferPointer(start: pkt.baseAddress! + scLen, count: count - scLen))
        } else {
            // Continuation — append to current NAL
            nalBuf.append(contentsOf: UnsafeBufferPointer(start: pkt.baseAddress!, count: count))
        }

        // Safety cap — drop corrupt/oversized NAL
        if nalBuf.count > 200 * 1024 {
            nalBuf.removeAll(keepingCapacity: true)
            waitingForIDR = true
        }
    }

    // MARK: - Process a complete NAL
    private func processNAL(_ nal: Data) {
        guard !nal.isEmpty else { return }
        let nalType = nal[0] & 0x1F

        switch nalType {
        case 7: // SPS
            print("[Video] Got SPS \(nal.hex)")
            if nal != kSPS, let d = makeFmtDesc(sps: nal, pps: kPPS) {
                fmtDesc = d; waitingForIDR = true
            }
        case 8: // PPS
            print("[Video] Got PPS \(nal.hex)")
        case 5: // IDR
            print("[Video] Got IDR size=\(nal.count)")
            waitingForIDR = false
            decode(nal)
        case 1: // P-frame
            if waitingForIDR { return }
            decode(nal)
        default:
            break
        }
    }

    // MARK: - Decode & enqueue (stays on videoQueue — no main-thread hop)
    private func decode(_ nal: Data) {
        guard let fmt = fmtDesc else {
            print("[Video] ❌ No fmtDesc!")
            return
        }

        // Build AVCC-framed copy (4-byte big-endian length prefix + NAL bytes)
        var avcc = Data(capacity: 4 + nal.count)
        var lenBE = UInt32(nal.count).bigEndian
        avcc.append(Data(bytes: &lenBE, count: 4))
        avcc.append(nal)
        let avccLen = avcc.count

        var blockBuf: CMBlockBuffer?
        let bErr = avcc.withUnsafeMutableBytes { ptr in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: ptr.baseAddress,
                blockLength: avccLen, blockAllocator: kCFAllocatorNull,
                customBlockSource: nil, offsetToData: 0,
                dataLength: avccLen, flags: 0, blockBufferOut: &blockBuf)
        }
        guard bErr == kCMBlockBufferNoErr, let bb = blockBuf else { return }

        var sampleBuf: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid)
        var sz = avccLen
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: bb, formatDescription: fmt,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sz,
            sampleBufferOut: &sampleBuf) == noErr,
              let sb = sampleBuf else { return }

        frameCount += 1
        if frameCount <= 5 { print("[Video] ✅ Decoded frame #\(frameCount) NAL=\(nal[0] & 0x1F) size=\(nal.count)") }

        // AVSampleBufferDisplayLayer is thread-safe for enqueue — no main-thread dispatch needed
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sb)
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
