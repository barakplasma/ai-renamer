import Base
import ./Core.bend as Core

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
