import Base
import ./Core.bend as Core
import ./Host.bend as Host
import 0x597f8af3f77d8983aacfa076df42d235/main.bend as Json
import 0x597f8af3f77d8983aacfa076df42d235/src/value.bend as Value

def keys() -> List<&2, String>:
  ["defaultProvider", "defaultApiKey", "defaultBaseURL", "defaultModel", "defaultFrames",
   "defaultCase", "defaultChars", "defaultLanguage", "defaultIncludeSubdirectories", "defaultCustomPrompt", "defaultJobs"]

def fallback_json(parsed: Maybe<&2, Value.Json>) -> Value.Json:
  match parsed:
    case Some{value}: value
    case None{}: Json.obj([])

def bool_string(value: Maybe<&2, Bool>) -> String:
  match value:
    case Some{True{}}: "true"
    case Some{False{}}: "false"
    case None{}: ""

def value_string_fallback(+value: Value.Json, as_text: Maybe<&2, String>, as_number: Maybe<&2, String>) -> String:
  match as_text as_number:
    case Some{text} _: text
    case _ Some{number}: number
    case _ _: bool_string(Json.as_bool(value))

def value_string(+value: Value.Json) -> String:
  value_string_fallback(value, Json.as_str(value), Json.as_num(value))

def lookup(fields: List<&2, String>, +key: String, fallback: String) -> String:
  match fields:
    case Con{name, Con{value, rest}}:
      Core.choose_match(String.eq(name, key), value, lookup(rest, key, fallback))
    case _:
      fallback

def fields(names: List<&2, String>, +json: Value.Json, +overrides: List<&2, String>) -> List<&2, String>:
  match names:
    case Nil{}: []
    case Con{+key, rest}:
      key <> lookup(overrides, key, value_string(Json.get(json, key))) <> fields(rest, json, overrides)

def entries(values: List<&2, String>) -> List<&1, String & Value.Json>:
  match values:
    case Con{key, Con{value, rest}}:
      (key, Json.str(value)) <> entries(rest)
    case _:
      []

def saved(answer: Host.Reply, values: List<&2, String>) -> Host.Reply:
  match answer:
    case Host.Error{message}: Host.Error{message}
    case Host.Output{_}: Host.Output{String.join(values, "\0")}

def save_if_needed(unchanged: Bool, +values: List<&2, String>) -> IO(Host.Reply):
  match unchanged:
    case True{}:
      IO.pure(Host.Reply, Host.Output{String.join(values, "\0")})
    case False{}:
      do IO<Host.Reply>:
        answer : Host.Reply <- Host.save_config(Json.print(Json.obj(entries(values))))
        return saved(answer, values)

def with_loaded(answer: Host.Reply, +overrides: List<&2, String>) -> IO(Host.Reply):
  match answer:
    case Host.Error{message}: IO.pure(Host.Reply, Host.Error{message})
    case Host.Output{text}:
      save_if_needed(List.is_empty(&2, String, overrides), fields(keys(), fallback_json(Json.parse(text)), overrides))

def load(+overrides: List<&2, String>) -> IO(Host.Reply):
  do IO<Host.Reply>:
    answer : Host.Reply <- Host.load_config(Core.choose_match(List.is_empty(&2, String, overrides), "false", "true"))
    with_loaded(answer, overrides)
