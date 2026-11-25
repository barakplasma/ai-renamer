import Base
import 0x64697f57fea19681b5fa4f87014ce63d/main.bend as Shake

type Parsed is Data:
  Args{path: String, settings: List<&2, String>}
  Invalid{message: String}
  Help{}
  Version{}
  Rollback{id: String}
  Runs{}

type Option is Data:
  Option{key: String, short: String, long: String, description: String}

def options() -> List<&2, Option>:
  [Option{"defaultProvider", "p", "provider", "Model provider (default: ollama)"},
   Option{"defaultApiKey", "a", "api-key", "API key for an OpenAI-compatible endpoint"},
   Option{"defaultBaseURL", "u", "base-url", "Provider endpoint"},
   Option{"defaultModel", "m", "model", "Model name (default: automatic selection)"},
   Option{"defaultFrames", "f", "frames", "Maximum video frames (default: 3)"},
   Option{"defaultCase", "c", "case", "Filename case style (default: kebabCase)"},
   Option{"defaultChars", "x", "chars", "Maximum stem length (default: 20)"},
   Option{"defaultLanguage", "l", "language", "Output language (default: English)"},
   Option{"defaultIncludeSubdirectories", "s", "include-subdirectories", "true or false (default: false)"},
   Option{"defaultCustomPrompt", "r", "custom-prompt", "Additional model instructions"},
   Option{"defaultJobs", "j", "jobs", "Parallel requests, 1–64 (default: 16)"}]

def option_args(options: List<&2, Option>) -> List<&2, Shake.Arg>:
  match options:
    case Nil{}:
      []
    case Con{Option{key, short, long, description}, rest}:
      Shake.many(key, Some{short}, Some{long}, description, False{}, None{}, []) <> option_args(rest)

def spec() -> Shake.Cli:
  Shake.app("ai-renamer", "Rename files from their contents.", Some{"2.1.0"},
    Shake.pos("path", "File or folder to rename", True{}, None{}, []) <> option_args(options()), [])

def prepend_value(found: List<&2, String>, key: String, rest: List<&2, String>) -> List<&2, String>:
  match found:
    case Nil{}:
      rest
    case Con{value, _}:
      key <> value <> rest

def read_settings(options: List<&2, Option>, +found: Shake.Matched) -> List<&2, String>:
  match options:
    case Nil{}:
      []
    case Con{Option{+key, _, _, _}, rest}:
      prepend_value(Shake.get_all(found, key), key, read_settings(rest, found))

def read_match(path: Maybe<&2, String>, found: Shake.Matched) -> Parsed:
  match path:
    case Some{value}:
      Args{value, read_settings(options(), found)}
    case None{}:
      Invalid{"Please provide a file or folder path."}

def read_error(help: Maybe<&2, List<&2, String>>, version: Maybe<&2, String>, err: Shake.ParseErr) -> Parsed:
  match help version:
    case Some{_} _:
      Help{}
    case _ Some{_}:
      Version{}
    case _ _:
      Invalid{Shake.err_text(spec(), err)}

def read_parse(answer: Result<&2, &2, Shake.ParseErr, Shake.Matched>) -> Parsed:
  match answer:
    case Done{+found}:
      read_match(Shake.get(found, "path"), found)
    case Fail{+err}:
      read_error(Shake.help_path(err), Shake.version_of(spec(), err), err)

def rollback_only(args: List<&2, String>) -> Parsed:
  match args:
    case Con{id, Nil{}}:
      Rollback{id}
    case _:
      Invalid{"Usage: ai-renamer --rollback RUN_ID"}

def is_special(+operation: String) -> U32:
  (Bool.to_u32(String.eq(operation, "--rollback")) + 2 * Bool.to_u32(String.eq(operation, "--list-runs")) : U32)

def list_only(args: List<&2, String>) -> Parsed:
  match args:
    case Nil{}:
      Runs{}
    case _:
      Invalid{"Usage: ai-renamer --list-runs"}

def parse_entry(mode: U32, operation: String, rest: List<&2, String>) -> Parsed:
  match mode:
    case 1:
      rollback_only(rest)
    case 2:
      list_only(rest)
    case _:
      read_parse(Shake.parse(spec(), operation <> rest))

def parse(args: List<&2, String>) -> Parsed:
  match args:
    case Nil{}:
      Invalid{"Please provide a file or folder path."}
    case Con{+head, tail}:
      parse_entry(is_special(head), head, tail)

def value_at(found: Bool, value: String, fallback: String) -> String:
  match found:
    case True{}:
      value
    case False{}:
      fallback

def get(options: List<&2, String>, +key: String) -> String:
  match options:
    case Con{name, Con{value, tail}}:
      value_at(String.eq(name, key), value, get(tail, key))
    case _:
      ""

def argv() -> IO(List<&2, String>):
  Shake.argv()

def help() -> String:
  Shake.help(spec(), []) ++ "\nDocuments:\n  Set DOCLING_SERVE_URL and optionally DOCLING_SERVE_API_KEY.\n\nRecovery:\n  ai-renamer --rollback RUN_ID\n  ai-renamer --list-runs"
