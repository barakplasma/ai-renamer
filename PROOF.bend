import Base
import ./Core.bend as Core
import ./LAWS.bend as Laws

def take_zero(s: String) -> {String.take(s, 0n) == "" : String}:
  match s:
    case SNil{}:
      {==}
    case SCon{_, _}:
      {==}

def Laws.zero_limit_means_no_stem(text, style):
  take_zero(Core.styled(style, Core.words(String.trim(text), "", [])))

def Laws.path_style_stays_in_directory():
  {==}

def Laws.image_extensions():
  ({==}, {==})

def Laws.video_extensions():
  ({==}, {==})

def Laws.distinguish_document_and_unknown():
  ({==}, ({==}, {==}))

def Laws.collision_candidates_have_a_clean_stem():
  {==}

def Laws.progress_reaches_100_percent():
  {==}
