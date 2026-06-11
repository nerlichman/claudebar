import Darwin
import Foundation

enum ProcessLiveness {
    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        // EPERM: the process exists but we can't signal it — still alive.
        return errno == EPERM
    }

    /// Real process start time from the kernel, for PID-reuse detection.
    static func startTime(of pid: Int32) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        guard tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }

    /// A session file is valid iff its pid is alive AND the kernel's start
    /// time for that pid roughly matches the session's startedAt — otherwise
    /// the pid was reused by an unrelated process after Claude died.
    static func validate(_ file: SessionFile) -> Bool {
        guard isAlive(file.pid) else { return false }
        guard let kernelStart = startTime(of: file.pid) else { return true }
        let claimed = Date(timeIntervalSince1970: file.startedAt / 1000)
        return abs(kernelStart.timeIntervalSince(claimed)) <= 30
    }
}
