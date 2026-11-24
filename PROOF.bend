import Base
import ./Core.bend as Core
import ./Rollback.bend as Rollback
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

def Laws.rollback_when_source_name_is_free():
  {==}

def Laws.rollback_never_overwrites_different_file(renamed):
  match renamed:
    case Rollback.Missing{}:
      {==}
    case Rollback.Matching{}:
      {==}
    case Rollback.Different{}:
      {==}

def Laws.rollback_when_original_already_restored():
  {==}

def Laws.rollback_leaves_reused_destination_alone():
  {==}

def Laws.rollback_detects_duplicate_identity():
  {==}

def Laws.rollback_detects_two_missing_paths():
  {==}

def Laws.rollback_does_not_move_replacement_file():
  {==}

def Laws.rollback_policy_matches_host_order():
  {==}

def Laws.slash_cannot_enter_a_word():
  {==}

def Laws.backslash_cannot_enter_a_word():
  {==}

def Laws.null_cannot_enter_a_word():
  {==}

def Laws.dot_only_names_become_empty(style):
  {==}

def Laws.blank_model_output_becomes_empty(style):
  {==}

def Laws.rendered_stem_is_truncated():
  {==}

def Laws.empty_run_has_no_pending_work():
  {==}
