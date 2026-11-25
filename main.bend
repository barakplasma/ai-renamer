import Base
import 0x5fea041be86f1677bfed779e7579233f/files.bend as Files
import 0x0d2a146cd1cbaedf76cc532bcd3594b0/time.bend as Time
import ./Core.bend as Core
import ./Host.bend as Host
import ./Model.bend as Model
import ./Prefs.bend as Prefs
import ./Options.bend as Options
import ./Rollback.bend as Rollback

type Settings is Data:
  Config{provider: String, base: String, key: String, model: String, frames: Nat, style: String,
    chars: Nat, language: String, recursive: String, custom: String, jobs: Nat}

type Target is Data:
  Target{path: String, shown: String, stamp: String}

type Scan is Data:
  Scan{files: List<&2, Target>, directories: List<&2, String>, warnings: List<&2, String>}

type Report is Data:
  Report{message: String, failed: Bool}

def default_url(+provider: String) -> String:
  Core.choose_match(String.eq(provider, "ollama"), "http://127.0.0.1:11434",
    Core.choose_match(String.eq(provider, "lm-studio"), "http://127.0.0.1:1234", "https://api.openai.com"))

def bounded(number: Maybe<&2, Nat>, fallback: Nat, max: Nat) -> Nat:
  match number:
    case None{}:
      fallback
    case Some{value}:
      Nat.max(1n, Nat.min(max, value))

def setting_number(raw: String, fallback: Nat, max: Nat) -> Nat:
  bounded(Nat.read(raw), fallback, max)

def assemble(+fields: List<&2, String>, +provider: String, model: String) -> Settings:
  Config{provider, Core.or_default(Options.get(fields, "defaultBaseURL"), default_url(provider)),
    Options.get(fields, "defaultApiKey"), model, setting_number(Options.get(fields, "defaultFrames"), 3n, 64n),
    Core.or_default(Options.get(fields, "defaultCase"), "kebabCase"), setting_number(Options.get(fields, "defaultChars"), 20n, 255n),
    Core.or_default(Options.get(fields, "defaultLanguage"), "English"), Options.get(fields, "defaultIncludeSubdirectories"),
    Options.get(fields, "defaultCustomPrompt"), setting_number(Options.get(fields, "defaultJobs"), 16n, 64n)}

def keep_file(is_file: Bool, path: String, shown: String, stamp: String, acc: List<&2, Target>) -> List<&2, Target>:
  match is_file:
    case True{}:
      Target{path, shown, stamp} <> acc
    case False{}:
      acc

def record_file(tag: String, path: String, +shown: String, stamp: String, acc: List<&2, Target>) -> List<&2, Target>:
  keep_file(String.eq(tag, "file") && Bool.not(String.eq(shown, ".DS_Store") || String.ends_with(shown, "/.DS_Store")),
    path, shown, stamp, acc)

def keep_line(keep: Bool, line: String, acc: List<&2, String>) -> List<&2, String>:
  match keep:
    case True{}:
      line <> acc
    case False{}:
      acc

def record_dir(tag: String, shown: String, acc: List<&2, String>) -> List<&2, String>:
  keep_line(String.eq(tag, "dir"), shown, acc)

def record_warn(tag: String, shown: String, acc: List<&2, String>) -> List<&2, String>:
  keep_line(String.eq(tag, "warn"), shown, acc)

def read_records(fields: List<&2, String>, files: List<&2, Target>, dirs: List<&2, String>, warnings: List<&2, String>) -> Scan:
  match fields:
    case Con{+tag, Con{path, Con{+shown, Con{stamp, rest}}}}:
      read_records(rest, record_file(tag, path, shown, stamp, files), record_dir(tag, shown, dirs), record_warn(tag, shown, warnings))
    case _:
      Scan{List.reverse(&2, Target, files), List.reverse(&2, String, dirs), List.reverse(&2, String, warnings)}

def log_nonempty(+text: String, empty: Bool) -> IO(Unit):
  match empty:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.print(text)

def log_all(lines: List<&2, String>, +prefix: String) -> IO(Unit):
  match lines:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{line, rest}:
      do IO<Unit>:
        IO.print(prefix ++ line)
        log_all(rest, prefix)

def renamed(reply: Host.Reply, shown: String) -> Report:
  match reply:
    case Host.Output{target}:
      Report{"🟢 Renamed: " ++ shown ++ " to " ++ target, False{}}
    case Host.Error{message}:
      Report{"🔴 Rename error: " ++ shown ++ ": " ++ message, True{}}

def apply_name(+name: String, path: String, +shown: String, stamp: String, empty: Bool) -> IO(Report):
  match empty:
    case True{}:
      IO.pure(Report, Report{"🔴 Model returned no usable filename: " ++ shown, True{}})
    case False{}:
      do IO<Report>:
        result : Host.Reply <- Host.rename_file(path, name, shown, stamp)
        return renamed(result, shown)

def proposed(result: Host.Reply, path: String, shown: String, stamp: String, style: String, chars: Nat) -> IO(Report):
  match result:
    case Host.Output{text}:
      +name = Core.filename(text, style, chars)
      apply_name(name, path, shown, stamp, String.is_empty(name))
    case Host.Error{message}:
      IO.pure(Report, Report{"🔴 Processing error: " ++ shown ++ ": " ++ message, True{}})

def suggest(settings: Settings, +path: String, shown: String, stamp: String, kind: String) -> IO(Report):
  match settings:
    case Config{provider, base, key, model, frames, +style, +chars, language, _, custom, _}:
      do IO<Report>:
        result : Host.Reply <- Model.suggest(provider, base, key, model, kind,
          Nat.show(frames), path, Core.prompt(style, chars, language), custom)
        report : Report <- proposed(result, path, shown, stamp, style, chars)
        return report

def process_kind(kind: Core.FileKind, settings: Settings, path: String, shown: String, stamp: String) -> IO(Report):
  match kind:
    case Core.Image{}:
      suggest(settings, path, shown, stamp, "image")
    case Core.Video{}:
      suggest(settings, path, shown, stamp, "video")
    case Core.PDF{}:
      suggest(settings, path, shown, stamp, "pdf")
    case Core.TextFile{}:
      suggest(settings, path, shown, stamp, "text")
    case Core.Unsupported{}:
      IO.pure(Report, Report{"🟡 Unsupported file: " ++ shown, False{}})

def process_extension(convert: Bool, ext: String, settings: Settings, path: String, shown: String, stamp: String) -> IO(Report):
  match convert:
    case True{}:
      suggest(settings, path, shown, stamp, "docling")
    case False{}:
      process_kind(Core.classify(ext), settings, path, shown, stamp)

def process_path(+ext: String, settings: Settings, path: String, shown: String, stamp: String) -> IO(Report):
  process_extension(Core.docling_extension(ext), ext, settings, path, shown, stamp)

def process_target(target: Target, settings: Settings) -> IO(Report):
  match target:
    case Target{+path, shown, stamp}:
      process_path(Files.path.extension(path), settings, path, shown, stamp)

def send_result(out: Chan(Report), report: Report, next: IO(Unit)) -> IO(Unit):
  do IO<Unit>:
    _ : Result<&1, &1, Report, Unit> <- Chan.send(Report, out, report)
    next

def use_task(item: Maybe<&1, Target>, out: Chan(Report), settings: Settings, next: IO(Unit)) -> IO(Unit):
  match item:
    case None{}:
      IO.pure(Unit, Unit{})
    case Some{target}:
      do IO<Unit>:
        report : Report <- process_target(target, settings)
        send_result(out, report, next)

def worker(fuel: Nat, +inbox: Chan(Target), +out: Chan(Report), +settings: Settings) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+left:
      do IO<Unit>:
        item : Maybe<&1, Target> <- Chan.recv(Target, inbox)
        use_task(item, out, settings, worker(left, inbox, out, settings))

def start_workers(jobs: Nat, +total: Nat, +inbox: Chan(Target), +out: Chan(Report), +settings: Settings) -> IO(Unit):
  match jobs:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+left:
      do IO<Unit>:
        IO.spawn(Unit, worker(total, inbox, out, settings))
        start_workers(left, total, inbox, out, settings)

def enqueue(files: List<&2, Target>, +inbox: Chan(Target)) -> IO(Unit):
  match files:
    case Nil{}:
      Chan.close(Target, inbox)
    case Con{target, rest}:
      do IO<Unit>:
        _ : Result<&1, &1, Target, Unit> <- Chan.send(Target, inbox, target)
        enqueue(rest, inbox)

def report_failed(report: Report) -> Bool:
  match report:
    case Report{_, failed}:
      failed

def show_report(report: Report) -> IO(Unit):
  match report:
    case Report{+message, _}:
      log_nonempty(message, String.is_empty(message))

def ensure_report(item: Maybe<&1, Report>) -> IO(Report):
  match item:
    case None{}:
      IO.die(Report, 1, "Result queue closed before all files completed.")
    case Some{value}:
      IO.pure(Report, value)

def render_progress(done: Nat, total: Nat, started: Nat) -> IO(Unit):
  do IO<Unit>:
    now : Nat <- Time.mono.ms()
    IO.print(Core.progress(done, total, Nat.div(Nat.sub(now, started), 1000n)))

def finish(failed: Bool) -> IO(Unit):
  match failed:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      IO.exit(1)

def report_loop(left: Nat, +done: Nat, +total: Nat, +started: Nat, +out: Chan(Report), +failed: Bool) -> IO(Unit):
  match left:
    case 0n:
      do IO<Unit>:
        Chan.close(Report, out)
        finish(failed)
    case 1n+rest:
      do IO<Unit>:
        item : Maybe<&1, Report> <- Chan.recv(Report, out)
        +report : Report <- ensure_report(item)
        show_report(report)
        render_progress(1n+done, total, started)
        report_loop(rest, 1n+done, total, started, out, failed || report_failed(report))

def announce_journal(result: Host.Reply) -> IO(Unit):
  match result:
    case Host.Error{message}:
      IO.die(Unit, 1, "Cannot start the recovery journal: " ++ message)
    case Host.Output{+id}:
      do IO<Unit>:
        IO.print("Run ID: " ++ id)
        IO.print("Undo this run: ai-renamer --rollback " ++ id)

def start_scan(scan: Scan, +settings: Settings, jobs: Nat) -> IO(Unit):
  match scan:
    case Scan{+files, dirs, +warnings}:
      +total = List.length(&2, Target, files)
      +workers = Nat.min(total, jobs)
      do IO<Unit>:
        journal : Host.Reply <- Host.begin_run()
        announce_journal(journal)
        log_all(dirs, "Processing directory: ")
        log_all(warnings, "🟡 Directory error: ")
        +started : Nat <- Time.mono.ms()
        render_progress(0n, total, started)
        +inbox : Chan(Target) <- Chan.new(Target, U32.from_nat(workers))
        +out : Chan(Report) <- Chan.new(Report, U32.from_nat(workers))
        IO.spawn(Unit, enqueue(files, inbox))
        start_workers(workers, total, inbox, out, settings)
        report_loop(total, 0n, total, started, out, Bool.not(List.is_empty(&2, String, warnings)))

def on_scan(result: Host.Reply, settings: Settings, jobs: Nat) -> IO(Unit):
  match result:
    case Host.Error{message}:
      IO.die(Unit, 1, message)
    case Host.Output{content}:
      start_scan(read_records(Host.unpack(content), [], [], []), settings, jobs)

def run(path: String, +settings: Settings) -> IO(Unit):
  match settings:
    case Config{+provider, +base, _, +model, _, _, _, _, +recursive, _, +jobs}:
      do IO<Unit>:
        IO.print("Provider: " ++ provider ++ "  Model: " ++ model ++ "  Endpoint: " ++ base ++ "  Jobs: " ++ Nat.show(jobs))
        scanned : Host.Reply <- Host.scan(path, recursive)
        on_scan(scanned, settings, jobs)

def on_model(model: String, path: String, fields: List<&2, String>, provider: String) -> IO(Unit):
  match model:
    case SNil{}:
      IO.die(Unit, 1, "No suitable model found.")
    case SCon{head, tail}:
      run(path, assemble(fields, provider, SCon{head, tail}))

def on_models(result: Host.Reply, path: String, fields: List<&2, String>, provider: String) -> IO(Unit):
  match result:
    case Host.Error{message}:
      IO.die(Unit, 1, "Model discovery: " ++ message)
    case Host.Output{+models}:
      do IO<Unit>:
        IO.print("Available models: " ++ String.join(Host.unpack(models), ", "))
        on_model(Core.choose_model(Host.unpack(models)), path, fields, provider)

def discover(is_openai: Bool, path: String, +fields: List<&2, String>, +provider: String) -> IO(Unit):
  match is_openai:
    case True{}:
      on_model("gpt-4o", path, fields, provider)
    case False{}:
      do IO<Unit>:
        result : Host.Reply <- Model.models(provider,
          Core.or_default(Options.get(fields, "defaultBaseURL"), default_url(provider)), Options.get(fields, "defaultApiKey"))
        on_models(result, path, fields, provider)

def resolve(model: String, path: String, fields: List<&2, String>, +provider: String) -> IO(Unit):
  match model:
    case SNil{}:
      discover(String.eq(provider, "openai"), path, fields, provider)
    case SCon{head, tail}:
      on_model(SCon{head, tail}, path, fields, provider)

def validate(allowed: Bool, path: String, +fields: List<&2, String>, provider: String) -> IO(Unit):
  match allowed:
    case True{}:
      resolve(Options.get(fields, "defaultModel"), path, fields, provider)
    case False{}:
      IO.die(Unit, 1, "Supported providers are ollama, lm-studio, and openai.")

def select_provider(path: String, fields: List<&2, String>, +provider: String) -> IO(Unit):
  validate(Core.one_of(["ollama", "lm-studio", "openai"], provider), path, fields, provider)

def with_fields(path: String, +fields: List<&2, String>) -> IO(Unit):
  select_provider(path, fields, Core.or_default(Options.get(fields, "defaultProvider"), "ollama"))

def on_config(config: Host.Reply, path: String) -> IO(Unit):
  match config:
    case Host.Error{message}:
      IO.die(Unit, 1, "Config: " ++ message)
    case Host.Output{raw}:
      with_fields(path, Host.unpack(raw))

def print_host(result: Host.Reply) -> IO(Unit):
  match result:
    case Host.Output{text}:
      IO.print(text)
    case Host.Error{message}:
      IO.die(Unit, 1, message)

def run_rollback(id: String) -> IO(Unit):
  do IO<Unit>:
    result : Host.Reply <- Host.rollback(id, Rollback.policy())
    print_host(result)

def list_runs() -> IO(Unit):
  do IO<Unit>:
    result : Host.Reply <- Host.runs()
    print_host(result)

def start(args: Options.Parsed) -> IO(Unit):
  match args:
    case Options.Rollback{id}:
      run_rollback(id)
    case Options.Runs{}:
      list_runs()
    case Options.Help{}:
      IO.print(Options.help())
    case Options.Version{}:
      IO.print("ai-renamer 2.1.0")
    case Options.Invalid{message}:
      IO.die(Unit, 1, message)
    case Options.Args{path, settings}:
      do IO<Unit>:
        config : Host.Reply <- Prefs.load(settings)
        on_config(config, path)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<&2, String> <- Options.argv()
    start(Options.parse(args))
