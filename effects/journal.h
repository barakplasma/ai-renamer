static pthread_mutex_t ar_run_mutex = PTHREAD_MUTEX_INITIALIZER;
static int ar_journal = -1;
static bool ar_journal_broken;
static size_t ar_journal_bytes;
static const size_t ar_journal_limit = 128 << 20;
static char *ar_run_dir;
static const char ar_header[] = "ai-renamer-v1\n";
typedef struct {
  uint64_t parent_dev, parent_ino;
  ARStamp stamp;
  char *parent, *from, *to;
} ARMove;
static const char ar_hex_digits[] = "0123456789abcdef";
static void ar_hex(ARBuffer *b, const void *src, size_t n) {
  const unsigned char *p = src;
  for (size_t i = 0; i < n; ++i) {
    char pair[2] = {ar_hex_digits[p[i] >> 4], ar_hex_digits[p[i] & 15]};
    ar_append(b, pair, 2);
  }
}
static bool ar_unhex(const char *text, unsigned char *out, size_t n) {
  if (strlen(text) != 2*n) return false;
  for (size_t i = 0; i < n; ++i) {
    const char *a = strchr(ar_hex_digits, text[2*i]), *b = strchr(ar_hex_digits, text[2*i+1]);
    if (!a || !b) return false;
    out[i] = (unsigned char)((a - ar_hex_digits) * 16 + (b - ar_hex_digits));
  }
  return true;
}
static char *ar_decode_path(const char *text) {
  size_t n = strlen(text)/2;
  char *out = io_mem(malloc(n+1));
  if (!n || !ar_unhex(text, (unsigned char *)out, n) || memchr(out, 0, n)) { free(out); return NULL; }
  out[n] = 0;
  return out;
}
static bool ar_id_ok(const char *id) {
  if (strlen(id) != 33 || id[8] != 'T' || id[15] != 'Z' || id[16] != '-') return false;
  for (size_t i = 0; i < 33; ++i) {
    if (i == 8 || i == 15 || i == 16) continue;
    if (i < 16 ? id[i] < '0' || id[i] > '9' : !strchr(ar_hex_digits, id[i])) return false;
  }
  return true;
}
static char *ar_journal_path(const char *state, const char *id) {
  char *result;
  if (asprintf(&result, "%s/%s.journal", state, id) < 0) abort();
  return result;
}
static void ar_begin(void *task) {
  ARWork *w = task;
  pthread_mutex_lock(&ar_run_mutex);
  char *state = ar_state_dir();
  if (ar_journal >= 0) { ar_message(w, "run already active"); goto end; }
  if (!state || !ar_mkdirs(state)) { ar_error(w, "create state directory", errno); goto end; }
  unsigned char random[8];
#ifdef __APPLE__
  arc4random_buf(random, sizeof random);
#else
  if (getrandom(random, sizeof random, 0) != sizeof random) { ar_error(w, "get random run ID", errno); goto end; }
#endif
  time_t now = time(NULL);
  struct tm utc;
  char prefix[24];
  if (!gmtime_r(&now, &utc) || !strftime(prefix, sizeof prefix, "%Y%m%dT%H%M%SZ-", &utc)) {
    ar_message(w, "cannot format run ID"); goto end;
  }
  ar_text(&w->out, prefix);
  ar_hex(&w->out, random, sizeof random);
  char *file = ar_journal_path(state, w->out.data);
  int fd = open(file, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0600);
  free(file);
  if (fd < 0) { ar_error(w, "create journal", errno); goto end; }
  if (flock(fd, LOCK_EX) || !ar_write(fd, ar_header, strlen(ar_header)) || fsync(fd) || !ar_syncdir(state)) {
    ar_error(w, "initialize journal", errno); close(fd); goto end;
  }
  ar_run_dir = state; state = NULL;
  ar_journal = fd;
  ar_journal_bytes = strlen(ar_header);
end:
  free(state);
  pthread_mutex_unlock(&ar_run_mutex);
}
static bool ar_log(ARMove m) {
  ARBuffer line = {0};
  char meta[256];
  snprintf(meta, sizeof meta, "%llu %llu %llu %llu %llu %lld %lld ",
    (unsigned long long)m.parent_dev, (unsigned long long)m.parent_ino,
    (unsigned long long)m.stamp.dev, (unsigned long long)m.stamp.ino,
    (unsigned long long)m.stamp.size, (long long)m.stamp.sec, (long long)m.stamp.ns);
  ar_text(&line, meta);
  ar_hex(&line, m.stamp.hash, sizeof m.stamp.hash); ar_text(&line, " ");
  ar_hex(&line, m.parent, strlen(m.parent)); ar_text(&line, " ");
  ar_hex(&line, m.from, strlen(m.from)); ar_text(&line, " ");
  ar_hex(&line, m.to, strlen(m.to)); ar_text(&line, "\n");
  if (line.len > ar_journal_limit - ar_journal_bytes) {
    free(line.data);
    errno = EFBIG;
    return false;
  }
  bool ok = ar_write(ar_journal, line.data, line.len) && fsync(ar_journal) == 0;
  if (ok) ar_journal_bytes += line.len;
  free(line.data);
  return ok;
}
static int ar_open_parent(const char *path, struct stat *st) {
  char *resolved = realpath(path, NULL);
  if (!resolved) return -1;
  bool same = !strcmp(path, resolved);
  free(resolved);
  if (!same) { errno = ELOOP; return -1; }
  int fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
  if (fd >= 0 && fstat(fd, st) != 0) { int e = errno; close(fd); errno = e; return -1; }
  return fd;
}
static void ar_rename(void *task) {
  ARWork *w = task;
  const char *path = w->arg[0], *stem = w->arg[1], *shown = w->arg[2], *expected = w->arg[3];
  if (!ar_component(stem)) { ar_message(w, "model did not return a safe filename"); return; }
  char *parent = ar_parent(path);
  const char *from = ar_name(path);
  struct stat st, dest;
  int dir = ar_open_parent(parent, &st), lock = -1;
  if (dir < 0) { ar_error(w, "open target directory", errno); free(parent); return; }
  ARStamp stamp;
  if (!ar_hash(dir, from, &stamp) || !ar_stamp_matches(stamp, expected)) {
    ar_message(w, "source changed since directory scan"); goto done;
  }
  const char *ext = ar_ext(from);
  size_t ext_len = strlen(ext);
  pthread_mutex_lock(&ar_run_mutex);
  if (ar_journal < 0 || ar_journal_broken) { ar_message(w, "no writable recovery journal"); goto unlock; }
  lock = ar_mutations(ar_run_dir);
  if (lock < 0) { ar_error(w, "lock changes", errno); goto unlock; }
  for (unsigned i = 0; i < 100000; ++i) {
    char suffix[16] = "", candidate[256];
    if (i) snprintf(suffix, sizeof suffix, "%u", i);
    size_t suffix_len = strlen(suffix);
    if (ext_len + suffix_len >= 255) { ar_message(w, "filename extension is too long"); break; }
    size_t stem_len = strlen(stem), limit = 255 - ext_len - suffix_len;
    if (stem_len > limit) {
      stem_len = limit;
      while (stem_len && ((unsigned char)stem[stem_len] & 0xc0) == 0x80) --stem_len;
    }
    while (stem_len && (stem[stem_len-1] == '.' || stem[stem_len-1] == ' ')) --stem_len;
    if (!stem_len) { ar_message(w, "filename has no usable stem"); break; }
    memcpy(candidate, stem, stem_len);
    memcpy(candidate+stem_len, suffix, suffix_len);
    for (size_t j = 0; j < ext_len; ++j) {
      char c = ext[j];
      candidate[stem_len+suffix_len+j] = c >= 'A' && c <= 'Z' ? c+32 : c;
    }
    candidate[stem_len+suffix_len+ext_len] = 0;
    if (!ar_component(candidate)) { ar_message(w, "unsafe destination filename"); break; }
    if (!strcmp(from, candidate)) { ar_text(&w->out, shown); break; }
    if (fstatat(dir, candidate, &dest, AT_SYMLINK_NOFOLLOW) == 0) continue;
    if (errno != ENOENT) { ar_error(w, "check destination", errno); break; }
    if (!ar_is_same(dir, from, stamp)) { ar_message(w, "source changed before rename"); break; }
    ARMove record = {(uint64_t)st.st_dev, (uint64_t)st.st_ino, stamp, parent, (char *)from, candidate};
    if (!ar_log(record)) { ar_journal_broken = true; ar_error(w, "sync recovery journal", errno); break; }
    if (!ar_is_same(dir, from, stamp)) { ar_message(w, "source changed while writing journal"); break; }
    if (ar_exclusive(dir, from, candidate) != 0) { ar_error(w, "exclusive rename", errno); break; }
    if (fsync(dir) != 0) { ar_error(w, "rename journaled; directory sync failed", errno); break; }
    if (!ar_is_same(dir, candidate, stamp)) {
      ar_message(w, "rename journaled; destination identity or metadata changed");
      break;
    }
    const char *last = strrchr(shown, '/');
    if (last) ar_append(&w->out, shown, (size_t)(last-shown+1));
    ar_text(&w->out, candidate);
    break;
  }
  if (!w->error && !w->out.len) ar_message(w, "no unused filename found");
unlock:
  if (lock >= 0) close(lock);
  pthread_mutex_unlock(&ar_run_mutex);
done:
  close(dir); free(parent);
}
static bool ar_parse_move(char *line, ARMove *m) {
  unsigned long long a,b,c,d,e;
  long long sec,ns;
  int at = 0;
  if (sscanf(line, "%llu %llu %llu %llu %llu %lld %lld %n", &a,&b,&c,&d,&e,&sec,&ns,&at) != 7 || at == 0)
    return false;
  m->parent_dev = a; m->parent_ino = b;
  m->stamp = (ARStamp){.dev=c,.ino=d,.size=e,.sec=sec,.ns=ns};
  char *context, *hash = strtok_r(line + at, " ", &context);
  char *dir = strtok_r(NULL, " ", &context);
  char *from = strtok_r(NULL, " ", &context);
  char *to = strtok_r(NULL, " ", &context);
  return hash && dir && from && to && !strtok_r(NULL, " ", &context) &&
      ar_unhex(hash, m->stamp.hash, 32) &&
      (m->parent = ar_decode_path(dir)) && m->parent[0] == '/' &&
      (m->from = ar_decode_path(from)) && !strchr(m->from, '/') && strcmp(m->from, ".") && strcmp(m->from, "..") &&
      (m->to = ar_decode_path(to)) && ar_component(m->to) && strcmp(m->to, m->from);
}
static void ar_free_move(ARMove *m) { free(m->parent); free(m->from); free(m->to); }
static int ar_path_state(int dir, const char *name, ARStamp stamp) {
  struct stat st;
  if (fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) != 0) return errno == ENOENT ? 0 : 2;
  if (!S_ISREG(st.st_mode) || !ar_same(stamp, ar_stat(&st))) return 2;
  ARStamp found;
  return ar_hash(dir, name, &found) && ar_same(stamp, found) && !memcmp(stamp.hash, found.hash, 32) ? 1 : 2;
}
static const char *ar_undo(ARMove m, const char *policy, size_t *restored) {
  struct stat st;
  int dir = ar_open_parent(m.parent, &st);
  if (dir < 0) return "cannot open original directory";
  const char *message = NULL;
  if ((uint64_t)st.st_dev != m.parent_dev || (uint64_t)st.st_ino != m.parent_ino) {
    message = "original directory was replaced";
  } else {
    int from = ar_path_state(dir, m.from, m.stamp), to = ar_path_state(dir, m.to, m.stamp);
    char decision = policy[3*from+to];
    if (decision == 'r' && from == 0 && to == 1 && ar_is_same(dir, m.to, m.stamp)) {
      if (ar_exclusive(dir, m.to, m.from) != 0) message = "exclusive restore failed";
      else if (fsync(dir) != 0) message = "restore journaled; directory sync failed";
      else if (!ar_is_same(dir, m.from, m.stamp)) message = "restore journaled; destination identity or metadata changed";
      else ++*restored;
    } else if (decision != 's' || from != 1 || to == 1) {
      message = "original name is occupied or renamed file was changed or removed";
    }
  }
  close(dir);
  return message;
}
static void ar_rollback(void *task) {
  ARWork *w = task;
  const char *id = w->arg[0], *policy = w->arg[1];
  if (!ar_id_ok(id) || strlen(policy) != 9) { ar_message(w, "invalid rollback run ID or policy"); return; }
  char *state = ar_state_dir();
  if (!state) { ar_error(w, "journal path", errno); return; }
  char *path = ar_journal_path(state, id);
  int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC), lock = -1;
  free(path);
  ARMove *moves = NULL;
  size_t count = 0, cap = 0, restored = 0;
  ARBuffer raw = {0}, problems = {0};
  if (fd < 0) { ar_error(w, "open journal", errno); goto done; }
  if (flock(fd, LOCK_EX | LOCK_NB) != 0) { ar_error(w, "run is still active or already being rolled back", errno); goto done; }
  if (!ar_read(fd, &raw, ar_journal_limit + 1)) { ar_error(w, "read journal", errno); goto done; }
  size_t header = strlen(ar_header);
  if (raw.len > ar_journal_limit || raw.len < header || memcmp(raw.data, ar_header, header) || memchr(raw.data, 0, raw.len)) {
    ar_message(w, "invalid or oversized recovery journal"); goto done;
  }
  for (char *line = raw.data + header, *end; (end = strchr(line, '\n')); line = end + 1) {
    if (count == cap) {
      cap = cap ? cap*2 : 32;
      moves = io_mem(realloc(moves, cap * sizeof(*moves)));
    }
    *end = 0;
    moves[count] = (ARMove){0};
    if (!ar_parse_move(line, &moves[count])) {
      ar_free_move(&moves[count]); ar_message(w, "invalid recovery journal record"); goto done;
    }
    ++count;
  }
  lock = ar_mutations(state);
  if (lock < 0) { ar_error(w, "lock changes", errno); goto done; }
  for (size_t i = count; i > 0; --i) {
    ARMove record = moves[i-1];
    const char *problem = ar_undo(record, policy, &restored);
    if (problem) {
      ar_text(&problems, "\n"); ar_text(&problems, record.parent); ar_text(&problems, "/");
      ar_text(&problems, record.from); ar_text(&problems, ": "); ar_text(&problems, problem);
    }
  }
  char summary[128];
  snprintf(summary, sizeof summary, "Rollback %s restored %zu file(s).", id, restored);
  ar_text(&w->out, summary);
  if (problems.len) { ar_text(&w->out, problems.data); ar_message(w, w->out.data); }
done:
  if (lock >= 0) close(lock);
  if (fd >= 0) close(fd);
  for (size_t i = 0; i < count; ++i) ar_free_move(&moves[i]);
  free(moves); free(state); free(raw.data); free(problems.data);
}
static void ar_runs(void *task) {
  ARWork *w = task;
  char *state = ar_state_dir();
  if (!state) { ar_error(w, "journal directory", errno); return; }
  struct dirent **files = NULL;
  int count = scandir(state, &files, NULL, alphasort);
  int code = errno;
  free(state);
  if (count < 0 && code != ENOENT) { ar_error(w, "list journals", code); return; }
  while (count > 0) {
    struct dirent *file = files[--count];
    char *name = file->d_name;
    if (strlen(name) == 41 && !strcmp(name+33, ".journal")) {
      name[33] = 0;
      if (ar_id_ok(name)) {
        if (w->out.len) ar_text(&w->out, "\n");
        ar_text(&w->out, name);
      }
    }
    free(file);
  }
  free(files);
  if (!w->out.len) ar_text(&w->out, "No rename runs.");
}

