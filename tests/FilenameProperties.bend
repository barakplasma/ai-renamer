import Base
import ../Core.bend as Core
import 0xcb49218c6a354d080bcff793a688eccc/property.bend as Property
import 0xcb49218c6a354d080bcff793a688eccc/generate.bend as Generate
import 0xcb49218c6a354d080bcff793a688eccc/shrink.bend as Shrink
import 0x46b9429cbffa7a8c1111ce19c60a3d6a/random.bend as Random

def input(rng: Random.Rng) -> String & Random.Rng:
  Generate.string(64, rng)

def copy_head(+head: Char, suffixes: String & String) -> String & String:
  match suffixes:
    case (a, b): (SCon{head, a}, SCon{head, b})

def copy(text: String) -> String & String:
  match text:
    case SNil{}: ("", "")
    case SCon{+head, rest}: copy_head(head, copy(rest))

def safe_stem(+name: String, max: Nat) -> Bool:
  Nat.is_le(String.length(name), max) &&
    Bool.not(String.contains(name, "/") || String.contains(name, "\\") || String.contains(name, "\0"))

def safe_styles(styles: List<&2, String>, +input: String) -> Bool:
  match styles:
    case Nil{}:
      True{}
    case Con{style, rest}:
      safe_stem(Core.filename(input, style, 31n), 31n) && safe_styles(rest, input)

def check_copy(pair: String & String) -> String & Bool:
  match pair:
    case (original, input):
      (original, safe_styles(["camelCase", "capitalCase", "constantCase", "dotCase", "noCase", "pascalCase",
    "pascalSnakeCase", "pathCase", "sentenceCase", "snakeCase", "trainCase", "kebabCase"], input))

def check(input: String) -> String & Bool:
  check_copy(copy(input))

def finish(ok: Bool) -> IO(Unit):
  match ok:
    case True{}:
      IO.print("Filename properties passed for 256 generated inputs across all 12 case styles.")
    case False{}:
      IO.exit(1)

def main() -> IO(Unit):
  do IO<Unit>:
    passed : Bool <- Property.run(~String, ~input, ~copy, ~Shrink.string, ~check, ~String.quote, 104729, 256n)
    finish(passed)
