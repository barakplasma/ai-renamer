import Base

type FileKind is Data:
  Image{}
  Video{}
  PDF{}
  TextFile{}
  Unsupported{}

def one_of(xs: List<&2, String>, +value: String) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{head, tail}:
      String.eq(head, value) || one_of(tail, value)

def classify_text(is_text: Bool) -> FileKind:
  match is_text:
    case True{}:
      TextFile{}
    case False{}:
      Unsupported{}

def classify_kind(+ext: String, image: Bool, video: Bool, pdf: Bool) -> FileKind:
  match image video pdf:
    case True{} _ _:
      Image{}
    case _ True{} _:
      Video{}
    case _ _ True{}:
      PDF{}
    case _ _ _:
      classify_text(one_of(String.split("js jsx ts tsx py rb php java c cpp h hpp cs go rs swift kt scala groovy lua pl pm r dart f f90 f95 m asm vb coffee elm erl ex exs hs clj cljs html htm css scss sass less vue svelte md markdown json xml yaml yml csv svg sh bash zsh fish ps1 bat cmd vbs sql graphql gql ejs pug jade hbs twig liquid ipynb txt log diff patch proto tex", ' '), ext))

def classify(raw: String) -> FileKind:
  +ext = String.to_lower(raw)
  image video = one_of(["jpg", "jpeg", "png", "bmp", "tif", "tiff"], ext) one_of(["mp4", "avi", "mov", "wmv", "flv", "mkv", "webm"], ext)
  classify_kind(ext, image, video, String.eq(ext, "pdf"))

def choose_match(yes: Bool, value: String, fallback: String) -> String:
  match yes:
    case True{}:
      value
    case False{}:
      fallback

def or_default(+value: String, fallback: String) -> String:
  choose_match(String.is_empty(value), fallback, value)

def fallback_model(models: List<&2, String>) -> String:
  match models:
    case Nil{}:
      ""
    case Con{head, _}:
      head

def find_model(models: List<&2, String>, +family: String) -> String:
  match models:
    case Nil{}:
      ""
    case Con{+head, tail}:
      choose_match(String.contains(String.to_lower(head), family), head, find_model(tail, family))

def choose_model_from(families: List<&2, String>, +models: List<&2, String>) -> String:
  match families:
    case Nil{}:
      fallback_model(models)
    case Con{family, rest}:
      or_default(find_model(models, family), choose_model_from(rest, models))

def choose_model(models: List<&2, String>) -> String:
  choose_model_from(["llava", "llama", "gemma", "phi", "qwen", "aya", "mistral", "mixtral", "deepseek-coder"], models)

def prompt(style: String, chars: Nat, language: String) -> String:
  "Generate filename:\n\nUse " ++ style ++ "\nMax " ++ Nat.show(chars) ++
  " characters\n" ++ language ++ " only\nNo file extension\nNo special chars\nOnly key elements\nOne word if possible\nNoun-verb format\n\nRespond ONLY with filename."

def add_suffix(done: Nat, seconds: Nat) -> String:
  Nat.show(Nat.div(seconds, Nat.max(1n, done))) ++ "s"

def percent_done(total: Nat, done: Nat) -> Nat:
  match total:
    case 0n:
      100n
    case 1n+rest:
      Nat.div(Nat.mul(done, 100n), 1n+rest)

def progress(+done: Nat, +total: Nat, elapsed: Nat) -> String:
  +percent = percent_done(total, done)
  +filled = Nat.div(Nat.mul(percent, 40n), 100n)
  "Processing |" ++ String.repeat("=", filled) ++ String.repeat("-", Nat.sub(40n, filled)) ++
  "| " ++ Nat.show(percent) ++ "% || " ++ Nat.show(done) ++ "/" ++ Nat.show(total) ++
  " Files || ETA: " ++ add_suffix(done, Nat.mul(Nat.sub(total, done), elapsed))

def word_char(+c: Char) -> Bool:
  +n = Char.to_u32(c)
  Char.is_alpha(c) || Char.is_digit(c) || (n >= 160 : U32) && (n < 8192 : U32) ||
  (n >= 8304 : U32) && (n < 12288 : U32) || (n >= 12352 : U32)

def starts_lower(s: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{head, _}:
      Char.is_lower(head)

def word_boundary(s: String, c: Char, rest: String) -> Bool:
  match s:
    case SNil{}:
      False{}
    case SCon{+previous, _}:
      Char.is_upper(c) && (Char.is_lower(previous) || Char.is_digit(previous) ||
        (Char.is_upper(previous) && starts_lower(rest)))

def save_word(s: String, acc: List<&2, String>) -> List<&2, String>:
  match s:
    case SNil{}:
      acc
    case SCon{head, tail}:
      String.reverse(SCon{head, tail}) <> acc

def next_word(is_word: Bool, boundary: Bool, c: Char, current: String) -> String:
  match is_word boundary:
    case False{} _:
      ""
    case True{} True{}:
      SCon{c, ""}
    case True{} False{}:
      SCon{c, current}

def keep_word(keep: Bool, current: String, acc: List<&2, String>) -> List<&2, String>:
  match keep:
    case True{}:
      save_word(current, acc)
    case False{}:
      acc

def words(s: String, +current: String, acc: List<&2, String>) -> List<&2, String>:
  match s:
    case SNil{}:
      List.reverse(&2, String, save_word(current, acc))
    case SCon{+head, +tail}:
      +valid = word_char(head)
      +boundary = word_boundary(current, head, tail)
      words(tail, next_word(valid, boundary, head, current), keep_word(Bool.not(valid) || boundary, current, acc))

def title(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{head, tail}:
      SCon{Char.to_upper(head), String.to_lower(tail)}

def format_word(s: String, style: U32) -> String:
  match style:
    case 0:
      String.to_lower(s)
    case 1:
      title(s)
    case _:
      String.to_upper(s)

def remaining(xs: List<&2, String>, +f: U32, +separator: String) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{head, tail}:
      separator ++ format_word(head, f) ++ remaining(tail, f, separator)

def joined(head: String, tail: List<&2, String>, +f: U32, +separator: String) -> String:
  format_word(head, f) ++ remaining(tail, f, separator)

def choose_index(found: Bool, index: U32, other: U32) -> U32:
  match found:
    case True{}:
      index
    case False{}:
      other

def style_index(xs: List<&2, String>, +style: String, +index: U32) -> U32:
  match xs:
    case Nil{}:
      99
    case Con{head, tail}:
      choose_index(String.eq(head, style), index, style_index(tail, style, U32.inc(index)))

def render_index(index: U32, head: String, tail: List<&2, String>) -> String:
  match index:
    case 0:
      String.to_lower(head) ++ remaining(tail, 1, "")
    case 1:
      joined(head, tail, 1, " ")
    case 2:
      joined(head, tail, 2, "_")
    case 3:
      joined(head, tail, 0, ".")
    case 4:
      joined(head, tail, 0, " ")
    case 5:
      joined(head, tail, 1, "")
    case 6:
      joined(head, tail, 1, "_")
    case 8:
      title(head) ++ remaining(tail, 0, " ")
    case 9:
      joined(head, tail, 0, "_")
    case 10:
      joined(head, tail, 1, "-")
    case _:
      joined(head, tail, 0, "-")

def render_style(style: String, +head: String, +tail: List<&2, String>) -> String:
  styles = String.split("camelCase capitalCase constantCase dotCase noCase pascalCase pascalSnakeCase pathCase sentenceCase snakeCase trainCase kebabCase", ' ')
  render_index(style_index(styles, style, 0), head, tail)

def styled(+style: String, +xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{+head, +tail}:
      render_style(style, head, tail)

def filename(text: String, style: String, limit: Nat) -> String:
  String.take(styled(style, words(String.trim(text), "", [])), limit)
