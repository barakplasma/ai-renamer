import Base

type FileStamp is Data:
  FileStamp{inode: Nat, size: Nat}

type Move is Data:
  KeepSource{source: FileStamp}
  MoveToDestination{destination: FileStamp}

# Model a same-directory exclusive rename. The host supplies the preconditions
# and the filesystem implements the move.
def decide(valid_name: Bool, empty_destination: Bool, synced_journal: Bool, source: FileStamp) -> Move:
  match valid_name empty_destination synced_journal:
    case True{} True{} True{}:
      MoveToDestination{source}
    case _ _ _:
      KeepSource{source}
