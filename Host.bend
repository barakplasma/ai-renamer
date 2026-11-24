import Base

type Reply is Data:
  Output{text: String}
  Error{message: String}

def raw(op: String, input: String) -> IO(Result<&1, &1, U32 & String, String>):
  import "./bridge.c"
  import "./bridge.js"

def decode(result: Result<&1, &1, U32 & String, String>) -> Reply:
  match result:
    case Done{text}:
      Output{text}
    case Fail{(_, message)}:
      Error{message}

def call(op: String, parameters: List<&2, String>) -> IO(Reply):
  do IO<Reply>:
    result : Result<&1, &1, U32 & String, String> <- raw(op, String.join(parameters, "\0"))
    return decode(result)

def unpack(s: String) -> List<&2, String>:
  String.split(s, '\0')
