static char *ar_config_path(void) {
  const char *home = getenv("HOME");
  if (!home || *home != '/') { errno = EINVAL; return NULL; }
  return ar_join(home, "ai-renamer.json");
}
static int ar_config_lock = -1;
static void ar_load(void *task) {
  ARWork *w = task;
  char *path = ar_config_path();
  if (!path) { ar_error(w, "config path", errno); return; }
  if (!strcmp(w->arg[0], "true")) {
    char *lock;
    if (asprintf(&lock, "%s.lock", path) < 0) abort();
    ar_config_lock = open(lock, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    free(lock);
    if (ar_config_lock < 0 || flock(ar_config_lock, LOCK_EX) != 0) {
      ar_error(w, "lock config", errno); free(path); return;
    }
  }
  int fd = open(path, O_RDONLY | O_CLOEXEC);
  free(path);
  if (fd < 0) {
    if (errno != ENOENT) ar_error(w, "read config", errno);
    return;
  }
  if (!ar_read(fd, &w->out, (1 << 20) + 1)) ar_error(w, "read config", errno);
  if (w->out.len > 1 << 20) ar_message(w, "config exceeded 1 MiB");
  close(fd);
}
static void ar_save(void *task) {
  ARWork *w = task;
  char *path = ar_config_path(), *temp = NULL;
  if (!path) { ar_error(w, "config path", errno); return; }
  if (asprintf(&temp, "%s.XXXXXX", path) < 0) abort();
  int fd = mkstemp(temp);
  if (fd < 0) { ar_error(w, "create config temporary file", errno); goto done; }
  if (!ar_write(fd, w->arg[0], strlen(w->arg[0])) || fsync(fd) != 0)
    ar_error(w, "save config", errno);
  if (close(fd) != 0) ar_error(w, "close config", errno);
  if (!w->error && rename(temp, path) != 0) ar_error(w, "replace config", errno);
  if (w->error) unlink(temp);
done:
  if (ar_config_lock >= 0) { close(ar_config_lock); ar_config_lock = -1; }
  free(path); free(temp);
}

typedef struct { uint64_t dev, ino, size; int64_t sec, ns; unsigned char hash[32]; } ARStamp;
static ARStamp ar_stat(const struct stat *st) {
#ifdef __APPLE__
  struct timespec m = st->st_mtimespec;
#else
  struct timespec m = st->st_mtim;
#endif
  return (ARStamp){.dev=st->st_dev, .ino=st->st_ino, .size=st->st_size, .sec=m.tv_sec, .ns=m.tv_nsec};
}
static bool ar_same(ARStamp a, ARStamp b) {
  return a.dev == b.dev && a.ino == b.ino && a.size == b.size && a.sec == b.sec && a.ns == b.ns;
}
static bool ar_hash(int dir, const char *name, ARStamp *value) {
  int fd = openat(dir, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return false;
  bool ok = false;
  struct stat st;
  if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) goto end;
  *value = ar_stat(&st);
#ifdef __APPLE__
  CC_SHA256_CTX digest;
  CC_SHA256_Init(&digest);
#else
  SHA256_CTX digest;
  SHA256_Init(&digest);
#endif
  for (;;) {
    unsigned char buf[65536];
    ssize_t n = read(fd, buf, sizeof buf);
    if (n < 0 && errno == EINTR) continue;
    if (n < 0) goto end;
    if (!n) break;
#ifdef __APPLE__
    CC_SHA256_Update(&digest, buf, (CC_LONG)n);
#else
    SHA256_Update(&digest, buf, (size_t)n);
#endif
  }
  if (fstat(fd, &st) != 0 || !ar_same(*value, ar_stat(&st))) goto end;
#ifdef __APPLE__
  CC_SHA256_Final(value->hash, &digest);
#else
  SHA256_Final(value->hash, &digest);
#endif
  ok = true;
end:
  close(fd);
  return ok;
}
static bool ar_is_same(int dir, const char *name, ARStamp stamp) {
  struct stat st;
  return fstatat(dir, name, &st, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(st.st_mode)
         && ar_same(stamp, ar_stat(&st));
}
static void ar_stamp_text(ARBuffer *buf, ARStamp t) {
  char text[192];
  snprintf(text, sizeof text, "%llu:%llu:%llu:%lld:%lld",
    (unsigned long long)t.dev, (unsigned long long)t.ino, (unsigned long long)t.size,
    (long long)t.sec, (long long)t.ns);
  ar_field(buf, text);
}
static bool ar_stamp_matches(ARStamp t, const char *expected) {
  ARBuffer text = {0};
  ar_stamp_text(&text, t);
  bool matched = !strcmp(text.data, expected);
  free(text.data);
  return matched;
}
static void ar_record(ARWork *w, const char *tag, const char *path,
                      const char *shown, const char *extra) {
  ar_field(&w->out, tag); ar_field(&w->out, path); ar_field(&w->out, shown); ar_field(&w->out, extra);
}
typedef struct { uint64_t dev, ino; } ARIdentity;
typedef struct { ARIdentity *list; size_t len; } ARVisited;
static bool ar_utf8(const unsigned char *p) {
  while (*p) {
    unsigned char lead = *p++;
    if (lead < 0x80) continue;
    int rest;
    unsigned min = 0x80, max = 0xbf;
    if (lead >= 0xc2 && lead <= 0xdf) rest = 1;
    else if (lead >= 0xe0 && lead <= 0xef) {
      rest = 2;
      if (lead == 0xe0) min = 0xa0;
      if (lead == 0xed) max = 0x9f;
    } else if (lead >= 0xf0 && lead <= 0xf4) {
      rest = 3;
      if (lead == 0xf0) min = 0x90;
      if (lead == 0xf4) max = 0x8f;
    } else return false;
    if (*p < min || *p > max) return false;
    ++p;
    while (--rest) {
      if (*p < 0x80 || *p > 0xbf) return false;
      ++p;
    }
  }
  return true;
}
static void ar_scan_at(ARWork *w, const char *path, const char *shown, bool deep, ARVisited *visited) {
  struct stat st;
  if (!ar_utf8((const unsigned char *)path)) {
    ar_record(w, "warn", "", "skipped a path with invalid UTF-8", "");
    return;
  }
  if (lstat(path, &st) != 0) { ar_record(w, "warn", "", path, ""); return; }
  if (S_ISREG(st.st_mode)) {
    ARBuffer stamp = {0};
    ar_stamp_text(&stamp, ar_stat(&st));
    ar_record(w, "file", path, shown, stamp.data);
    free(stamp.data);
    return;
  }
  if (!S_ISDIR(st.st_mode)) return;
  for (size_t i = 0; i < visited->len; ++i)
    if (visited->list[i].dev == (uint64_t)st.st_dev && visited->list[i].ino == (uint64_t)st.st_ino) return;
  visited->list = io_mem(realloc(visited->list, (visited->len + 1) * sizeof(*visited->list)));
  visited->list[visited->len++] = (ARIdentity){st.st_dev, st.st_ino};
  int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) { ar_record(w, "warn", "", path, ""); return; }
  DIR *dir = fdopendir(fd);
  if (!dir) { close(fd); ar_record(w, "warn", "", path, ""); return; }
  ar_record(w, "dir", path, shown, "");
  for (;;) {
    errno = 0;
    struct dirent *entry = readdir(dir);
    if (!entry) {
      if (errno) ar_record(w, "warn", "", path, "");
      break;
    }
    if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
    if (fstatat(fd, entry->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
      ar_record(w, "warn", "", entry->d_name, ""); continue;
    }
    if (!S_ISREG(st.st_mode) && !(deep && S_ISDIR(st.st_mode))) continue;
    char *file = ar_join(path, entry->d_name);
    char *label = !strcmp(shown, ".") ? io_mem(strdup(entry->d_name)) : ar_join(shown, entry->d_name);
    ar_scan_at(w, file, label, deep, visited);
    free(file); free(label);
  }
  closedir(dir);
}
static void ar_scan(void *task) {
  ARWork *w = task;
  char *parent = ar_parent(w->arg[0]), *resolved = realpath(parent, NULL);
  free(parent);
  if (!resolved) { ar_error(w, "input directory", errno); return; }
  const char *leaf = ar_name(w->arg[0]);
  char *path = *leaf ? ar_join(resolved, leaf) : io_mem(strdup(resolved));
  free(resolved);
  struct stat st;
  if (lstat(path, &st) != 0) { ar_error(w, "input path", errno); free(path); return; }
  if (!S_ISDIR(st.st_mode) && !S_ISREG(st.st_mode)) {
    ar_message(w, "input must be a regular file or directory"); free(path); return;
  }
  if (S_ISDIR(st.st_mode)) {
    char *clean = realpath(path, NULL);
    free(path); path = clean;
    if (!path) { ar_error(w, "input path", errno); return; }
  }
  ARVisited visited = {0};
  ar_scan_at(w, path, S_ISDIR(st.st_mode) ? "." : leaf, !strcmp(w->arg[1], "true"), &visited);
  free(visited.list); free(path);
}

