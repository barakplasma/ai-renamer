import Base

type Reply is Data:
  Output{text: String}
  Error{message: String}

def decode_status(status: U32, stdout: String, stderr: String) -> Reply:
  match status:
    case 0:
      Output{stdout}
    case _:
      Error{String.trim(stderr)}

def decode(result: Result<&1, &1, U32 & String, U32 & (String & String)>) -> Reply:
  match result:
    case Done{(status, (stdout, stderr))}:
      decode_status(status, stdout, stderr)
    case Fail{(_, message)}:
      Error{message}

def call(op: String, parameters: List<&2, String>) -> IO(Reply):
  do IO<Reply>:
    result : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run(
      "renamer-host", [op], String.join(parameters, "\0"), 67108864, 400000)
    return decode(result)

def unpack(s: String) -> List<&2, String>:
  String.split(s, '\0')
