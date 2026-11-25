import Base
import ./Options.bend as Options
import 0x64697f57fea19681b5fa4f87014ce63d/main.bend as Shake
import ./Core.bend as Core
import ./Rollback.bend as Rollback
import ./RenameSafety.bend as RenameSafety
import ./JsonData.bend as JsonData
import 0x597f8af3f77d8983aacfa076df42d235/main.bend as Json

# The only text sent to a rename operation comes from a size-limited stem.
law zero_limit_means_no_stem:
  for text: String
  for style: String
  {Core.filename(text, style, 0n) == "" : String}

# Separators in a model response never become directory components.
law path_style_stays_in_directory:
  {Core.filename("../two/words", "pathCase", 20n) == "two-words" : String}

law image_extensions:
  {Core.classify("JPG") == Core.Image{} : Core.FileKind} &
  {Core.classify("png") == Core.Image{} : Core.FileKind}

law video_extensions:
  {Core.classify("mp4") == Core.Video{} : Core.FileKind} &
  {Core.classify("avi") == Core.Video{} : Core.FileKind}

law distinguish_document_and_unknown:
  {Core.classify("pdf") == Core.PDF{} : Core.FileKind} &
  {Core.classify("txt") == Core.TextFile{} : Core.FileKind} &
  {Core.classify("exe") == Core.Unsupported{} : Core.FileKind}

law collision_candidates_have_a_clean_stem:
  {Core.filename("QuarterlyReport", "snakeCase", 30n) == "quarterly_report" : String}

law progress_reaches_100_percent:
  {Core.progress(3n, 3n, 42n) == "Processing |========================================| 100% || 3/3 Files || ETA: 0s" : String}

law rollback_when_source_name_is_free:
  {Rollback.decide(Rollback.Missing{}, Rollback.Matching{}) == Rollback.Restore{} : Rollback.Decision}

law rollback_never_overwrites_different_file:
  for renamed: Rollback.PathState
  {Rollback.decide(Rollback.Different{}, renamed) == Rollback.Conflict{} : Rollback.Decision}

law rollback_when_original_already_restored:
  {Rollback.decide(Rollback.Matching{}, Rollback.Missing{}) == Rollback.Skip{} : Rollback.Decision}

law rollback_leaves_reused_destination_alone:
  {Rollback.decide(Rollback.Matching{}, Rollback.Different{}) == Rollback.Skip{} : Rollback.Decision}

law rollback_detects_duplicate_identity:
  {Rollback.decide(Rollback.Matching{}, Rollback.Matching{}) == Rollback.Conflict{} : Rollback.Decision}

law rollback_detects_two_missing_paths:
  {Rollback.decide(Rollback.Missing{}, Rollback.Missing{}) == Rollback.Conflict{} : Rollback.Decision}

law rollback_does_not_move_replacement_file:
  {Rollback.decide(Rollback.Missing{}, Rollback.Different{}) == Rollback.Conflict{} : Rollback.Decision}

law rollback_policy_matches_host_order:
  {Rollback.policy() == "crcscsccc" : String}

law slash_cannot_enter_a_word:
  {Core.word_char('/') == False{} : Bool}

law backslash_cannot_enter_a_word:
  {Core.word_char(Char.from_u32(92)) == False{} : Bool}

law null_cannot_enter_a_word:
  {Core.word_char(Char.from_u32(0)) == False{} : Bool}

law dot_only_names_become_empty:
  for style: String
  {Core.filename("..", style, 30n) == "" : String}

law blank_model_output_becomes_empty:
  for style: String
  {Core.filename(" \n\t ", style, 30n) == "" : String}

law rendered_stem_is_truncated:
  {Core.filename("Quarterly Report", "snakeCase", 5n) == "quart" : String}

law empty_run_has_no_pending_work:
  {Core.percent_done(0n, 0n) == 100n : Nat}

law null_response_has_no_filename:
  {JsonData.string(Json.null()) == "" : String}

law numeric_response_has_no_filename:
  {JsonData.string(Json.num("123")) == "" : String}

law filename_response_preserves_escaped_text:
  {JsonData.parse_string(Json.parse("\"first\\nsecond\"")) == "first\nsecond" : String}

law generated_filename_obeys_the_requested_length:
  for text: String
  for style: String
  for limit: Nat
  {String.length(Core.filename(text, style, limit)) ==
    Nat.min(limit, String.length(Core.styled(style, Core.words(String.trim(text), "", [])))) : Nat}

law cli_spec_has_no_conflicting_options:
  {Shake.check(Options.spec()) == [] : List<&2, Shake.SpecErr>}

law docling_routes_pdf_and_office_formats:
  {Core.docling_extension("PDF") == True{} : Bool} &
  {Core.docling_extension("docx") == True{} : Bool} &
  {Core.docling_extension("xlsx") == True{} : Bool} &
  {Core.docling_extension("pptx") == True{} : Bool}

law docling_does_not_receive_model_images_or_plain_text:
  {Core.docling_extension("png") == False{} : Bool} &
  {Core.docling_extension("mp4") == False{} : Bool} &
  {Core.docling_extension("txt") == False{} : Bool}

law chat_end_marker_does_not_enter_filename:
  {Core.filename(Core.clean_model_text("qtr_sales_report<|eot_id|>"), "kebabCase", 20n) == "qtr-sales-report" : String}

# These laws cover the rename model. Native tests check it against the filesystem.
law rename_preserves_file_identity_and_size:
  for inode: Nat
  for size: Nat
  {RenameSafety.decide(True{}, True{}, True{}, RenameSafety.FileStamp{inode, size}) ==
    RenameSafety.MoveToDestination{RenameSafety.FileStamp{inode, size}} : RenameSafety.Move}

law invalid_destination_keeps_source:
  for source: RenameSafety.FileStamp
  {RenameSafety.decide(False{}, True{}, True{}, source) ==
    RenameSafety.KeepSource{source} : RenameSafety.Move}

law occupied_destination_keeps_source:
  for source: RenameSafety.FileStamp
  {RenameSafety.decide(True{}, False{}, True{}, source) ==
    RenameSafety.KeepSource{source} : RenameSafety.Move}

law unsynced_journal_keeps_source:
  for source: RenameSafety.FileStamp
  {RenameSafety.decide(True{}, True{}, False{}, source) ==
    RenameSafety.KeepSource{source} : RenameSafety.Move}
