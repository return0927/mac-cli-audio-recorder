import AppKit
import CoreAudio
import Darwin

/// A process that Core Audio knows about (i.e. has an audio client).
struct AudioProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isPlaying: Bool
    /// The process's own name (e.g. "Google Chrome Helper", "WebKit GPU").
    let name: String
    /// The app responsible for it (e.g. "Google Chrome", "Safari").
    let appName: String
    let appBundleID: String
}

// Private-but-stable libSystem call that maps helper processes (Chrome Helper,
// WebKit GPU process, ...) back to the app that launched them.
private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
private let responsibleFn: ResponsibleFn? = {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
    else { return nil }
    return unsafeBitCast(sym, to: ResponsibleFn.self)
}()

private func responsiblePID(_ pid: pid_t) -> pid_t {
    guard let fn = responsibleFn else { return pid }
    let r = fn(pid)
    return r > 0 ? r : pid
}

private func processName(_ pid: pid_t) -> String {
    if let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName { return n }
    var buf = [CChar](repeating: 0, count: 1024)
    if proc_name(pid, &buf, UInt32(buf.count)) > 0 { return String(cString: buf) }
    return "pid \(pid)"
}

func audioProcesses() throws -> [AudioProcess] {
    try getObjectList(systemObject, kAudioHardwarePropertyProcessObjectList).compactMap { id in
        guard let pid = try? getValue(id, kAudioProcessPropertyPID, initial: pid_t(-1)), pid > 0 else { return nil }
        let playing = (try? getValue(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
        let rpid = responsiblePID(pid)
        let app = NSRunningApplication(processIdentifier: rpid)
        return AudioProcess(
            objectID: id,
            pid: pid,
            bundleID: getString(id, kAudioProcessPropertyBundleID) ?? "",
            isPlaying: playing != 0,
            name: processName(pid),
            appName: app?.localizedName ?? processName(rpid),
            appBundleID: app?.bundleIdentifier ?? ""
        )
    }
}

/// Finds every audio process belonging to the app matching `query`
/// (case-insensitive substring of app name / bundle ID, or an exact PID).
func matchProcesses(_ query: String, in all: [AudioProcess]) -> [AudioProcess] {
    if let pid = pid_t(query) {
        return all.filter { $0.pid == pid || responsiblePID($0.pid) == pid }
    }
    let q = query.lowercased()
    return all.filter {
        $0.appName.lowercased().contains(q) || $0.appBundleID.lowercased().contains(q)
            || $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q)
    }
}
