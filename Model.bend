import Base
import 0x5fea041be86f1677bfed779e7579233f/files.bend as Files
import 0x92957abd83651a4f5b5d352560a37e03/process.bend as ProcessTools
import 0xec25e4adfb02e59e4b817801115988ee/bytes.bend as Bytes
import 0xe0126415561194eca594bb57287bdd1d/encoding.bend as Encoding
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

def probe_output(status: U32, stdout: Bytes.Bytes, stderr: Bytes.Bytes) -> Host.Reply:
  match status:
    case 0:
      Host.Output{String.trim(Encoding.utf8.decode(stdout))}
    case _:
      Host.Error{"ffprobe failed: " ++ String.trim(Encoding.utf8.decode(stderr))}

def probe_result(result: Result<&1, &1, U32 & String, U32 & Bytes.Bytes & Bytes.Bytes>) -> Host.Reply:
  match result:
    case Fail{(_, message)}:
      Host.Error{"ffprobe: " ++ message}
    case Done{(status, (stdout, stderr))}:
      probe_output(status, stdout, stderr)

def video_material(probe: Host.Reply, frames: String, path: String) -> IO(Host.Reply):
  match probe:
    case Host.Output{duration}:
      Host.material("video", frames, path, duration)
    case Host.Error{message}:
      IO.pure(Host.Reply, Host.Error{message})

def material(video: Bool, kind: String, frames: String, +path: String) -> IO(Host.Reply):
  match video:
    case False{}:
      Host.material(kind, frames, path, "")
    case True{}:
      do IO<Host.Reply>:
        result : Result<&1, &1, U32 & String, U32 & Bytes.Bytes & Bytes.Bytes> <- ProcessTools.run.bounded(
          "ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", path],
          [], ".", Bytes.new(0), 120000, 4096)
        video_material(probe_result(result), frames, path)

def docling_text(+markdown: String, +status: String, usable: Bool) -> Host.Reply:
  match usable:
    case True{}:
      Host.Output{String.take(markdown, 65536n)}
    case False{}:
      Host.Error{"Docling extraction produced no usable Markdown (status: " ++ status ++ ")."}

def docling_document(+status: String, +text: String) -> Host.Reply:
  docling_text(text, status, (String.eq(status, "success") || String.eq(status, "partial_success")) &&
    Bool.not(String.is_empty(String.trim(text))))

def docling_json(parsed: Maybe<&2, Value.Json>) -> Host.Reply:
  match parsed:
    case None{}:
      Host.Error{"Docling returned invalid JSON."}
    case Some{+body}:
      docling_document(JsonData.string(Json.get(body, "status")),
        JsonData.string(Json.get(Json.get(body, "document"), "md_content")))

def docling_status(ok: Bool, code: String, body: String) -> Host.Reply:
  match ok:
    case True{}:
      docling_json(Json.parse(body))
    case False{}:
      Host.Error{"Docling returned HTTP " ++ code ++ "."}

def docling_fields(parts: List<&2, String>) -> Host.Reply:
  match parts:
    case Con{+status, tail}:
      docling_status(String.starts_with(status, "2"), status, String.join(tail, "\0"))
    case _:
      Host.Error{"Docling returned no HTTP response."}

def docling_response(reply: Host.Reply) -> Host.Reply:
  match reply:
    case Host.Output{text}:
      docling_fields(Host.unpack(text))
    case Host.Error{message}:
      Host.Error{"Docling: " ++ message}

def env_value(value: Result<&1, &1, U32 & String, String>) -> String:
  match value:
    case Done{text}: text
    case Fail{_}: ""

def local_document(kind: Core.FileKind, path: String) -> IO(Host.Reply):
  match kind:
    case Core.PDF{}:
      Host.material("pdf", "", path, "")
    case Core.TextFile{}:
      Host.material("text", "", path, "")
    case _:
      IO.pure(Host.Reply, Host.Error{"Set DOCLING_SERVE_URL to extract this document."})

def document_endpoint(+base: String) -> String:
  endpoint(base, "/v1/convert/file")

def document_source(no_server: Bool, base: String, +path: String) -> IO(Host.Reply):
  match no_server:
    case True{}:
      local_document(Core.classify(Files.path.extension(path)), path)
    case False{}:
      do IO<Host.Reply>:
        key : Result<&1, &1, U32 & String, String> <- IO.get_env("DOCLING_SERVE_API_KEY")
        reply : Host.Reply <- Host.docling(document_endpoint(base), env_value(key), path)
        return docling_response(reply)

def choose_material(docling: Bool, +kind: String, frames: String, path: String) -> IO(Host.Reply):
  match docling:
    case False{}:
      material(String.eq(kind, "video"), kind, frames, path)
    case True{}:
      do IO<Host.Reply>:
        url : Result<&1, &1, U32 & String, String> <- IO.get_env("DOCLING_SERVE_URL")
        +base : String = String.trim(env_value(url))
        document_source(String.is_empty(base), base, path)

def suggest(provider: String, base: String, key: String, model: String, +kind: String, frames: String, path: String, prompt: String, +custom: String) -> IO(Host.Reply):
  do IO<Host.Reply>:
    data : Host.Reply <- choose_material(String.eq(kind, "docling"), kind, frames, path)
    use_material(data, String.eq(kind, "video") || String.eq(kind, "image"), String.eq(provider, "ollama"),
      base, key, model, prompt, Core.choose_match(String.is_empty(custom), "", "\n\nCustom instructions:\n" ++ custom))
