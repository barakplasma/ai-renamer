import Base
import 0x597f8af3f77d8983aacfa076df42d235/main.bend as Json
import 0x597f8af3f77d8983aacfa076df42d235/src/value.bend as Value

def string_or_empty(value: Maybe<&2, String>) -> String:
  match value:
    case Some{text}: text
    case None{}: ""

def string(value: Value.Json) -> String:
  string_or_empty(Json.as_str(value))

def parse_string(parsed: Maybe<&2, Value.Json>) -> String:
  match parsed:
    case Some{json}: string(json)
    case None{}: ""
