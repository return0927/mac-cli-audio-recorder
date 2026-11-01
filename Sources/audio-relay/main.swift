import AVFoundation
import CoreAudio
import Foundation

let usage = """
audio-relay — 지금 듣고 있는 소리(AirPods / 오디오 인터페이스 출력)를 그대로 파일로 녹음

사용법:
  audio-relay list [--all]                 오디오를 쓰는 앱 목록 (♪ = 지금 재생 중)
  audio-relay record [옵션]                녹음 시작 (Ctrl+C 로 종료)

record 옵션:
  -a, --app <이름|PID>   이 앱의 소리만 녹음 (여러 번 지정 가능). 생략하면 시스템 전체
  -o, --output <파일>    저장 경로. 확장자로 형식 결정: .m4a(AAC, 기본) .wav .aiff .caf
  -d, --duration <초>    지정한 시간만큼 녹음 후 자동 종료 (--wait 이면 녹음 시작 시점부터)
  -w, --wait             소리가 감지될 때까지 대기했다가 그때부터 녹음
      --threshold <dB>   --wait 의 감지 기준 음량 (기본 -50, 예: -40 이면 더 큰 소리에만 반응)
      --pre-roll <초>    --wait 시 감지 직전 구간도 포함 (기본 0.5, 앞부분 잘림 방지)

예:
  audio-relay record
  audio-relay record --app chrome -o lecture.m4a
  audio-relay record -a Zoom -a Slack -d 3600 -o meeting.wav
  audio-relay record --wait --app spotify -o song.m4a
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("error: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func err(_ s: String) { FileHandle.standardError.write(s.data(using: .utf8)!) }

// MARK: - list

func runList(all: Bool) throws {
    let procs = try audioProcesses().filter { $0.pid != getpid() }
    // Group helper processes under their responsible app.
    let groups = Dictionary(grouping: procs) { $0.appName }
        .map { (app: $0.key, procs: $0.value, playing: $0.value.contains(where: \.isPlaying)) }
        .filter { all || $0.playing }
        .sorted { ($0.playing ? 0 : 1, $0.app.lowercased()) < ($1.playing ? 0 : 1, $1.app.lowercased()) }

    print("출력 장치: \(defaultOutputDeviceName())\n")
    if groups.isEmpty {
        print(all ? "오디오를 사용하는 프로세스가 없습니다."
                  : "지금 소리를 내는 앱이 없습니다. (전체 목록: audio-relay list --all)")
        return
    }
    for g in groups {
        let bundle = g.procs.first?.appBundleID ?? ""
        print("\(g.playing ? "♪" : " ") \(g.app)\(bundle.isEmpty ? "" : "  (\(bundle))")")
        for p in g.procs.sorted(by: { $0.pid < $1.pid }) {
            print("    \(p.isPlaying ? "♪" : " ") pid \(p.pid)  \(p.name)")
        }
    }
}

// MARK: - record

func defaultOutputURL() -> URL {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return URL(fileURLWithPath: "recording-\(f.string(from: Date())).m4a")
}

func formatTime(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%02d:%02d", s / 60, s % 60)
}

func meter(_ peak: Float) -> String {
    let db = peak > 0 ? 20 * log10(peak) : -120
    let width = 20
    let filled = max(0, min(width, Int((db + 60) / 60 * Float(width))))
    let bar = String(repeating: "█", count: filled) + String(repeating: "·", count: width - filled)
    return db <= -120 ? "[\(bar)]   -∞ dB" : String(format: "[%@] %5.1f dB", bar, db)
}

func runRecord(apps: [String], output: URL, duration: Double?, trigger: Recorder.Trigger?) throws {
    let matcher: (() -> [AudioObjectID])?
    var label = "시스템 전체"
    if apps.isEmpty {
        matcher = nil
    } else {
        let all = try audioProcesses()
        let found = apps.flatMap { matchProcesses($0, in: all) }
        if found.isEmpty {
            fail("'\(apps.joined(separator: ", "))' 에 해당하는 오디오 프로세스가 없습니다. "
                 + "앱에서 소리를 한 번 재생한 뒤 `audio-relay list --all` 로 확인하세요.")
        }
        label = Set(found.map(\.appName)).sorted().joined(separator: ", ")
        matcher = {
            let all = (try? audioProcesses()) ?? []
            return Array(Set(apps.flatMap { matchProcesses($0, in: all) }.map(\.objectID)))
        }
    }

    if FileManager.default.fileExists(atPath: output.path) {
        fail("\(output.path) 파일이 이미 있습니다.")
    }

    let recorder = Recorder(matcher: matcher, trigger: trigger)
    do {
        try recorder.start(writingTo: output)
    } catch {
        recorder.stop()
        try? FileManager.default.removeItem(at: output)
        throw error
    }

    let fmt = recorder.format!
    err("""
    ● 녹음 대상: \(label)
      듣는 장치: \(defaultOutputDeviceName()) (그대로 계속 들립니다)
      파일:      \(output.path)  (\(Int(fmt.sampleRate)) Hz, \(fmt.channelCount)ch)
      종료:      Ctrl+C\(duration.map { " 또는 \(formatTime($0)) 후 자동" } ?? "")
    \(trigger.map { String(format: "  시작:      %.0f dB 이상 소리가 감지되면 (직전 %.1f초 포함)\n", 20 * log10($0.threshold), $0.preRoll) } ?? "")

    """)

    let started = Date()
    var warnedSilence = false
    var sawAnySignal = false
    var announcedTrigger = false
    var finished = false

    func finish(_ reason: String) {
        guard !finished else { return }
        finished = true
        recorder.stop()
        if recorder.triggeredAt == nil {
            try? FileManager.default.removeItem(at: output)
            err("\n\(reason) — 소리가 감지되지 않아 파일을 만들지 않았습니다.\n")
            exit(0)
        }
        let secs = Double(recorder.framesWritten) / fmt.sampleRate
        err("\n\(reason) — \(formatTime(secs)) 저장됨: \(output.path)\n")
        if !recorder.heardSound {
            err("""
            ⚠︎ 녹음된 소리가 전부 무음입니다. 재생 중인 소리가 없었거나, 시스템 오디오 녹음 권한이 없는 것입니다.
              시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 녹음 → '시스템 오디오 녹음 전용'에서
              이 명령을 실행한 터미널 앱을 허용한 뒤 다시 실행하세요.

            """)
        }
        exit(recorder.writeError == nil ? 0 : 1)
    }

    // Ctrl+C / kill
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { finish("녹음 종료") }
        src.resume()
        sources.append(src)
    }

    // Live status line
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: .milliseconds(200))
    timer.setEventHandler {
        if let e = recorder.writeError {
            err("\n파일 쓰기 오류: \(e)\n")
            finish("중단")
        }
        let peak = recorder.takePeak()
        if peak > 0 { sawAnySignal = true }

        guard let triggeredAt = recorder.triggeredAt else {
            let waited = Date().timeIntervalSince(started)
            err("\r\u{1B}[2K◌ 대기 중 \(formatTime(waited))  \(meter(peak))")
            if !warnedSilence, waited > 10, !sawAnySignal {
                warnedSilence = true
                err("\n  (10초째 완전 무음: 재생 중인 소리가 없거나 '시스템 오디오 녹음' 권한이 필요할 수 있어요)\n")
            }
            return
        }
        if trigger != nil, !announcedTrigger {
            announcedTrigger = true
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            err("\r\u{1B}[2K  소리 감지 — \(f.string(from: triggeredAt))부터 녹음 시작\n")
        }

        let elapsed = Date().timeIntervalSince(triggeredAt)
        err("\r\u{1B}[2K● REC \(formatTime(elapsed))  \(meter(peak))")
        if trigger == nil, !warnedSilence, elapsed > 5, !recorder.heardSound {
            warnedSilence = true
            err("\n  (5초째 무음: 재생 중인 소리가 없거나 '시스템 오디오 녹음' 권한이 필요할 수 있어요)\n")
        }
        if let duration, elapsed >= duration { finish("지정 시간 도달") }
    }
    timer.resume()

    withExtendedLifetime((sources, timer)) { dispatchMain() }
}

// MARK: - argument parsing

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

func value(after flag: String) -> String {
    guard !args.isEmpty else { fail("\(flag) 뒤에 값이 필요합니다.") }
    return args.removeFirst()
}

do {
    switch command {
    case "list", "ls":
        try runList(all: args.contains("--all") || args.contains("-a"))

    case "record", "rec":
        var apps: [String] = []
        var output: URL?
        var duration: Double?
        var wait = false
        var thresholdDB: Float = -50
        var preRoll = 0.5
        while !args.isEmpty {
            let a = args.removeFirst()
            switch a {
            case "-a", "--app": apps.append(value(after: a))
            case "-o", "--output": output = URL(fileURLWithPath: (value(after: a) as NSString).expandingTildeInPath)
            case "-d", "--duration":
                guard let d = Double(value(after: a)), d > 0 else { fail("--duration 은 양수(초)여야 합니다.") }
                duration = d
            case "-w", "--wait": wait = true
            case "--threshold":
                guard let t = Float(value(after: a)), t < 0, t > -120 else {
                    fail("--threshold 는 -120 ~ 0 사이의 dB 값이어야 합니다. (예: -50)")
                }
                thresholdDB = t
            case "--pre-roll":
                guard let p = Double(value(after: a)), p >= 0, p <= 10 else {
                    fail("--pre-roll 은 0 ~ 10 초 사이여야 합니다.")
                }
                preRoll = p
            case "-h", "--help": print(usage); exit(0)
            default: fail("알 수 없는 옵션: \(a)\n\n\(usage)")
            }
        }
        let trigger = wait ? Recorder.Trigger(threshold: pow(10, thresholdDB / 20), preRoll: preRoll) : nil
        try runRecord(apps: apps, output: output ?? defaultOutputURL(), duration: duration, trigger: trigger)

    case "-h", "--help", "help":
        print(usage)

    default:
        fail("알 수 없는 명령: \(command)\n\n\(usage)")
    }
} catch {
    fail("\(error)")
}
