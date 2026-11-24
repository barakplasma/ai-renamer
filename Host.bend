import Base

type Reply is Data:
  Output{text: String}
  Error{message: String}

def decode(result: Result<&1, &1, U32 & String, String>) -> Reply:
  match result:
    case Done{text}:
      Output{text}
    case Fail{(_, message)}:
      Error{message}

def load_config_native(lock: String) -> IO(Result<&1, &1, U32 & String, String>):
  import "./effects/native.c"
  import "./effects/unsupported.js"

def load_config(lock: String) -> IO(Reply):
  do IO<Reply>:
    result : Result<&1, &1, U32 & String, String> <- load_config_native(lock)
    return decode(result)

def save_config_native(json: String) -> IO(Result<&1, &1, U32 & String, String>):
  import "./effects/native.c"
  import "./effects/unsupported.js"

def save_config(json: String) -> IO(Reply):
  do IO<Reply>:
    result : Result<&1, &1, U32 & String, String> <- save_config_native(json)
    return decode(result)

def scan_native(path: String, recursive: String) -> IO(Result<&1, &1, U32 & String, String>):
  import "./effects/native.c"
  import "./effects/unsupported.js"

def scan(path: String, recursive: String) -> IO(Reply):
  do IO<Reply>:
    result : Result<&1, &1, U32 & String, String> <- scan_native(path, recursive)
    return decode(result)

def begin_run_native() -> IO(Result<&1, &1, U32 & String, String>):
  import "./effects/native.c"
  import "./effects/unsupported.js"

def begin_run() -> IO(Reply):
  do IO<Reply>:
    result : Result<&1, &1, U32 & String, String> <- begin_run_native()
    return decode(result)

def rename_file_native(path: String, name: String, shown: String, stamp: String) -> IO(Result<&1, &1, U32 & String, String>):
  import "./effects/native.c"
  import "./effects/unsupported.js"

def rename_file(path: String, name: String, shown: String, stamp: String) -> IO(Reply):
  do IO<Reply>:
    result : Result<&1, &1, U32 & String, String> <- rename_file_native(path, name, shown, stamp)
    return decode(result)

def rollback_native(id: String, policy: String) -> IO(Result<&1, &1, U32 & String, String>):
  import "./effects/native.c"
  import "./effects/unsupported.js"

def rollback(id: String, policy: String) -> IO(Reply):
  do IO<Reply>:
    result : Result<&1, &1, U32 & String, String> <- rollback_native(id, policy)
    return decode(result)

def runs_native() -> IO(Result<&1, &1, U32 & String, String>):
  import "./effects/native.c"
  import "./effects/unsupported.js"

def runs() -> IO(Reply):
  do IO<Reply>:
    result : Result<&1, &1, U32 & String, String> <- runs_native()
    return decode(result)

def http_native(url: String, key: String, body: String) -> IO(Result<&1, &1, U32 & String, String>):
  import "./effects/native.c"
  import "./effects/unsupported.js"

def http(url: String, key: String, body: String) -> IO(Reply):
  do IO<Reply>:
    result : Result<&1, &1, U32 & String, String> <- http_native(url, key, body)
    return decode(result)

def material_native(kind: String, frames: String, path: String) -> IO(Result<&1, &1, U32 & String, String>):
  import "./effects/native.c"
  import "./effects/unsupported.js"

def material(kind: String, frames: String, path: String) -> IO(Reply):
  do IO<Reply>:
    result : Result<&1, &1, U32 & String, String> <- material_native(kind, frames, path)
    return decode(result)

def unpack(s: String) -> List<&2, String>:
  String.split(s, '\0')
