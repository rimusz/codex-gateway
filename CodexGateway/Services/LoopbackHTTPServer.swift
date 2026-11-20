import Foundation
import Network
import zlib

typealias HTTPHandler = (_ request: HTTPRequest, _ response: HTTPResponse) -> Void

struct HTTPRequest {
  let method: String
  let path: String
  let query: String
  let headers: [String: String]
  let body: Data
  var isWebSocketUpgrade: Bool {
    (headers["upgrade"]?.lowercased() == "websocket") && headers["sec-websocket-key"] != nil
  }
  var webSocketKey: String? { headers["sec-websocket-key"] }

  /// Headers safe to forward after the gateway has decoded the request body locally.
  var forwardHeaders: [String: String] {
    let skip: Set<String> = [
      "host", "connection", "content-length", "transfer-encoding", "content-encoding",
      "proxy-connection", "keep-alive", "te", "trailer", "upgrade"
    ]
    return headers.filter { !skip.contains($0.key.lowercased()) }
  }
}

final class HTTPResponse: @unchecked Sendable {
  private let connection: NWConnection
  private var sent = false
  private var streaming = false
  private var outbound: [Data] = []
  private var sending = false
  private var finishAfterFlush = false
  private let queue: DispatchQueue

  init(connection: NWConnection, queue: DispatchQueue) {
    self.connection = connection
    self.queue = queue
  }

  func send(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
    queue.async {
      guard !self.sent else { return }
      self.sent = true
      var allHeaders = headers
      if allHeaders["Content-Length"] == nil && !body.isEmpty {
        allHeaders["Content-Length"] = "\(body.count)"
      }
      if allHeaders["Connection"] == nil { allHeaders["Connection"] = "close" }
      var data = HTTPResponse.headerBlock(status: status, headers: allHeaders)
      data.append(body)
      self.enqueueOnQueue(data, end: true)
    }
  }

  /// HTTP 200 head for a chunked SSE body. Further bytes go out through `writeChunk`.
  func startStream(status: Int = 200, headers: [String: String] = [:]) {
    queue.async {
      guard !self.sent else { return }
      self.sent = true
      self.streaming = true
      var allHeaders = headers
      allHeaders.removeValue(forKey: "Content-Length")
      allHeaders["Transfer-Encoding"] = "chunked"
      allHeaders["Connection"] = "close"
      self.enqueueOnQueue(HTTPResponse.headerBlock(status: status, headers: allHeaders), end: false)
    }
  }

  func writeChunk(_ body: Data) {
    guard !body.isEmpty else { return }
    let frame = HTTPResponse.chunkFrame(body)
    queue.async {
      guard self.streaming else { return }
      self.enqueueOnQueue(frame, end: false)
    }
  }

  func endStream() {
    queue.async {
      guard self.streaming else { return }
      self.streaming = false
      self.enqueueOnQueue(Data("0\r\n\r\n".utf8), end: true)
    }
  }

  static func chunkFrame(_ data: Data) -> Data {
    var frame = Data(String(data.count, radix: 16).utf8)
    frame.append(Data("\r\n".utf8))
    frame.append(data)
    frame.append(Data("\r\n".utf8))
    return frame
  }

  private static func headerBlock(status: Int, headers: [String: String]) -> Data {
    var headerLines = ["HTTP/1.1 \(status) \(statusText(status))"]
    for (key, value) in headers { headerLines.append("\(key): \(value)") }
    return Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
  }

  /// Caller is already on `queue`. Sends are chained because NWConnection allows one outstanding send.
  private func enqueueOnQueue(_ data: Data, end: Bool) {
    if !data.isEmpty { outbound.append(data) }
    if end { finishAfterFlush = true }
    pump()
  }

  private func pump() {
    guard !sending else { return }
    if outbound.isEmpty {
      if finishAfterFlush {
        finishAfterFlush = false
        connection.cancel()
      }
      return
    }
    let data = outbound.removeFirst()
    sending = true
    // Retain self until this send finishes and pump() runs again. The request
    // handler returns as soon as endStream() is queued; those queued blocks are
    // the only other retains. A weak completion drops them when the last block
    // returns, deallocating HTTPResponse while later frames (the function_call
    // item, response.completed, and the terminating 0-chunk) are still in
    // `outbound`, and connection.cancel() never runs. The retain ends once
    // outbound is empty and finishAfterFlush cancels the connection.
    connection.send(content: data, completion: .contentProcessed { _ in
      self.queue.async {
        self.sending = false
        self.pump()
      }
    })
  }

  func upgradeWebSocket(key: String, onSession: @escaping (WebSocketSession) -> Void) {
    queue.async {
      guard !self.sent else { return }
      self.sent = true
      let accept = WebSocketHandshake.accept(key: key)
      let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
      self.connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
        let session = WebSocketSession(connection: self.connection, queue: self.queue)
        onSession(session)
      })
    }
  }

  private static func statusText(_ code: Int) -> String {
    switch code {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 404: return "Not Found"
    case 500: return "Internal Server Error"
    default: return "OK"
    }
  }
}

enum WebSocketMessage {
  case text(String)
  case binary(Data)
}

enum WebSocketHandshake {
  static func accept(key: String) -> String {
    let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    let data = Data((key + magic).utf8)
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    _ = data.withUnsafeBytes { CC_SHA1($0.baseAddress, CC32(data.count), &hash) }
    return Data(hash).base64EncodedString()
  }
}

import CommonCrypto

final class WebSocketSession {
  private let connection: NWConnection
  private let queue: DispatchQueue
  private var buffer = Data()

  init(connection: NWConnection, queue: DispatchQueue) {
    self.connection = connection
    self.queue = queue
  }

  func start(onMessage: @escaping (WebSocketMessage) -> Void, onClose: @escaping () -> Void) {
    receive(onMessage: onMessage, onClose: onClose)
  }

  func send(text: String) {
    guard let payload = text.data(using: .utf8) else { return }
    send(frame: encodeFrame(opcode: 0x1, payload: payload))
  }

  func send(binary: Data) {
    send(frame: encodeFrame(opcode: 0x2, payload: binary))
  }

  private func send(frame: Data) {
    connection.send(content: frame, completion: .contentProcessed { _ in })
  }

  private func receive(onMessage: @escaping (WebSocketMessage) -> Void, onClose: @escaping () -> Void) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, _, error in
      guard let self else { return }
      if error != nil { onClose(); return }
      guard let data, !data.isEmpty else {
        self.receive(onMessage: onMessage, onClose: onClose)
        return
      }
      self.buffer.append(data)
      while let (opcode, payload, consumed) = self.parseFrame() {
        self.buffer.removeFirst(consumed)
        switch opcode {
        case 0x1:
          if let text = String(data: payload, encoding: .utf8) { onMessage(.text(text)) }
        case 0x2:
          onMessage(.binary(payload))
        case 0x8:
          onClose()
          return
        case 0x9:
          self.send(frame: self.encodeFrame(opcode: 0xA, payload: payload))
        default:
          break
        }
      }
      self.receive(onMessage: onMessage, onClose: onClose)
    }
  }

  private func parseFrame() -> (UInt8, Data, Int)? {
    guard buffer.count >= 2 else { return nil }
    let b0 = buffer[0]
    let b1 = buffer[1]
    let opcode = b0 & 0x0F
    let masked = (b1 & 0x80) != 0
    var length = Int(b1 & 0x7F)
    var index = 2
    if length == 126 {
      guard buffer.count >= 4 else { return nil }
      length = Int(buffer[2]) << 8 | Int(buffer[3])
      index = 4
    } else if length == 127 {
      guard buffer.count >= 10 else { return nil }
      length = 0
      for i in 0..<8 { length = length << 8 | Int(buffer[2 + i]) }
      index = 10
    }
    let maskSize = masked ? 4 : 0
    guard buffer.count >= index + maskSize + length else { return nil }
    var payload = buffer.subdata(in: index + maskSize ..< index + maskSize + length)
    if masked {
      let mask = buffer[index..<index+4]
      for i in 0..<payload.count { payload[i] ^= mask[mask.startIndex + (i % 4)] }
    }
    return (opcode, payload, index + maskSize + length)
  }

  private func encodeFrame(opcode: UInt8, payload: Data) -> Data {
    var frame = Data([0x80 | opcode])
    if payload.count < 126 {
      frame.append(UInt8(payload.count))
    } else if payload.count < 65536 {
      frame.append(126)
      frame.append(UInt8((payload.count >> 8) & 0xFF))
      frame.append(UInt8(payload.count & 0xFF))
    } else {
      frame.append(127)
      for shift in stride(from: 56, through: 0, by: -8) {
        frame.append(UInt8((payload.count >> shift) & 0xFF))
      }
    }
    frame.append(payload)
    return frame
  }
}

final class LoopbackHTTPServer {
  private var listener: NWListener?
  private let queue = DispatchQueue(label: "com.rimusz.CodexGateway.http", qos: .userInitiated)
  var handler: HTTPHandler?

  func start(host: String = Paths.gatewayHost, port: UInt16 = Paths.gatewayPort) throws {
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    // Pin the listener to the loopback address so the gateway is only reachable from
    // this machine — never from the LAN. (A bare port would bind all interfaces.)
    params.requiredLocalEndpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host(host),
      port: NWEndpoint.Port(rawValue: port)!
    )
    listener = try NWListener(using: params)
    listener?.newConnectionHandler = { [weak self] connection in
      self?.handle(connection)
    }
    listener?.start(queue: queue)
    GatewayLog.info("Listening on http://\(host):\(port) (loopback only)")
  }

  func stop() {
    listener?.cancel()
    listener = nil
  }

  private func handle(_ connection: NWConnection) {
    connection.start(queue: queue)
    var data = Data()
    func read() {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 80 * 1024 * 1024) { [weak self] chunk, _, isComplete, error in
        guard let self else { return }
        if let chunk { data.append(chunk) }
        if let request = self.parseRequest(data, isComplete: isComplete) {
          let response = HTTPResponse(connection: connection, queue: self.queue)
          self.handler?(request, response)
        } else if error == nil && !isComplete {
          read()
        } else {
          connection.cancel()
        }
      }
    }
    read()
  }

  private func parseRequest(_ data: Data, isComplete: Bool) -> HTTPRequest? {
    guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let headerData = data.subdata(in: 0..<headerRange.lowerBound)
    guard let raw = String(data: headerData, encoding: .utf8) else { return nil }
    let headerPart = raw
    let lines = headerPart.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
    guard parts.count >= 2 else { return nil }
    let method = parts[0]
    let urlParts = parts[1].split(separator: "?", maxSplits: 1).map(String.init)
    let path = urlParts[0]
    let query = urlParts.count > 1 ? urlParts[1] : ""
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let idx = line.firstIndex(of: ":") else { continue }
      let key = String(line[..<idx]).trimmingCharacters(in: .whitespaces).lowercased()
      let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
      headers[key] = value
    }
    let bodyStart = headerRange.upperBound
    let rawBody = data.subdata(in: bodyStart..<data.count)
    let body: Data
    switch HTTPRequestParser.extractBody(method: method, headers: headers, rawBody: rawBody, isComplete: isComplete) {
    case .needMoreData:
      return nil
    case .ready(let extracted):
      body = HTTPBodyDecoder.decodeContentEncoding(extracted, headers: headers)
    }
    return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
  }
}

enum HTTPRequestParser {
  private static let bodyMethods: Set<String> = ["POST", "PUT", "PATCH"]

  enum BodyResult: Equatable {
    case needMoreData
    case ready(Data)
  }

  static func extractBody(method: String, headers: [String: String], rawBody: Data, isComplete: Bool) -> BodyResult {
    if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
      guard let decoded = HTTPBodyDecoder.decodeChunked(rawBody) else { return .needMoreData }
      return .ready(decoded)
    }

    if let contentLength = headers["content-length"], let len = Int(contentLength) {
      guard rawBody.count >= len else { return .needMoreData }
      return .ready(rawBody.subdata(in: 0..<len))
    }

    if bodyMethods.contains(method.uppercased()) {
      if rawBody.isEmpty, !isComplete {
        return .needMoreData
      }
      return .ready(rawBody)
    }

    return .ready(Data())
  }
}

enum HTTPBodyDecoder {
  static func decodeContentEncoding(_ body: Data, headers: [String: String]) -> Data {
    let encoding = headers["content-encoding"]?.lowercased() ?? ""
    guard !encoding.isEmpty else {
      if body.count >= 4, body[0] == 0x28, body[1] == 0xB5, body[2] == 0x2F, body[3] == 0xFD,
         let decoded = ZstdBridge.decompress(body) {
        return decoded
      }
      return body
    }
    if encoding.contains("gzip") || encoding.contains("x-gzip") {
      return gunzip(body) ?? body
    }
    if encoding.contains("zstd") || encoding.contains("x-zstd") {
      return ZstdBridge.decompress(body) ?? body
    }
    return body
  }

  static func gunzip(_ data: Data) -> Data? {
    guard data.count >= 10, data[0] == 0x1f, data[1] == 0x8b else { return nil }

    var stream = z_stream()
    let initStatus = inflateInit2_(&stream, MAX_WBITS + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    guard initStatus == Z_OK else { return nil }
    defer { inflateEnd(&stream) }

    let chunkSize = 65_536
    var output = Data()
    var status: Int32 = Z_OK

    data.withUnsafeBytes { inputBuffer in
      guard let inputBase = inputBuffer.baseAddress?.assumingMemoryBound(to: Bytef.self) else { return }
      stream.next_in = UnsafeMutablePointer(mutating: inputBase)
      stream.avail_in = uInt(data.count)

      var buffer = [UInt8](repeating: 0, count: chunkSize)
      repeat {
        buffer.withUnsafeMutableBytes { outputBuffer in
          stream.next_out = outputBuffer.baseAddress!.assumingMemoryBound(to: Bytef.self)
          stream.avail_out = uInt(chunkSize)
        }
        status = inflate(&stream, Z_SYNC_FLUSH)
        if status == Z_OK || status == Z_STREAM_END {
          output.append(buffer, count: chunkSize - Int(stream.avail_out))
        }
      } while status == Z_OK
    }

    return status == Z_STREAM_END ? output : nil
  }

  static func decodeChunked(_ data: Data) -> Data? {
    let crlf = Data("\r\n".utf8)
    var index = data.startIndex
    var decoded = Data()

    while index < data.endIndex {
      guard let lineRange = data.range(of: crlf, options: [], in: index..<data.endIndex),
            let sizeLine = String(data: data.subdata(in: index..<lineRange.lowerBound), encoding: .utf8) else {
        return nil
      }

      let sizeText = sizeLine.split(separator: ";", maxSplits: 1).first.map(String.init) ?? sizeLine
      guard let size = Int(sizeText.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else {
        return nil
      }

      let payloadStart = lineRange.upperBound
      if size == 0 {
        return data.count >= payloadStart + crlf.count ? decoded : nil
      }

      let payloadEnd = payloadStart + size
      let nextChunkStart = payloadEnd + crlf.count
      guard data.count >= nextChunkStart,
            data.subdata(in: payloadEnd..<nextChunkStart) == crlf else {
        return nil
      }

      decoded.append(data.subdata(in: payloadStart..<payloadEnd))
      index = nextChunkStart
    }

    return nil
  }
}

private typealias CC32 = CC_LONG
