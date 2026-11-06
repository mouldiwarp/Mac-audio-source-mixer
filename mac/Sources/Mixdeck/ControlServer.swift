import Foundation
import Network

/// Local text API on TCP 127.0.0.1 (spec/features/control-and-recording.md §4).
@MainActor
final class ApiServer {
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private let handle: (String) -> [String]
    private(set) var status = "off"

    init(handle: @escaping (String) -> [String]) { self.handle = handle }

    func start(port: Int) {
        stop()
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: UInt16(port)))
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in Task { @MainActor in self?.accept(c) } }
            l.stateUpdateHandler = { [weak self] st in
                Task { @MainActor in
                    switch st {
                    case .ready: self?.status = "listening on 127.0.0.1:\(port)"
                    case .failed(let e): self?.status = "failed: \(e)"
                    default: break
                    }
                }
            }
            l.start(queue: .main)
            listener = l
            status = "starting…"
        } catch {
            status = "failed: \(error)"
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        clients.values.forEach { $0.cancel() }
        clients.removeAll()
        status = "off"
    }

    private func accept(_ c: NWConnection) {
        guard clients.count < 8 else { c.cancel(); return }
        let key = ObjectIdentifier(c)
        clients[key] = c
        c.stateUpdateHandler = { [weak self] st in
            if case .cancelled = st { Task { @MainActor in self?.clients[key] = nil } }
            if case .failed = st { Task { @MainActor in self?.clients[key] = nil } }
        }
        c.start(queue: .main)
        receive(c, pending: "")
    }

    private func receive(_ c: NWConnection, pending: String) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                var buf = pending
                if let data, let s = String(data: data, encoding: .utf8) { buf += s }
                // Run everything up to the last complete statement.
                if let cut = buf.lastIndex(where: { $0 == ";" || $0 == "\n" }) {
                    let script = String(buf[...cut])
                    buf = String(buf[buf.index(after: cut)...])
                    let replies = self.handle(script)
                    if !replies.isEmpty { c.send(content: (replies.joined(separator: "\n") + "\n").data(using: .utf8), completion: .contentProcessed { _ in }) }
                }
                if complete || error != nil {
                    if !buf.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let replies = self.handle(buf)
                        if !replies.isEmpty { c.send(content: (replies.joined(separator: "\n") + "\n").data(using: .utf8), completion: .contentProcessed { _ in c.cancel() }); return }
                    }
                    c.cancel()
                    return
                }
                self.receive(c, pending: buf)
            }
        }
    }
}

/// OSC 1.0 over UDP 127.0.0.1 (spec §5).
@MainActor
final class OscServer {
    struct Message { var address: String; var args: [ControlValue] }

    private var listener: NWListener?
    private var peers: [NWConnection] = []
    /// Returns the reply value for a query (no arguments), or nil.
    private let handle: (Message) -> ControlValue?
    private(set) var status = "off"

    init(handle: @escaping (Message) -> ControlValue?) { self.handle = handle }

    func start(port: Int) {
        stop()
        do {
            let params = NWParameters.udp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(integerLiteral: UInt16(port)))
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in Task { @MainActor in self?.accept(c) } }
            l.stateUpdateHandler = { [weak self] st in
                Task { @MainActor in
                    switch st {
                    case .ready: self?.status = "listening on 127.0.0.1:\(port)"
                    case .failed(let e): self?.status = "failed: \(e)"
                    default: break
                    }
                }
            }
            l.start(queue: .main)
            listener = l
            status = "starting…"
        } catch {
            status = "failed: \(error)"
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        peers.forEach { $0.cancel() }
        peers.removeAll()
        status = "off"
    }

    private func accept(_ c: NWConnection) {
        if peers.count >= 16 { peers.removeFirst().cancel() }
        peers.append(c)
        c.start(queue: .main)
        receive(c)
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self else { return }
                if let data {
                    for m in Self.decode(data) {
                        if let reply = self.handle(m) {
                            c.send(content: Self.encode(Message(address: m.address, args: [reply])), completion: .contentProcessed { _ in })
                        }
                    }
                }
                if error == nil { self.receive(c) }
            }
        }
    }

    // MARK: Wire format

    nonisolated static func decode(_ d: Data) -> [Message] {
        let b = [UInt8](d)
        var pos = 0
        func str() -> String? {
            guard let end = b[pos...].firstIndex(of: 0) else { return nil }
            let s = String(decoding: b[pos..<end], as: UTF8.self)
            pos = (end + 4) & ~3
            return s
        }
        func u32() -> UInt32? {
            guard pos + 4 <= b.count else { return nil }
            defer { pos += 4 }
            return UInt32(b[pos]) << 24 | UInt32(b[pos + 1]) << 16 | UInt32(b[pos + 2]) << 8 | UInt32(b[pos + 3])
        }
        guard let addr = str() else { return [] }
        if addr == "#bundle" {
            pos += 8   // time tag
            var out: [Message] = []
            while pos < b.count, let len = u32(), pos + Int(len) <= b.count {
                out += decode(Data(b[pos..<pos + Int(len)]))
                pos += Int(len)
            }
            return out
        }
        var args: [ControlValue] = []
        if pos < b.count, let tags = str(), tags.hasPrefix(",") {
            for t in tags.dropFirst() {
                switch t {
                case "f": if let v = u32() { args.append(.number(Double(Float(bitPattern: v)))) }
                case "i": if let v = u32() { args.append(.number(Double(Int32(bitPattern: v)))) }
                case "d": if let hi = u32(), let lo = u32() { args.append(.number(Double(bitPattern: UInt64(hi) << 32 | UInt64(lo)))) }
                case "s": if let s = str() { args.append(.string(s)) }
                case "T": args.append(.number(1))
                case "F": args.append(.number(0))
                default: break
                }
            }
        }
        return [Message(address: addr, args: args)]
    }

    nonisolated static func encode(_ m: Message) -> Data {
        var out = Data()
        func pad(_ s: String) { var d = Data(s.utf8); d.append(0); while d.count % 4 != 0 { d.append(0) }; out.append(d) }
        func u32(_ v: UInt32) { out.append(contentsOf: [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]) }
        pad(m.address)
        pad("," + m.args.map { if case .string = $0 { return "s" } else { return "f" } }.joined())
        for a in m.args {
            switch a {
            case .number(let d): u32(Float(d).bitPattern)
            case .string(let s): pad(s)
            }
        }
        return out
    }
}
