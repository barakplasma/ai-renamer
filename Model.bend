import Base
import ./Core.bend as Core
import ./Host.bend as Host
import ./JsonData.bend as JsonData
import 0x597f8af3f77d8983aacfa076df42d235/main.bend as Json
import 0x597f8af3f77d8983aacfa076df42d235/src/value.bend as Value

def trim_slashes(path: String) -> String:
  match path:
    case SCon{'/', rest}:
      trim_slashes(rest)
    case _:
      path

def endpoint(base: String, +route: String) -> String:
  +trimmed = String.reverse(trim_slashes(String.reverse(base)))
  trimmed ++ Core.choose_match(
    String.ends_with(trimmed, "/v1") && String.starts_with(route, "/v1/"), String.drop(route, 3n), route)

def response_error(status: String, body: Value.Json) -> Host.Reply:
  +detail = Json.get(body, "error")
  +reason = Core.or_default(JsonData.string(detail), JsonData.string(Json.get(detail, "message")))
  Host.Error{"HTTP " ++ status ++ Core.choose_match(String.is_empty(reason), "", ": " ++ reason)}

def model_names(items: List<&2, Value.Json>) -> List<&2, String>:
  match items:
    case Nil{}: []
    case Con{+item, rest}:
      Core.or_default(JsonData.string(Json.get(item, "id")), JsonData.string(Json.get(item, "name"))) <> model_names(rest)

def response_value(ollama: Bool, discovery: Bool, body: Value.Json) -> Host.Reply:
  match ollama discovery:
    case True{} True{}:
      Host.Output{String.join(model_names(Json.items(Json.get(body, "models"))), "\0")}
    case False{} True{}:
      Host.Output{String.join(model_names(Json.items(Json.get(body, "data"))), "\0")}
    case True{} False{}:
      Host.Output{JsonData.string(Json.get(body, "response"))}
    case False{} False{}:
      item = Json.at(Json.get(body, "choices"), 0)
      Host.Output{JsonData.string(Json.get(Json.get(item, "message"), "content"))}

def response_body(ok: Bool, status: String, body: Maybe<&2, Value.Json>, ollama: Bool, discovery: Bool) -> Host.Reply:
  match ok body:
    case True{} Some{json}:
      response_value(ollama, discovery, json)
    case True{} None{}:
      Host.Error{"Model returned invalid JSON."}
    case False{} Some{json}:
      response_error(status, json)
    case False{} None{}:
      Host.Error{"HTTP " ++ status}

def response_fields(parts: List<&2, String>, ollama: Bool, discovery: Bool) -> Host.Reply:
  match parts:
    case Con{+status, tail}:
      response_body(String.starts_with(status, "2"), status, Json.parse(String.join(tail, "\0")), ollama, discovery)
    case _:
      Host.Error{"Missing HTTP response."}

def response(answer: Host.Reply, ollama: Bool, discovery: Bool) -> Host.Reply:
  match answer:
    case Host.Output{text}:
      response_fields(Host.unpack(text), ollama, discovery)
    case Host.Error{message}:
      Host.Error{message}

def models(+provider: String, base: String, key: String) -> IO(Host.Reply):
  +ollama = String.eq(provider, "ollama")
  route = Core.choose_match(ollama, "/api/tags", "/v1/models")
  do IO<Host.Reply>:
    reply : Host.Reply <- Host.http(endpoint(base, route), Core.choose_match(ollama, "", key), "")
    return response(reply, ollama, True{})

def image_value(mime: String, data: String, ollama: Bool) -> Value.Json:
  match ollama:
    case True{}:
      Json.str(data)
    case False{}:
      url = "data:" ++ mime ++ ";base64," ++ data
      Json.obj([("type", Json.str("image_url")), ("image_url", Json.obj([("url", Json.str(url))]))])

def image_values(fields: List<&2, String>, +ollama: Bool) -> List<&2, Value.Json>:
  match fields:
    case Con{mime, Con{encoded, rest}}:
      image_value(mime, encoded, ollama) <> image_values(rest, ollama)
    case _:
      []

def ollama_fields(+model: String, +prompt: String, images: List<&2, Value.Json>) -> List<&1, String & Value.Json>:
  match images:
    case Nil{}:
      [("model", Json.str(model)), ("stream", Json.bool(False{})), ("prompt", Json.str(prompt))]
    case Con{head, tail}:
      [("model", Json.str(model)), ("stream", Json.bool(False{})), ("prompt", Json.str(prompt)),
        ("images", Json.arr(head <> tail))]

def payload(ollama: Bool, model: String, prompt: String, images: List<&2, Value.Json>) -> Value.Json:
  match ollama:
    case True{}:
      Json.obj(ollama_fields(model, prompt, images))
    case False{}:
      text = Json.obj([("type", Json.str("text")), ("text", Json.str(prompt))])
      message = Json.obj([("role", Json.str("user")), ("content", Json.arr(text <> images))])
      Json.obj([("model", Json.str(model)), ("stream", Json.bool(False{})), ("messages", Json.arr([message]))])

def submit(+ollama: Bool, base: String, key: String, model: String, prompt: String, frames: List<&2, String>) -> IO(Host.Reply):
  route = Core.choose_match(ollama, "/api/generate", "/v1/chat/completions")
  body = Json.print(payload(ollama, model, prompt, image_values(frames, ollama)))
  do IO<Host.Reply>:
    reply : Host.Reply <- Host.http(endpoint(base, route), Core.choose_match(ollama, "", key), body)
    return response(reply, ollama, False{})

def with_media(parts: List<&2, String>, ollama: Bool, base: String, key: String, model: String, prompt: String, custom: String) -> IO(Host.Reply):
  match parts:
    case Con{+context, images}:
      submit(ollama, base, key, model, Core.choose_match(String.is_empty(context), "", context ++ "\n\n") ++ prompt ++ custom, images)
    case _:
      IO.pure(Host.Reply, Host.Error{"No media could be read."})

def with_text(empty: Bool, text: String, ollama: Bool, base: String, key: String, model: String, prompt: String, custom: String) -> IO(Host.Reply):
  match empty:
    case True{}:
      IO.pure(Host.Reply, Host.Error{"No text content."})
    case False{}:
      submit(ollama, base, key, model, prompt ++ "\n\nContent:\n" ++ text ++ custom, [])

def use_material(reply: Host.Reply, media: Bool, ollama: Bool, base: String, key: String, model: String, prompt: String, +custom: String) -> IO(Host.Reply):
  match reply media:
    case Host.Error{message} _:
      IO.pure(Host.Reply, Host.Error{message})
    case Host.Output{text} True{}:
      with_media(Host.unpack(text), ollama, base, key, model, prompt, custom)
    case Host.Output{text} False{}:
      +clean = String.trim(text)
      with_text(String.is_empty(clean), clean, ollama, base, key, model, prompt, custom)

def suggest(provider: String, base: String, key: String, model: String, +kind: String, frames: String, path: String, prompt: String, +custom: String) -> IO(Host.Reply):
  do IO<Host.Reply>:
    data : Host.Reply <- Host.material(kind, frames, path)
    use_material(data, String.eq(kind, "video") || String.eq(kind, "image"), String.eq(provider, "ollama"),
      base, key, model, prompt, Core.choose_match(String.is_empty(custom), "", "\n\nCustom instructions:\n" ++ custom))
