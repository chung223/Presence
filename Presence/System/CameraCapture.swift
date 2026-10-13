import AVFoundation
import Foundation

/// 裝置不在附近時有人手動解鎖，就用相機拍一張照片存證。只存在這台 Mac 上。
enum CameraCapture {
    static var authorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    static var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Presence/Photos", isDirectory: true)
    }

    /// 拍一張照片存成 JPEG，回傳檔案位置；沒有權限或失敗回傳 nil。
    static func capturePhoto() async -> URL? {
        guard authorization == .authorized, let directory else { return nil }
        guard let data = await Task.detached(operation: { await PhotoTaker().take() }).value else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent("unlock-\(formatter.string(from: Date())).jpg")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// 刪掉超過指定天數的照片。
    static func removePhotos(olderThan days: Int) {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        for file in files {
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantFuture
            if created < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }
}

/// AVFoundation 在自己的佇列上回呼，所以不跟主執行緒綁在一起。
private nonisolated final class PhotoTaker: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?

    func take() async -> Data? {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input), session.canAddOutput(output) else { return nil }
        session.beginConfiguration()
        session.sessionPreset = .photo
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
        defer { session.stopRunning() }

        // 剛開相機時畫面偏暗，等曝光穩定
        try? await Task.sleep(for: .milliseconds(1500))
        return await withCheckedContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
            // 保險：5 秒內沒有回呼就放棄
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [self] in finish(nil) }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        finish(error == nil ? photo.fileDataRepresentation() : nil)
    }

    private func finish(_ data: Data?) {
        let pending = lock.withLock { () -> CheckedContinuation<Data?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: data)
    }
}
