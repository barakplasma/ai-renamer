import Base
import ./Core.bend as Core

type Parsed is Data:
  Args{path: String, settings: List<&2, String>}
  Invalid{message: String}
  Help{}
  Version{}
  Rollback{id: String}
  Runs{}

def pick_key(index: U32) -> String:
  match index:
    case 0: "defaultProvider"
    case 1: "defaultApiKey"
    case 2: "defaultBaseURL"
    case 3: "defaultModel"
    case 4: "defaultFrames"
    case 5: "defaultCase"
    case 6: "defaultChars"
    case 7: "defaultLanguage"
    case 8: "defaultIncludeSubdirectories"
    case 9: "defaultCustomPrompt"
    case 10: "defaultJobs"
    case _: ""

def config_key(+flag: String) -> String:
  +long = Core.style_index(String.split("--provider --api-key --base-url --model --frames --case --chars --language --include-subdirectories --custom-prompt --jobs", ' '), flag, 0)
  short = Core.style_index(String.split("-p -a -u -m -f -c -x -l -s -r -j", ' '), flag, 0)
  Core.or_default(pick_key(long), pick_key(short))

def finish(+path: String, options: List<&2, String>, missing: Bool) -> Parsed:
  match missing:
    case True{}:
      Invalid{"Please provide a file or folder path."}
    case False{}:
      Args{path, List.reverse(&2, String, options)}

type Step is Data:
  Input{path: String}
  Setting{key: String}
  Positional{}
  Stop{result: Parsed}

def positional(+raw: String, is_option: Bool, path_free: Bool) -> Step:
  match is_option path_free:
    case True{} _:
      Stop{Invalid{"Unknown option: " ++ raw}}
    case False{} True{}:
      Input{raw}
    case False{} False{}:
      Stop{Invalid{"Unexpected argument: " ++ raw}}

def keyed(key: String, +raw: String, free: Bool) -> Step:
  match key:
    case SNil{}:
      positional(raw, String.starts_with(raw, "-"), free)
    case SCon{head, tail}:
      Setting{SCon{head, tail}}

def step(+raw: String, path_free: Bool, help: Bool, version: Bool, literal: Bool) -> Step:
  match help version literal:
    case True{} _ _:
      Stop{Help{}}
    case _ True{} _:
      Stop{Version{}}
    case _ _ True{}:
      Positional{}
    case _ _ _:
      keyed(config_key(raw), raw, path_free)

def next_step(+raw: String, path_free: Bool, literal: Bool) -> Step:
  match literal:
    case True{}:
      positional(raw, False{}, path_free)
    case False{}:
      step(raw, path_free, String.eq(raw, "-h") || String.eq(raw, "--help"),
        String.eq(raw, "--version"), String.eq(raw, "--"))

type ParseState is Data:
  Parsing{pending: String, path: String, settings: List<&2, String>, literal: Bool}
  Halted{result: Parsed}

def parse_step(action: Step, path: String, settings: List<&2, String>, literal: Bool) -> ParseState:
  match action:
    case Stop{result}:
      Halted{result}
    case Input{value}:
      Parsing{"", value, settings, literal}
    case Positional{}:
      Parsing{"", path, settings, True{}}
    case Setting{key}:
      Parsing{key, path, settings, literal}

def inline_setting(key: String, value: String, path: String, settings: List<&2, String>) -> ParseState:
  match key:
    case SNil{}:
      Halted{Invalid{"Unknown option."}}
    case SCon{head, tail}:
      Parsing{"", path, value <> SCon{head, tail} <> settings, False{}}

def update_option(parts: List<&2, String>, +path: String, settings: List<&2, String>, raw: String) -> ParseState:
  match parts:
    case Con{option, Con{first, rest}}:
      inline_setting(config_key(option), String.join(first <> rest, "="), path, settings)
    case _:
      parse_step(next_step(raw, String.is_empty(path), False{}), path, settings, False{})

def update_argument(is_long_option: Bool, literal: Bool, +raw: String, +path: String, settings: List<&2, String>) -> ParseState:
  match is_long_option literal:
    case True{} False{}:
      update_option(String.split(raw, '='), path, settings, raw)
    case _ +mode:
      parse_step(next_step(raw, String.is_empty(path), mode), path, settings, mode)

def update_pending(pending: String, path: String, settings: List<&2, String>, literal: Bool, +raw: String) -> ParseState:
  match pending:
    case SNil{}:
      update_argument(String.starts_with(raw, "--"), literal, raw, path, settings)
    case SCon{h, t}:
      Parsing{"", path, raw <> SCon{h, t} <> settings, literal}

def update(state: ParseState, raw: String) -> ParseState:
  match state:
    case Halted{result}:
      Halted{result}
    case Parsing{pending, path, settings, literal}:
      update_pending(pending, path, settings, literal, raw)

def finish_state(state: ParseState) -> Parsed:
  match state:
    case Halted{result}:
      result
    case Parsing{SNil{}, +path, settings, _}:
      finish(path, settings, String.is_empty(path))
    case Parsing{SCon{h, t}, _, _, _}:
      Invalid{"Missing value for " ++ SCon{h, t}}

def parse_go(args: List<String>, state: ParseState) -> Parsed:
  match args:
    case Nil{}:
      finish_state(state)
    case Con{raw, tail}:
      parse_go(tail, update(state, raw))

def rollback_only(args: List<String>) -> Parsed:
  match args:
    case Con{id, Nil{}}:
      Rollback{id}
    case _:
      Invalid{"Usage: ai-renamer --rollback RUN_ID"}

def is_special(+operation: String) -> U32:
  (Bool.to_u32(String.eq(operation, "--rollback")) + 2 * Bool.to_u32(String.eq(operation, "--list-runs")) : U32)

def list_only(args: List<String>) -> Parsed:
  match args:
    case Nil{}:
      Runs{}
    case _:
      Invalid{"Usage: ai-renamer --list-runs"}

def parse_entry(mode: U32, operation: String, rest: List<String>) -> Parsed:
  match mode:
    case 1:
      rollback_only(rest)
    case 2:
      list_only(rest)
    case _:
      parse_go(operation <> rest, Parsing{"", "", [], False{}})

def parse(args: List<String>) -> Parsed:
  match args:
    case Nil{}:
      parse_go([], Parsing{"", "", [], False{}})
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

def help() -> String:
  "Usage: ai-renamer PATH [options]\n       ai-renamer --rollback RUN_ID\n       ai-renamer --list-runs\n\n" ++
  "  -p, --provider                ollama, lm-studio, openai (default: ollama)\n" ++
  "  -a, --api-key                 API key for an OpenAI-compatible endpoint\n" ++
  "  -u, --base-url                Provider endpoint\n" ++
  "  -m, --model                   Model name (defaults to automatic selection)\n" ++
  "  -f, --frames                  Maximum video frames (default: 3)\n" ++
  "  -c, --case                    Filename case style (default: kebabCase)\n" ++
  "  -x, --chars                   Maximum stem length (default: 20)\n" ++
  "  -l, --language                Output language (default: English)\n" ++
  "  -s, --include-subdirectories  true or false (default: false)\n" ++
  "  -r, --custom-prompt           Additional model instructions\n" ++
  "  -j, --jobs                    Parallel requests, 1–64 (default: 16)\n" ++
  "  -h, --help                    Show help\n" ++
  "      --version                 Show version"
