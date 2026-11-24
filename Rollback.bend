import Base

type PathState is Data:
  Missing{}
  Matching{}
  Different{}

type Decision is Data:
  Restore{}
  Skip{}
  Conflict{}

def decide(original: PathState, renamed: PathState) -> Decision:
  match original renamed:
    case Missing{} Matching{}:
      Restore{}
    case Matching{} Missing{}:
      Skip{}
    case Matching{} Different{}:
      Skip{}
    case _ _:
      Conflict{}

def code(decision: Decision) -> String:
  match decision:
    case Restore{}:
      "r"
    case Skip{}:
      "s"
    case Conflict{}:
      "c"

# Order shared with the filesystem adapter: missing, matching, different.
def row(+original: PathState) -> String:
  code(decide(original, Missing{})) ++ code(decide(original, Matching{})) ++
    code(decide(original, Different{}))

def policy() -> String:
  row(Missing{}) ++ row(Matching{}) ++ row(Different{})
